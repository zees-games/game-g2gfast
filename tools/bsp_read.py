#!/usr/bin/env python3
"""Read a VBSP map (v19-v21) far enough to get geometry and zones out of it.

[b]The reader itself is dot-map's shared one[/b] (`dot-map/tools/bsp/dotbsp/reader.py`), which
every game's converter uses, so a fix to how the format is read reaches all of them. This file
keeps the names this repository's tools import (`from bsp_read import Bsp, ...`) and the
g2gfast-specific dump below. dot-map is found as a sibling checkout (`../dot-map`, where
dot-bootstrap clones it) or at `$DOTBSP_PATH`.

Point it at a surf or bhop map and it writes an .obj of the world geometry and a .json of
the entities that become timer zones and spawns:

    tools/bsp_read.py ../inspirations/g2gfast/surf_kitsune.bsp out/

Why this is only a reader and not an importer: what a *map* is here is a `G2GMap` subclass
with `_build()` and `timer_zones()` (see maps/surf_g2g_intro.gd), and the interesting
decisions -- which volume is the START, which of thirty materials is a ramp, what a stage
is -- are judgement calls that differ per map.

[b]Units.[/b] The map stores coordinates in the units this game is authored in --
`G2GUnits.METRES_PER_UNIT` is 0.01905, 0.75 inch per unit -- so nothing is scaled here. Only
the axes are swapped, because the map is Z-up and Godot is Y-up:

    godot = (src.x, src.z, -src.y)

Emitting metres instead would be the obvious alternative and is wrong: every other number in
this project (`fallback_spawn_units`, `zone_box`, every tunable) is in genre units, and a map
file that mixed the two is a map file nobody can read.
"""

import collections
import json
import os
import sys


def _shared():
    here = os.path.dirname(os.path.abspath(__file__))
    for p in (os.environ.get("DOTBSP_PATH", ""), os.path.join(here, "..", "..", "dot-map", "tools", "bsp")):
        if p and os.path.isfile(os.path.join(p, "dotbsp", "reader.py")):
            return os.path.abspath(p)
    sys.exit("bsp_read: dot-map's shared reader was not found. Clone dot-map beside this "
             "repository (dot-bootstrap does) or set DOTBSP_PATH to dot-map/tools/bsp.")


if _shared() not in sys.path:
    sys.path.insert(0, _shared())
from dotbsp.reader import *  # noqa: E402,F401,F403
from dotbsp.reader import Bsp, SKIP_MASK, clean_material, to_godot  # noqa: E402,F401


def write_obj(bsp, out_path):
    groups = collections.defaultdict(list)
    for f in bsp.model_faces(0):
        mat, flags = bsp.face_material(f)
        if flags & SKIP_MASK:
            continue
        g = clean_material(mat)
        if f[6] >= 0:
            groups[g].extend(bsp.displacement_tris(f))
        else:
            p = bsp.face_points(f)
            for k in range(1, len(p) - 1):
                groups[g].append((p[0], p[k], p[k + 1]))

    index, verts, body = {}, [], []

    def idx(p):
        q = to_godot(p)
        q = (round(q[0], 4), round(q[1], 4), round(q[2], 4))
        if q not in index:
            index[q] = len(verts) + 1
            verts.append(q)
        return index[q]

    for g in sorted(groups):
        name = g.replace("/", "_")
        body.append("g %s\nusemtl %s" % (name, name))
        for t in groups[g]:
            a, b, c = idx(t[0]), idx(t[1]), idx(t[2])
            if a == b or b == c or a == c:
                continue          # degenerate after rounding; Godot drops these anyway
            body.append("f %d %d %d" % (a, b, c))
    with open(out_path, "w") as fh:
        fh.write("# %s -- world geometry in GENRE UNITS, Godot axes\n" % os.path.basename(bsp.path))
        fh.write("# multiply by G2GUnits.METRES_PER_UNIT for metres\n")
        for v in verts:
            fh.write("v %.4f %.4f %.4f\n" % v)
        fh.write("\n".join(body) + "\n")
    return len(verts), sum(len(v) for v in groups.values()), sorted(groups)


# Entities worth carrying across. Everything else in one of these maps is round logic,
# weapons and decoration this game has no use for.
WANTED = {
    "info_player_terrorist", "info_player_counterterrorist", "info_player_start",
    "info_teleport_destination", "trigger_teleport", "trigger_multiple",
    "trigger_once", "trigger_push", "trigger_hurt", "func_button", "worldspawn",
}


def write_entities(bsp, out_path):
    out = []
    for e in bsp.entities:
        cls = e.get("classname", "")
        if cls not in WANTED:
            continue
        rec = {k: v for k, v in e.items() if k != "hammerid"}
        if "origin" in e:
            try:
                p = [float(x) for x in e["origin"].split()]
                rec["origin_godot"] = list(to_godot(p))
            except ValueError:
                pass
        model = e.get("model", "")
        if model.startswith("*"):
            mi = int(model[1:])
            if mi < len(bsp.models):
                mins, maxs = bsp.model_bounds(mi)
                a, b = to_godot(mins), to_godot(maxs)
                rec["aabb_min_godot"] = [min(a[i], b[i]) for i in range(3)]
                rec["aabb_max_godot"] = [max(a[i], b[i]) for i in range(3)]
        out.append(rec)
    with open(out_path, "w") as fh:
        json.dump({"source": os.path.basename(bsp.path), "units": "genre units, Godot axes",
                   "entities": out}, fh, indent=1)
    return len(out)


def main(argv):
    if len(argv) < 3:
        print(__doc__.strip().splitlines()[2].strip())
        print("usage: bsp_read.py <map.bsp> <out-dir>")
        return 2
    src, out_dir = argv[1], argv[2]
    os.makedirs(out_dir, exist_ok=True)
    stem = os.path.splitext(os.path.basename(src))[0].lower()
    bsp = Bsp(src).load()
    mins, maxs = bsp.model_bounds(0)
    obj = os.path.join(out_dir, stem + ".obj")
    ents = os.path.join(out_dir, stem + "_entities.json")
    nv, nt, mats = write_obj(bsp, obj)
    ne = write_entities(bsp, ents)
    print("%s  VBSP v%d" % (os.path.basename(src), bsp.version))
    print("  world  %.0f x %.0f x %.0f units" % tuple(maxs[i] - mins[i] for i in range(3)))
    print("  %s  %d verts, %d tris, %d materials" % (obj, nv, nt, len(mats)))
    print("  %s  %d entities" % (ents, ne))
    print("  materials: %s" % ", ".join(mats[:8]) + (" ..." if len(mats) > 8 else ""))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
