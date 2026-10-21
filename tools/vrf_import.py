#!/usr/bin/env python3
"""Turn a Source 2 (CS2) map into an importable g2gfast map, through ValveResourceFormat.

    tools/vrf_import.py surf_hologram.vpk maps/imported --id surf_hologram \\
        --cli /path/to/Source2Viewer-CLI --work /path/to/scratch/surf_hologram

The second importer path: `bsp_import.py` reads a compiled Source 1 `.bsp`; a CS2 map is a
`.vpk` of `.vwrld_c`/`.vmdl_c`/`.vents_c` resources, which only ValveResourceFormat (VRF,
MIT, https://github.com/ValveResourceFormat/ValveResourceFormat) reads. This script runs
its CLI, then writes the same files `bsp_import.py` does (`<id>.json` manifest, `<id>.bin`,
`<id>_lightmap.png`; no textures) so the game loads the map the same way and nothing past
the importer knows which engine it came from. Needs numpy, scipy and trimesh.

What VRF is asked for, and why (measured on surf_hologram, VRF 20.1):

* `-d --gltf_export_format glb` writes `maps/<name>.glb` (the render geometry of the world
  nodes, in metres, node matrices carrying the scale), `maps/<name>_physics.glb` (every
  entity's physics: triggers, clips), and `maps/<name>/world_physics_physics.glb` (the
  world's collision, in SOURCE UNITS with Z up, the node matrix again carrying the scale).
* `-f maps/<name>/entities/default_ents.vents_c -b DATA` prints the entity lump as KeyValues3
  text, which is where spawns, triggers and their targets are.

[b]Scale and axes.[/b] The glTF is in metres at 0.0254 m per unit (a Source 2 unit is an
inch) and re-axed to Y-up: `glTF = (src.y, src.z, src.x) * 0.0254`, a cyclic permutation, no
flip. The movement numbers (250 u/s, 72 tall) are the same numbers as the Source 1 maps', so
a Source 2 unit is a genre unit exactly as a `.bsp` unit is; it is the 0.0254 that is undone
here, never a new ratio. The manifest then takes the importer's own axis swap
(`to_godot`: x, z, -y).

[b]Collision is the author's physics, not the picture.[/b] The world's physics comes out as
a triangle soup. Welded and split into pieces, most of surf_hologram's world pieces are
closed boxes: those become convex hulls, as a `.bsp` brush does. A closed piece that is not
convex, and every open piece (the `playerclip` sheets laid over the ramps, whose visual
model has no physics at all), is kept as triangles, written BOTH ways round because the
loader's concave shape is single-sided and a sheet has no inside.

[b]Textures and lighting are not carried over.[/b] The art rule: the author's textures are
replaced by the game's own prototype set, which is what a Source 1 surface the pakfile did
not carry gets. Every surface is `prototype`, placed in the world on a 64-unit grid, role
from the slope. CS2's baked light (`irradiance.exr`) is not decoded: the lightmap is one
white patch. The sun comes from `light_environment`.
"""

import argparse
import collections
import json
import math
import os
import re
import struct
import subprocess
import sys

import numpy as np
import trimesh
from scipy.spatial import ConvexHull, QhullError

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsp_import as bi  # noqa: E402
from bsp_read import to_godot, yaw_to_godot  # noqa: E402
import vtf  # noqa: E402

METRES_PER_INCH = 0.0254
LM_SIZE = 8

SPAWN_CLASSES = ("info_player_terrorist", "info_player_counterterrorist", "info_player_start")


# ------------------------------------------------------------------ the CLI ---
def run_cli(cli, vpk, work, name):
    """Export the map's glTFs and print its entity lump, into `work`. Idempotent."""
    os.makedirs(work, exist_ok=True)
    if not os.path.exists(os.path.join(work, "maps", name + ".glb")):
        subprocess.run([cli, "-i", vpk, "-o", work, "-d", "--gltf_export_format", "glb",
                        "--gltf_export_extras"], check=True, stdout=subprocess.DEVNULL)
    ents = os.path.join(work, "entities.kv3")
    if not os.path.exists(ents) or os.path.getsize(ents) == 0:
        out = subprocess.run([cli, "-i", vpk, "-f", "maps/%s/entities/default_ents.vents_c" % name,
                              "-b", "DATA"], check=True, capture_output=True, text=True).stdout
        with open(ents, "w") as fh:
            fh.write(out)
    return ents


def vpk_map_name(cli, vpk):
    out = subprocess.run([cli, "-i", vpk, "--vpk_dir"], check=True, capture_output=True,
                         text=True).stdout
    names = re.findall(r"^maps/([A-Za-z0-9_]+)\.vmap_c ", out, re.M)
    if len(names) != 1:
        raise SystemExit("expected one maps/<name>.vmap_c in the vpk, found %r" % names)
    return names[0]


def parse_entities(path):
    """The KeyValues3 entity lump as one dict per entity (flat keys only, which is all it has)."""
    ents, cur = [], None
    with open(path) as fh:
        for line in fh:
            s = line.strip()
            if s == "values =":
                cur = {}
                continue
            if cur is None:
                continue
            if s == "}":
                if cur and "classname" in cur:
                    ents.append(cur)
                cur = None
                continue
            m = re.match(r'^(\w+) = (.*)$', s)
            if m:
                v = m.group(2)
                if v.startswith('"') and v.endswith('"'):
                    v = v[1:-1]
                cur[m.group(1)] = v
    return ents


def numbers(value, count=3):
    parts = str(value).replace(",", " ").replace("[", " ").replace("]", " ").split()
    try:
        out = [float(p) for p in parts[:count]]
    except ValueError:
        return None
    return out if len(out) == count else None


# The author's textures are not carried, and the engine's own prototype grid is tinted instead.
# These are the sRGB tints, chosen by the material's role in the course (ramp, rail, end cap).
PALETTE = {
    "full_ramp_end_mat": [0.80, 0.50, 0.20], "half_ramp_end_mat": [0.80, 0.50, 0.20],
    "half_ramp_end_flip_mat": [0.80, 0.50, 0.20], "ramp_surf_side_mat": [0.25, 0.45, 0.75],
    "side_rail_ramp_mat": [0.20, 0.55, 0.40], "tileable_surf_dec_mat": [0.40, 0.42, 0.48],
    "reflectivity_30": [0.55, 0.55, 0.58], "reflectivity": [0.55, 0.55, 0.58],
    # surf_intro (Chent): painted concrete walls, a darker concrete, orange blend ramps.
    "hr_concrete_wall_painted_002_grey": [0.46, 0.47, 0.50],
    "hr_concrete_wall_painted_002_grey_dark": [0.26, 0.27, 0.30],
    "orange_blend": [0.85, 0.45, 0.15], "meshset": [0.5, 0.5, 0.5],
}


# ----------------------------------------------------------------- geometry ---
def to_src(points_gltf):
    """glTF metres (Y up) to Source units (Z up): src = (g.z, g.x, g.y) / 0.0254."""
    p = np.asarray(points_gltf, dtype=np.float64) / METRES_PER_INCH
    return np.stack([p[..., 2], p[..., 0], p[..., 1]], axis=-1)


def node_geometry(path):
    """Every node's geometry placed by its matrix: (node name, src vertices, src normals, faces)."""
    scene = trimesh.load(path)
    out = []
    for node in scene.graph.nodes_geometry:
        matrix, gname = scene.graph[node]
        g = scene.geometry[gname]
        v = trimesh.transform_points(g.vertices, matrix)
        n = None
        if len(g.vertex_normals) == len(g.vertices):
            n = to_src(g.vertex_normals @ matrix[:3, :3].T)
            ln = np.linalg.norm(n, axis=1)
            ln[ln == 0] = 1.0
            n = n / ln[:, None]
        out.append((node, to_src(v), n, np.asarray(g.faces), matrix))
    return out


def material_of(node):
    """`node000_world_lr0_agg4_51_ramp_surf_side_mat_fragment3` -> `ramp_surf_side_mat`."""
    if re.search(r"nomerge\d+\.meshset(?:_\d+)?$", node):
        return "meshset"
    m = re.match(r"^node\d+_world_lr\d+_agg\d+_\d+_(.+?)(?:_fragment\d+)?$", node)
    name = m.group(1) if m else re.sub(r"_fragment\d+$", "", node)
    # glTF de-duplicates repeated material names with a counter (`side_rail_ramp_mat_66`),
    # which is not part of the name; `reflectivity_30` is, so only its second counter goes.
    name = re.sub(r"^(.*_mat|reflectivity_\d+)_\d+$", r"\1", name)
    base = re.sub(r"_\d+$", "", name)
    return base if base in PALETTE else name


def build_mesh(parts, cos_limit):
    """The drawn world as (material, role) surfaces in the importer's vertex layout."""
    groups = collections.defaultdict(lambda: ([], [], {}))
    white = (2.0 / LM_SIZE, 2.0 / LM_SIZE)
    degenerate = 0
    for node, v, n, faces, _m in parts:
        mat = material_of(node)
        for f in faces:
            a, b, c = v[f[0]], v[f[1]], v[f[2]]
            fn = np.cross(b - a, c - a)
            ln = np.linalg.norm(fn)
            if ln < 1e-6:
                degenerate += 1
                continue
            fn = fn / ln
            # The front is the side the vertex normals point to; the ring is then wound the
            # engine's way (clockwise from the front) whatever way the glTF had it.
            if n is not None and np.dot(fn, n[f[0]] + n[f[1]] + n[f[2]]) < 0:
                fn = -fn
                ring_src = (a, c, b)
            else:
                ring_src = (a, b, c)
            role = bi.role_for_normal(float(fn[2]), cos_limit)
            verts, idx, seen = groups[(mat, role)]
            tan, bit = bi.tangent_frame(tuple(float(x) for x in fn))
            ring = []
            for p in ring_src:
                key = (round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2),
                       round(float(fn[0]), 3), round(float(fn[1]), 3), round(float(fn[2]), 3))
                i = seen.get(key)
                if i is None:
                    g, gn = to_godot(p), to_godot(fn)
                    u = (p[0] * tan[0] + p[1] * tan[1] + p[2] * tan[2]) / bi.UNITS_PER_SQUARE
                    w = (p[0] * bit[0] + p[1] * bit[1] + p[2] * bit[2]) / bi.UNITS_PER_SQUARE
                    verts.append((g, gn, (u, w), white))
                    i = seen[key] = len(verts) - 1
                ring.append(i)
            # (a, b, c) is anticlockwise seen from the side cross(b-a, c-a) points to; the
            # engine's front face is clockwise, so the ring goes in reversed.
            idx.extend((ring[0], ring[2], ring[1]))
    surfaces, blob = [], bytearray()
    for key in sorted(groups):
        mat, role = key
        verts, idx, _ = groups[key]
        voff = len(blob)
        for g, gn, uv, uv2 in verts:
            blob += struct.pack("<10f", g[0], g[1], g[2], gn[0], gn[1], gn[2],
                                uv[0], uv[1], uv2[0], uv2[1])
        ioff = len(blob)
        for i in idx:
            blob += struct.pack("<I", i)
        surfaces.append({"material": mat, "role": role, "prototype": True,
                         "vertex_offset": voff, "vertex_count": len(verts),
                         "index_offset": ioff, "index_count": len(idx),
                         "texture": None, "translucent": False,
                         **({"colour": PALETTE[mat]} if mat in PALETTE else {})})
    return surfaces, bytes(blob), degenerate


def pieces(v, faces, weld=0.5):
    """Connected pieces of a triangle soup: lists of face indices, welded within `weld`."""
    keys = np.round(v / weld).astype(np.int64)
    ids, parent = {}, []

    def vid(k):
        i = ids.get(k)
        if i is None:
            i = ids[k] = len(parent)
            parent.append(i)
        return i

    def find(i):
        while parent[i] != i:
            parent[i] = parent[parent[i]]
            i = parent[i]
        return i

    tri = [[vid(tuple(keys[i])) for i in f] for f in faces]
    for t in tri:
        for j in (1, 2):
            a, b = find(t[0]), find(t[j])
            if a != b:
                parent[b] = a
    comp = collections.defaultdict(list)
    for fi, t in enumerate(tri):
        comp[find(t[0])].append(fi)
    return list(comp.values()), tri


def closed(tri_of_piece):
    """Every welded edge used exactly once each way: a closed, consistently wound surface."""
    e = collections.Counter()
    for t in tri_of_piece:
        for k in range(3):
            e[(t[k], t[(k + 1) % 3])] += 1
    return all(c == 1 and e.get((b, a), 0) == 1 for (a, b), c in e.items())


def build_collision(physics_path):
    """Convex hulls for the closed convex pieces, two-sided triangles for the rest."""
    hulls, tri_pts, report = [], [], collections.Counter()
    for node, v, _n, faces, _m in node_geometry(physics_path):
        comps, tri = pieces(v, faces)
        for comp in comps:
            fs = faces[comp]
            pts = np.unique(np.round(v[np.unique(fs.ravel())], 3), axis=0)
            as_hull = None
            if len(comp) >= 4 and len(pts) >= 4 and closed([tri[f] for f in comp]):
                try:
                    h = ConvexHull(pts)
                    # The surface's own enclosed volume against its hull's: equal exactly
                    # when it is convex.
                    tv = sum(np.dot(v[f[0]], np.cross(v[f[1]], v[f[2]])) for f in fs) / 6.0
                    if abs(abs(tv) - h.volume) <= 0.02 * h.volume:
                        as_hull = pts[h.vertices]
                except QhullError:
                    pass
            if as_hull is not None:
                hulls.append(as_hull)
                report[node + ": hulls"] += 1
            else:
                for f in fs:
                    tri_pts.append(v[f])
                report[node + ": triangles"] += len(comp)
    return hulls, tri_pts, report


def collision_blob(hulls, tri_pts):
    blob = bytearray()
    for pts in hulls:
        blob += struct.pack("<I", len(pts))
        for p in pts:
            blob += struct.pack("<3f", *to_godot(p))
    verts, index_of, idx = [], {}, []
    for t in tri_pts:
        for tt in (t, t[::-1]):
            for p in tt:
                key = (round(float(p[0]), 2), round(float(p[1]), 2), round(float(p[2]), 2))
                i = index_of.get(key)
                if i is None:
                    i = index_of[key] = len(verts)
                    verts.append(to_godot(p))
                idx.append(i)
    voff = len(blob)
    for p in verts:
        blob += struct.pack("<3f", *p)
    ioff = len(blob)
    for i in idx:
        blob += struct.pack("<I", i)
    info = {"hull_count": len(hulls), "hull_offset": 0,
            "displacement_vertex_offset": voff, "displacement_vertex_count": len(verts),
            "displacement_index_offset": ioff, "displacement_index_count": len(idx),
            "playerclip_hulls": 0, "prop_hulls": 0}
    return bytes(blob), info


# -------------------------------------------------------------------- zones ---
def entity_boxes(physics_path, ents):
    """{entity index: (lo, hi)} in Source units: each brush entity's physics AABB.

    The map-level physics glb has one node per entity with a model; the node's translation
    is the entity's origin, which is how a node is tied back to its entity.
    """
    placed = []
    for node, v, _n, _f, matrix in node_geometry(physics_path):
        placed.append((node, to_src(matrix[:3, 3]), v.min(axis=0), v.max(axis=0)))
    out, used = {}, set()
    for i, e in enumerate(ents):
        o = numbers(e.get("origin", ""))
        if o is None or "model" not in e:
            continue
        best = None
        for k, (node, org, lo, hi) in enumerate(placed):
            if k in used or not node.startswith(e["classname"]):
                continue
            d = float(np.linalg.norm(org - np.array(o)))
            if d < 2.0 and (best is None or d < best[0]):
                best = (d, k)
        if best:
            used.add(best[1])
            out[i] = ([float(x) for x in placed[best[1]][2]], [float(x) for x in placed[best[1]][3]])
    return out


def build_zones(ents, boxes, solids):
    spawns = []
    for e in ents:
        if e["classname"] in SPAWN_CLASSES and "origin" in e:
            o = numbers(e["origin"])
            yaw = (numbers(e.get("angles", "0 0 0")) or [0, 0, 0])[1]
            spawns.append({"origin_src": o, "origin": list(to_godot(o)),
                           "yaw": yaw_to_godot(yaw), "yaw_src": yaw})
    if not spawns:
        raise SystemExit("no info_player_* in the entity lump: nowhere to start")
    # info_player_start is the one the map's own teleports aim at.
    main = next((s for e in ents if e["classname"] == "info_player_start"
                 for s in spawns if s["origin_src"] == numbers(e["origin"])), spawns[0])
    by_name = {e["targetname"]: e for e in ents if e.get("targetname")}

    zones, notes = [], []

    def add(kind, lo, hi, dest=None, yaw=0.0, comment="", pit=False):
        z = {"kind": kind, "track": 0}
        if lo is not None:
            if pit:
                lo, hi, grown, _how = bi.inflate_pit(lo, hi, bi.MIN_ZONE_THICKNESS, solids)
            else:
                lo, hi, grown = bi.inflate(lo, hi, bi.MIN_ZONE_THICKNESS)
            a, b = to_godot(lo), to_godot(hi)
            z["min"] = [min(a[i], b[i]) for i in range(3)]
            z["max"] = [max(a[i], b[i]) for i in range(3)]
            z["inflated"] = grown
        if dest is not None:
            at = to_godot(dest)
            z["destination"] = [at[0], at[1] + bi.DESTINATION_LIFT, at[2]]
            z["destination_yaw"] = yaw_to_godot(yaw)
        if comment:
            z["comment"] = comment
        zones.append(z)

    # The surf timer plugins' convention, which the mapper's page says the map follows:
    # `map_start` and `map_end` trigger_multiples.
    for i, e in enumerate(ents):
        tn = e.get("targetname", "").replace("[PR#]", "")
        if e["classname"] == "trigger_multiple" and i in boxes:
            lo, hi = boxes[i]
            if tn == "map_start":
                add("START", lo, hi, dest=main["origin_src"], yaw=main["yaw_src"], comment=tn)
            elif tn == "map_end":
                add("END", lo, hi, comment=tn)
    kinds = {z["kind"] for z in zones}
    if not kinds:
        # No map_start / map_end: a staged map whose timer plugin is told its zones by file
        # (surf_intro). Read it from the teleport graph instead, the way the Source 1 importer
        # does for a staged map.
        return build_staged_zones(ents, boxes, solids, spawns, by_name, add, zones, notes)
    if not {"START", "END"} <= kinds:
        raise SystemExit("map_start / map_end not both found among the trigger_multiples")
    add("SPAWN", None, None, dest=main["origin_src"], yaw=main["yaw_src"],
        comment="the spawn for main")

    respawn = []
    for i, e in enumerate(ents):
        if e["classname"] != "trigger_teleport" or i not in boxes:
            continue
        tgt = by_name.get(e.get("target", ""))
        o = numbers(tgt["origin"]) if tgt and "origin" in tgt else None
        if o is None:
            raise SystemExit("trigger_teleport %s aims at %r, which is not in the entity lump"
                             % (e.get("hammerUniqueId", "?"), e.get("target")))
        yaw = (numbers(tgt.get("angles", "0 0 0")) or [0, 0, 0])[1]
        lo, hi = boxes[i]
        add("RESPAWN", lo, hi, dest=o, yaw=yaw, comment=e["target"].replace("[PR#]", ""), pit=True)
        z = zones[-1]
        respawn.append({"min": z["min"], "max": z["max"], "inflated": z["inflated"], "track": 0})
    return zones, spawns, main, respawn, notes


def lighting_of(ents):
    out = {}
    env = next((e for e in ents if e["classname"] == "light_environment"), None)
    if env is not None:
        ang = numbers(env.get("angles", "0 0 0")) or [0, 0, 0]
        col = numbers(env.get("color", "255 255 255")) or [255, 255, 255]
        # Source 2's pitch is positive downwards, Source 1's negative: the manifest wants
        # the latter. Brightness is a plain bright day; the baked light is not carried.
        out["sun"] = {"yaw_src": ang[1], "pitch_src": -ang[0],
                      "colour": [c / 255.0 for c in col], "brightness": 400.0}
    world = next((e for e in ents if e["classname"] == "worldspawn"), None)
    if world is not None and world.get("skyname"):
        out["sky_name"] = world["skyname"]
    out["baked_light_count"] = sum(1 for e in ents if e["classname"].startswith("light_omni"))
    return out


STAGE_NAME = re.compile(r"^S(\d+)$")
START_ROOM_EXTENTS = (480.0, 448.0, 192.0)
ARRIVAL_EXTENTS = (160.0, 160.0, 96.0)


def build_staged_zones(ents, boxes, solids, spawns, by_name, add, zones, notes):
    """START / STAGE / END / RESPAWN from a teleport graph named `Spawn`, `S1`..`Sn`, `Win`.

    [b]A gate is a teleport aimed at a section from inside a different one; a pit is aimed at
    its own section's start.[/b] A section's extent is its widest floor-level teleport (the
    slab under the course, aimed at the section's own start). Every other teleport whose
    centre lies in a section's footprint but aims elsewhere is that section's gate: its
    arrival becomes the next STAGE zone, and the one aimed at `Win` is the END (round the
    win room). A teleport aimed at `Spawn` sends back to the spawn room (the START room round the
    `Spawn` start entity): a pit. The thin one in no section's footprint (the spawn room's
    own door) is the gate to S1, so the stages run 1..n as the timer wants.
    """
    def tag(name):
        return (name or "").replace("[PR#]", "")

    starts = {tag(e.get("targetname")): e for e in ents
              if e["classname"] == "info_player_start" and e.get("targetname")}
    if "Spawn" not in starts:
        raise SystemExit("staged map without an info_player_start named Spawn")
    room = starts["Spawn"]
    room_o = numbers(room["origin"])
    room_yaw = (numbers(room.get("angles", "0 0 0")) or [0, 0, 0])[1]
    # The room's own player starts; the other info_player_starts are the stages' arrivals.
    keep = [s for s in spawns if np.linalg.norm(np.array(s["origin_src"]) - room_o) < 256.0]
    spawns[:] = keep
    main = next(s for s in spawns if s["origin_src"] == room_o)

    tele = [(i, e, boxes[i]) for i, e in enumerate(ents)
            if e["classname"] == "trigger_teleport" and i in boxes]
    # Section footprints: the widest slab aimed at each S<n>.
    slabs = {}
    for _i, e, (lo, hi) in tele:
        t = tag(e["target"])
        area = (hi[0] - lo[0]) * (hi[1] - lo[1])
        if STAGE_NAME.match(t) and (t not in slabs or area > slabs[t][0]):
            slabs[t] = (area, lo, hi)

    def section_of(lo, hi):
        cx, cy = (lo[0] + hi[0]) / 2.0, (lo[1] + hi[1]) / 2.0
        hit = [(a, t) for t, (a, l, h) in slabs.items()
               if l[0] <= cx <= h[0] and l[1] <= cy <= h[1]]
        return min(hit)[1] if hit else None

    add("START", [room_o[0] - START_ROOM_EXTENTS[0], room_o[1] - START_ROOM_EXTENTS[1],
                  room_o[2] - START_ROOM_EXTENTS[2]],
        [room_o[0] + START_ROOM_EXTENTS[0], room_o[1] + START_ROOM_EXTENTS[1],
         room_o[2] + START_ROOM_EXTENTS[2]], dest=room_o, yaw=room_yaw,
        comment="the spawn room the start entities stand in")
    add("SPAWN", None, None, dest=main["origin_src"], yaw=main["yaw_src"],
        comment="the spawn for main")

    def arrival(name, kind, number=None):
        e = starts[name]
        o = numbers(e["origin"])
        yaw = (numbers(e.get("angles", "0 0 0")) or [0, 0, 0])[1]
        ext = ARRIVAL_EXTENTS
        add(kind, [o[0] - ext[0], o[1] - ext[1], o[2] - ext[2]],
            [o[0] + ext[0], o[1] + ext[1], o[2] + ext[2]], dest=o, yaw=yaw,
            comment="the arrival of %s's gate" % name)
        if number is not None:
            zones[-1]["number"] = float(number)

    respawn, seen_gate = [], set()
    for _i, e, (lo, hi) in tele:
        t = tag(e["target"])
        sec = section_of(lo, hi)
        # A gate is thin and stands in a section aimed at a later one; the slabs are pits.
        is_slab = sec == t and (hi[0] - lo[0]) > 512.0
        if t != "Spawn" and sec != t and not is_slab:
            # The gate itself is a teleport like any other (it sends the run on, kept); the
            # arrival is what is timed.
            if t not in seen_gate:
                seen_gate.add(t)
                if t == "Win":
                    arrival("Win", "END")
                else:
                    arrival(t, "STAGE", int(STAGE_NAME.match(t).group(1)))
        tgt = by_name.get(e["target"])
        o = numbers(tgt["origin"]) if tgt and "origin" in tgt else None
        if o is None:
            raise SystemExit("trigger_teleport aims at %r, which is not in the entity lump"
                             % e.get("target"))
        yaw = (numbers(tgt.get("angles", "0 0 0")) or [0, 0, 0])[1]
        add("RESPAWN", lo, hi, dest=o, yaw=yaw, comment=t, pit=True)
        z = zones[-1]
        respawn.append({"min": z["min"], "max": z["max"], "inflated": z["inflated"], "track": 0})
    # The spawn room's exit is a gate to S1 too: a thin teleport in no section's footprint.
    return zones, spawns, main, respawn, notes


# ------------------------------------------------------------------- driver ---
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("vpk")
    ap.add_argument("out_dir")
    ap.add_argument("--id", required=True)
    ap.add_argument("--cli", required=True, help="path to ValveResourceFormat's Source2Viewer-CLI")
    ap.add_argument("--work", required=True, help="scratch directory for the CLI's output "
                    "(never inside a repository)")
    ap.add_argument("--zones-dir", default=None, dest="zones_dir")
    ap.add_argument("--tier", type=int, default=3)
    a = ap.parse_args(argv)

    map_id = a.id.lower()
    zones_dir = a.zones_dir or os.path.join(os.path.dirname(os.path.abspath(__file__)),
                                            "..", "maps", "zones")
    doc = bi.load_overrides(zones_dir, map_id)
    problem = bi.attribution_problem(doc, map_id)
    if problem is not None:
        print("refused: %s" % problem, file=sys.stderr)
        return 2

    name = vpk_map_name(a.cli, a.vpk)
    ents = parse_entities(run_cli(a.cli, a.vpk, a.work, name))
    base = os.path.join(a.work, "maps")

    d = os.path.join(a.out_dir, map_id)
    os.makedirs(d, exist_ok=True)
    cos_limit = math.cos(math.radians(bi.MAX_SLOPE_DEGREES))

    parts = node_geometry(os.path.join(base, name + ".glb"))
    surfaces, mesh_blob, degenerate = build_mesh(parts, cos_limit)

    hulls, tri_pts, _report = build_collision(
        os.path.join(base, name, "world_physics_physics.glb"))
    col_blob, collision = collision_blob(hulls, tri_pts)
    for key in ("hull_offset", "displacement_vertex_offset", "displacement_index_offset"):
        collision[key] += len(mesh_blob)
    with open(os.path.join(d, map_id + ".bin"), "wb") as fh:
        fh.write(mesh_blob)
        fh.write(col_blob)

    # One white patch: the only thing an unlit prototype surface samples.
    vtf.write_png(os.path.join(d, map_id + "_lightmap.png"), LM_SIZE, LM_SIZE,
                  b"\xff" * (LM_SIZE * LM_SIZE * 4), opaque=True)

    boxes = entity_boxes(os.path.join(base, name + "_physics.glb"), ents)
    solids = [([float(x) for x in h.min(axis=0)], [float(x) for x in h.max(axis=0)])
              for h in hulls]
    zones, spawns, main_spawn, respawn, znotes = build_zones(ents, boxes, solids)

    allp = np.concatenate([p[1] for p in parts])
    lo, hi = allp.min(axis=0), allp.max(axis=0)
    spawn_zone = next(z for z in zones if z["kind"] == "SPAWN")
    manifest = {
        "id": map_id,
        "source": os.path.basename(a.vpk),
        "units": "genre units (Source units), Godot axes; x metres = x * 0.01905",
        "tier": int(doc.get("tier", a.tier)),
        "bounds": {"min": list(to_godot(lo)), "max": list(to_godot(hi))},
        "lightmap": {"file": map_id + "_lightmap.png", "width": LM_SIZE, "height": LM_SIZE},
        "lighting": lighting_of(ents),
        "surfaces": surfaces,
        "collision": collision,
        "skybox": None,
        "static_props": {"placed": 0, "drawn": 0, "stock_models": 0, "stock_standins": 0,
                         "surfaces": 0, "tinted": 0, "open_sky_lit": 0},
        "brush_entities": {"solid": 0, "faces_drawn": 0},
        "units_per_square": bi.UNITS_PER_SQUARE,
        "max_slope": bi.MAX_SLOPE_DEGREES,
        "spawn": {"origin": spawn_zone["destination"], "yaw": spawn_zone["destination_yaw"]},
        "spawns": [{"origin": s["origin"], "yaw": s["yaw"]} for s in spawns],
        "min_zone_thickness": bi.MIN_ZONE_THICKNESS,
        "zones": zones,
        "track_names": {"0": "main"},
        "respawn_volumes": respawn,
        "mechanics": {"water": [], "push": [], "gravity": [], "hurt": [], "conveyors": [],
                      "ladders": [], "blocks": []},
        "push_volumes": [],
        "trigger_volumes": [],
        "engine": "Source 2 via ValveResourceFormat",
    }
    for key in ("display_name", "author", "kind", "notes"):
        if key in doc:
            manifest[key] = doc[key]
    with open(os.path.join(d, map_id + ".json"), "w") as fh:
        json.dump(manifest, fh, indent=1)

    tris = sum(s["index_count"] for s in surfaces) // 3
    by_role = collections.Counter()
    for s in surfaces:
        by_role[s["role"]] += s["index_count"] // 3
    print("%s (%s) -> %s" % (os.path.basename(a.vpk), name, d))
    print("  %d surfaces, %d tris (%d degenerate dropped), roles: %s" % (
        len(surfaces), tris, degenerate,
        ", ".join("%s %d%%" % (r, by_role[r] * 100 // max(1, tris))
                  for r in ("PLATFORM", "RAMP", "FLOOR"))))
    print("  collision: %d convex hulls, %d triangles (written two-sided) from open or "
          "non-convex pieces" % (collision["hull_count"], collision["displacement_index_count"] // 6))
    print("  %d zones (%s)" % (len(zones), ", ".join(
        "%s x%d" % kv for kv in sorted(collections.Counter(z["kind"] for z in zones).items()))))
    for n in znotes:
        print("  note: %s" % n)
    print("  start spawn at %s units" % [round(v) for v in manifest["spawn"]["origin"]])
    return 0


if __name__ == "__main__":
    sys.exit(main())
