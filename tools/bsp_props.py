#!/usr/bin/env python3
"""Static props: the `sprp` game lump, and the MDL/VVD/VTX models it places.

[b]A static prop is most of what some of these maps look like.[/b] surf_aquaflow's reef
is 737 of them, surf_summit's torches, fences and bhop blocks 976, surf_interference's
city 802; across the 26 imported maps 17 carry props and every one was simply absent --
the map rendered as its brushes over a void. The geometry is a second format family
from the .bsp's (a studio model is three files: the MDL says what the parts and
materials are, the VVD holds the vertices, the VTX the triangles, per LOD), so it lives
here rather than in bsp_read.

Only models the map carried in its own pakfile can be drawn. A prop naming a stock model
(`models/props_c17/...`) is somebody else's asset that never shipped with the map, the
same situation as a stock texture, and is counted and skipped.

[b]Lit from the map's own light probes, not from the lightmap.[/b] A prop has no
lightmap; the engine lights it from the leaf's ambient cube (six colours, one per axis
direction, that vrad sampled across every leaf). `light_block` turns one cube into a
small octahedral normal-to-colour tile that goes in the lightmap atlas beside the faces'
luxels, and each vertex's second UV points at its own normal inside that tile -- so a
prop is shaded by the same shader, through the same exposure, as the brushes around it,
and needs nothing new in the game.
"""
import math
import struct

from bsp_read import decompress_lump

LUMP_GAME = 35
LUMP_LEAF_AMBIENT_INDEX_HDR, LUMP_LEAF_AMBIENT_INDEX = 51, 52
LUMP_LEAF_AMBIENT_LIGHTING_HDR, LUMP_LEAF_AMBIENT_LIGHTING = 55, 56

# The side of one prop's lighting tile in the atlas, in texels. 6x6 is enough: the cube
# only has six numbers in it, and bilinear filtering between these texels is what turns
# them back into a smooth gradient over a curved model.
LIGHT_TILE = 6

SOLID_VPHYSICS = 6


# ------------------------------------------------------------------ game lumps
def game_lumps(bsp):
    """{four-character id: (version, bytes)} for every game lump the map has."""
    off, ln, _ = bsp.dir[LUMP_GAME]
    if not ln:
        return {}
    raw = bsp.d[off:off + ln]
    count = struct.unpack_from("<i", raw, 0)[0]
    out = {}
    for i in range(count):
        gid, _flags, version, fileofs, filelen = struct.unpack_from("<4sHHii", raw, 4 + 16 * i)
        data = bsp.d[fileofs:fileofs + filelen]
        if data[:4] == b"LZMA":
            data = decompress_lump(data)
        out[gid[::-1].decode("ascii", "replace")] = (version, data)
    return out


def static_props(bsp):
    """Every static prop: {model, origin, angles, solid, skin, flags, lighting_origin}.

    The record grows with the lump version (fade distances, then DX levels, a colour,
    CPU/GPU levels) and every field this reads is in the first 32 bytes of all of them,
    so the stride is taken from the lump itself -- what is left over, divided by the
    count -- rather than from a table of versions that the next map would be missing.
    """
    lump = game_lumps(bsp).get("sprp")
    if lump is None:
        return []
    version, d = lump
    names_n = struct.unpack_from("<i", d, 0)[0]
    names = [d[4 + 128 * i:4 + 128 * (i + 1)].split(b"\0")[0].decode("ascii", "replace")
             .replace("\\", "/").lower() for i in range(names_n)]
    o = 4 + 128 * names_n
    leaves = struct.unpack_from("<i", d, o)[0]
    o += 4 + 2 * leaves
    count = struct.unpack_from("<i", d, o)[0]
    o += 4
    if count <= 0:
        return []
    stride = (len(d) - o) // count
    props = []
    for i in range(count):
        q = o + i * stride
        origin = struct.unpack_from("<3f", d, q)
        angles = struct.unpack_from("<3f", d, q + 12)
        model, _first_leaf, _leaf_count, solid, flags = struct.unpack_from("<HHHBB", d, q + 24)
        skin = struct.unpack_from("<i", d, q + 32)[0]
        lighting = origin
        if version >= 4 and stride >= 60:
            lighting = struct.unpack_from("<3f", d, q + 44)
        scale = 1.0
        if version >= 11 and stride >= 76:
            scale = struct.unpack_from("<f", d, q + stride - 4)[0] or 1.0
        props.append({
            "model": names[model] if model < len(names) else "",
            "origin": origin, "angles": angles, "solid": solid, "skin": skin,
            "flags": flags,
            # STATIC_PROP_USE_LIGHTING_ORIGIN: the mapper moved the probe point, usually
            # out of the ground a prop is sunk into.
            # A lighting origin that is not a number is a field this version lays out
            # differently; the prop's own origin is the honest fallback.
            "lighting_origin": lighting if flags & 0x2 and all(
                math.isfinite(c) and abs(c) < 65536 for c in lighting) else origin,
            "scale": scale,
        })
    return props


def angle_matrix(angles):
    """Source's AngleMatrix: (pitch, yaw, roll) degrees to three rows, model -> world."""
    p, y, r = (math.radians(a) for a in angles)
    sp, cp = math.sin(p), math.cos(p)
    sy, cy = math.sin(y), math.cos(y)
    sr, cr = math.sin(r), math.cos(r)
    return (
        (cp * cy, sr * sp * cy - cr * sy, cr * sp * cy + sr * sy),
        (cp * sy, sr * sp * sy + cr * cy, cr * sp * sy - sr * cy),
        (-sp, sr * cp, cr * cp),
    )


def transform(m, v):
    return (m[0][0] * v[0] + m[0][1] * v[1] + m[0][2] * v[2],
            m[1][0] * v[0] + m[1][1] * v[1] + m[1][2] * v[2],
            m[2][0] * v[0] + m[2][1] * v[1] + m[2][2] * v[2])


# ---------------------------------------------------------------------- models
def _cstr(data, at):
    end = data.index(b"\0", at)
    return data[at:end].decode("ascii", "replace")


def read_model(pak, path):
    """One studio model as a list of meshes, or None when the pak does not carry it.

    Each mesh is {"materials": [candidate material names, by skin family],
    "positions": [...], "normals": [...], "uvs": [...], "triangles": [(a, b, c), ...]}
    in MODEL space. LOD 0 of the first model of every body part -- a static prop has
    one of each nearly always, and a second body part is an alternative, not an extra.
    """
    base = path[:-4] if path.endswith(".mdl") else path
    mdl = pak.get(base + ".mdl")
    vvd = pak.get(base + ".vvd")
    vtx = pak.get(base + ".dx90.vtx") or pak.get(base + ".vtx") or pak.get(base + ".dx80.vtx")
    if not (mdl and vvd and vtx) or mdl[:4] != b"IDST" or vvd[:4] != b"IDSV":
        return None

    # -- MDL: materials, skins, and where each mesh's vertices start.
    (num_tex, tex_index, num_cd, cd_index, num_skinref, num_families, skin_index,
     num_bodyparts, bodypart_index) = struct.unpack_from("<9i", mdl, 204)
    textures = []
    for i in range(num_tex):
        at = tex_index + i * 64
        textures.append(_cstr(mdl, at + struct.unpack_from("<i", mdl, at)[0])
                        .replace("\\", "/").lower())
    cds = []
    for i in range(num_cd):
        cds.append(_cstr(mdl, struct.unpack_from("<i", mdl, cd_index + 4 * i)[0])
                   .replace("\\", "/").lower().strip("/"))
    skins = []
    for fam in range(max(1, num_families)):
        skins.append([struct.unpack_from("<h", mdl, skin_index + 2 * (fam * num_skinref + k))[0]
                      for k in range(num_skinref)] if num_families else list(range(num_tex)))

    def material_names(ref):
        out = []
        for fam in skins:
            t = fam[ref] if ref < len(fam) else ref
            name = textures[t] if 0 <= t < len(textures) else ""
            out.append([(cd + "/" + name).strip("/") for cd in cds] or [name])
        return out

    # -- VVD: every vertex of LOD 0, with the fixup table applied.
    (_id, _ver, _sum, num_lods, *lod_verts) = struct.unpack_from("<4s3i8i", vvd, 0)
    num_fixups, fixup_start, vertex_start = struct.unpack_from("<3i", vvd, 48)
    raw_count = lod_verts[0]

    def vvd_vertex(i):
        q = vertex_start + i * 48
        return struct.unpack_from("<3f3f2f", vvd, q + 16)

    if num_fixups:
        order = []
        for k in range(num_fixups):
            lod, src, n = struct.unpack_from("<3i", vvd, fixup_start + 12 * k)
            if lod >= 0:
                order.extend(range(src, src + n))
    else:
        order = list(range(raw_count))
    vertices = [vvd_vertex(i) for i in order]

    # -- VTX: triangles per mesh, as indices into that mesh's own vertices.
    vtx_bodyparts, vtx_bodypart_off = struct.unpack_from("<2i", vtx, 28)
    meshes = []
    for bp in range(min(num_bodyparts, vtx_bodyparts)):
        mdl_bp = bodypart_index + bp * 16
        nummodels, _base, modelindex = struct.unpack_from("<3i", mdl, mdl_bp + 4)
        if nummodels < 1:
            continue
        mdl_model = mdl_bp + modelindex                # model 0 of this body part
        nummeshes, meshindex, _numverts, vertexindex = struct.unpack_from("<4i", mdl, mdl_model + 72)
        model_first = vertexindex // 48

        vtx_bp = vtx_bodypart_off + bp * 8
        vtx_models, vtx_model_off = struct.unpack_from("<2i", vtx, vtx_bp)
        if vtx_models < 1:
            continue
        vtx_model = vtx_bp + vtx_model_off
        lods, lod_off = struct.unpack_from("<2i", vtx, vtx_model)
        if lods < 1:
            continue
        vtx_lod = vtx_model + lod_off
        vtx_meshes, vtx_mesh_off = struct.unpack_from("<2i", vtx, vtx_lod)

        for mi in range(min(nummeshes, vtx_meshes)):
            mdl_mesh = mdl_model + meshindex + mi * 116
            material, _mi, mesh_verts, vertexoffset = struct.unpack_from("<4i", mdl, mdl_mesh)
            first = model_first + vertexoffset
            tris = _vtx_mesh_triangles(vtx, vtx_lod + vtx_mesh_off + mi * 9, mesh_verts)
            if tris is None or not tris:
                continue
            used = sorted({i for t in tris for i in t})
            if used and first + used[-1] >= len(vertices):
                continue
            remap = {i: k for k, i in enumerate(used)}
            meshes.append({
                "materials": material_names(material),
                "positions": [vertices[first + i][0:3] for i in used],
                "normals": [vertices[first + i][3:6] for i in used],
                "uvs": [vertices[first + i][6:8] for i in used],
                "triangles": [(remap[a], remap[b], remap[c]) for a, b, c in tris],
            })
    return meshes


def _vtx_mesh_triangles(vtx, mesh_at, mesh_verts):
    """The triangles of one VTX mesh, as mesh-local vertex ids, or None if unreadable.

    [b]The strip-group header is 25 bytes in one generation of the format and 33 in the
    next[/b] (two topology fields were appended), and nothing in the file says which.
    So both are tried and the first whose every index and vertex id lands inside its own
    arrays wins -- a wrong stride produces offsets that run off the end almost at once.
    """
    groups, group_off = struct.unpack_from("<2i", vtx, mesh_at)
    for size in (25, 33):
        tris = []
        ok = True
        for g in range(groups):
            at = mesh_at + group_off + g * size
            if at + 24 > len(vtx):
                ok = False
                break
            nverts, vert_off, nidx, idx_off, _nstrips, _strip_off = struct.unpack_from("<6i", vtx, at)
            if (nverts < 0 or nidx < 0 or nidx % 3 or at + vert_off + nverts * 9 > len(vtx)
                    or at + idx_off + nidx * 2 > len(vtx)):
                ok = False
                break
            ids = [struct.unpack_from("<H", vtx, at + vert_off + 9 * v + 4)[0] for v in range(nverts)]
            if any(i >= mesh_verts for i in ids):
                ok = False
                break
            idx = struct.unpack_from("<%dH" % nidx, vtx, at + idx_off)
            if any(i >= nverts for i in idx):
                ok = False
                break
            for t in range(0, nidx, 3):
                tris.append((ids[idx[t]], ids[idx[t + 1]], ids[idx[t + 2]]))
        if ok:
            return tris
    return None


# ------------------------------------------------------------------- lighting
def _leaf_of(bsp, point):
    node = bsp.models[0][9]
    while node >= 0:
        n = bsp.nodes[node]
        pl = bsp.planes[n[0]]
        d = pl[0] * point[0] + pl[1] * point[1] + pl[2] * point[2] - pl[3]
        node = n[1] if d >= 0 else n[2]
    return -1 - node


def _rgbe(b, o):
    r, g, bl, e = struct.unpack_from("<BBBb", b, o)
    s = 2.0 ** e
    return (r * s, g * s, bl * s)


class AmbientProbes:
    """The leaf ambient cubes vrad left in the map: one light probe per sample point."""

    def __init__(self, bsp):
        self.bsp = bsp
        index = bsp._lump(LUMP_LEAF_AMBIENT_INDEX)
        light = bsp._lump(LUMP_LEAF_AMBIENT_LIGHTING)
        if not index or not light:
            index = bsp._lump(LUMP_LEAF_AMBIENT_INDEX_HDR)
            light = bsp._lump(LUMP_LEAF_AMBIENT_LIGHTING_HDR)
        self.index, self.light = index, light

    def cube(self, point):
        """Six linear colours (+X, -X, +Y, -Y, +Z, -Z) at a point, or None."""
        if not self.index:
            return None
        # A prop's origin is often a few units inside the ground it stands on, which is a
        # solid leaf with no samples; the probe a player would see it lit by is above.
        for lift in (0.0, 16.0, 48.0, 128.0):
            p = (point[0], point[1], point[2] + lift)
            leaf = _leaf_of(self.bsp, p)
            if not 0 <= leaf < len(self.index) // 4:
                continue
            count, first = struct.unpack_from("<HH", self.index, leaf * 4)
            if not count:
                continue
            lf = self.bsp.leafs[leaf]
            lo, hi = lf[3:6], lf[6:9]
            best, best_d = None, None
            for s in range(first, first + count):
                o = s * 28
                if o + 28 > len(self.light):
                    break
                fx, fy, fz = struct.unpack_from("<3B", self.light, o + 24)
                q = [lo[a] + (hi[a] - lo[a]) * f / 255.0 for a, f in enumerate((fx, fy, fz))]
                d = sum((q[a] - p[a]) ** 2 for a in range(3))
                if best_d is None or d < best_d:
                    best, best_d = o, d
            if best is not None:
                return [_rgbe(self.light, best + 4 * k) for k in range(6)]
        return None


def cube_at(cube, n):
    """Source's own ambient-cube evaluation: each axis weighted by the normal squared."""
    x, y, z = n
    xx, yy, zz = x * x, y * y, z * z
    px = cube[0] if x >= 0 else cube[1]
    py = cube[2] if y >= 0 else cube[3]
    pz = cube[4] if z >= 0 else cube[5]
    return tuple(xx * px[k] + yy * py[k] + zz * pz[k] for k in range(3))


def octahedral_decode(u, v):
    """A unit normal from octahedral coordinates in [0, 1]^2."""
    x, y = u * 2.0 - 1.0, v * 2.0 - 1.0
    z = 1.0 - abs(x) - abs(y)
    if z < 0:
        x, y = ((1.0 - abs(y)) * (1 if x >= 0 else -1), (1.0 - abs(x)) * (1 if y >= 0 else -1))
    ln = math.sqrt(x * x + y * y + z * z) or 1.0
    return (x / ln, y / ln, z / ln)


def octahedral_encode(n):
    """Octahedral coordinates in [0, 1]^2 of a normal (Source axes)."""
    x, y, z = n
    s = abs(x) + abs(y) + abs(z) or 1.0
    x, y, z = x / s, y / s, z / s
    if z < 0:
        x, y = ((1.0 - abs(y)) * (1 if x >= 0 else -1), (1.0 - abs(x)) * (1 if y >= 0 else -1))
    return (x * 0.5 + 0.5, y * 0.5 + 0.5)


def light_block(cube):
    """A LIGHT_TILE square of linear colours: texel (i, j) is the cube seen along the
    normal whose octahedral coordinate is that texel's centre."""
    rows = []
    for j in range(LIGHT_TILE):
        row = []
        for i in range(LIGHT_TILE):
            n = octahedral_decode((i + 0.5) / LIGHT_TILE, (j + 0.5) / LIGHT_TILE)
            row.append(cube_at(cube, n))
        rows.append(row)
    return rows


# ------------------------------------------------------------------- collision
METRES_PER_INCH = 0.0254


def read_phy(pak, path):
    """A model's collision as convex pieces in MODEL space (Source units), or None.

    The .phy is the physics engine's own compact format: per solid a "compact surface"
    whose "ledges" are convex hulls given as triangles over a shared point table, in
    metres and with the physics engine's axes (y down, z forward). Every ledge's points
    are one convex hull, which is exactly the shape the world's brushes already have
    here -- so a solid prop becomes more of the same `ConvexPolygonShape3D`s, and the
    genre's rule that a sliding hull meets convex pieces and not loose triangles holds.
    """
    base = path[:-4] if path.endswith(".mdl") else path
    phy = pak.get(base + ".phy")
    if not phy or len(phy) < 16:
        return None
    header_size, _id, solids, _sum = struct.unpack_from("<4i", phy, 0)
    at = header_size
    hulls = []
    for _s in range(solids):
        if at + 4 > len(phy):
            break
        size = struct.unpack_from("<i", phy, at)[0]
        start = at + 4
        at = start + size
        cs = start
        if phy[cs:cs + 4] == b"VPHY":
            cs += 28
        # compactsurface_t is 48 bytes; its ledges follow it, then their points, then
        # the ledge tree, whose offset is the one bound the header gives.
        tree = struct.unpack_from("<i", phy, cs + 32)[0]
        end = cs + tree if tree > 0 else at
        off = cs + 48
        points_start = end
        while off + 16 <= min(end, points_start, len(phy)):
            point_off, _client, flags, ntri = struct.unpack_from("<iiIh", phy, off)
            ledge_size = (flags >> 8) * 16
            if ledge_size <= 0:
                break
            pts_at = off + point_off
            points_start = min(points_start, pts_at)
            ids = set()
            for t in range(ntri):
                tri = off + 16 + t * 16
                for e in range(3):
                    ids.add(struct.unpack_from("<H", phy, tri + 4 + e * 4)[0])
            hull = []
            for i in sorted(ids):
                q = pts_at + i * 16
                if q + 12 > len(phy):
                    continue
                x, y, z = struct.unpack_from("<3f", phy, q)
                hull.append((x / METRES_PER_INCH, z / METRES_PER_INCH, -y / METRES_PER_INCH))
            if len(hull) >= 4:
                hulls.append(hull)
            off += ledge_size
    return hulls


class GroundLight:
    """The baked light on the floor under a point: the luxel a prop is standing on.

    [b]The ambient cube alone is about a hundredth of what the floor beside a prop
    receives[/b] (surf_mesa: cube 0.06 against a median luxel of 9.4), because vrad
    leaves direct light out of it -- the engine adds the sun and the nearest lights to a
    prop at load time, from its world-light list, with visibility. Doing that here is a
    ray tracer. The floor's own luxel already IS that answer at the prop's feet, shadows
    included, so it is used as the light from above and, softened, from the sides; the
    cube keeps its direction and colour on top.
    """

    CELL = 512.0

    def __init__(self, bsp, faces, light):
        self.bsp, self.light = bsp, light
        self.grid = {}
        for f in faces:
            if f[9] < 0:
                continue
            pl = bsp.planes[f[0]]
            if pl[2] < 0.3:
                continue
            pts = bsp.face_points(f)
            if len(pts) < 3:
                continue
            xs, ys = [p[0] for p in pts], [p[1] for p in pts]
            for cx in range(int(min(xs) // self.CELL), int(max(xs) // self.CELL) + 1):
                for cy in range(int(min(ys) // self.CELL), int(max(ys) // self.CELL) + 1):
                    self.grid.setdefault((cx, cy), []).append((f, pts, pl))

    def at(self, point, reach=512.0):
        """Linear RGB of the highest lit upward face under `point`, or None."""
        x, y, z = point
        best, best_z = None, None
        for f, pts, pl in self.grid.get((int(x // self.CELL), int(y // self.CELL)), []):
            if not _inside_xy(pts, x, y):
                continue
            fz = (pl[3] - pl[0] * x - pl[1] * y) / pl[2]
            if fz > z + 16.0 or fz < z - reach:
                continue
            if best_z is None or fz > best_z:
                best, best_z = f, fz
        if best is None:
            return None
        return self._luxel(best, (x, y, best_z))

    def open_sky(self, share=0.75):
        """The light of a well-lit floor of this map: the luxel at the centre of every lit
        upward face, `share` of the way up by brightness. For a prop with no lit floor
        under it -- a 3D-skybox prop, which stands over its sky room's tool walls -- the
        nearest thing the map says about light in the open."""
        seen, lit = set(), []
        for cell in self.grid.values():
            for f, pts, pl in cell:
                if id(f) in seen:
                    continue
                seen.add(id(f))
                c = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts),
                     sum(p[2] for p in pts) / len(pts))
                v = self._luxel(f, c)
                if v is not None:
                    lit.append(v)
        if not lit:
            return None
        return _typical(lit, share)

    def local(self, point, radius=640.0, share=0.5):
        """The typical light on the lit upward faces within `radius` of `point` (horizontally),
        or None with fewer than three.

        [b]For a box standing where no baked light is under it.[/b] `at` reads the one
        floor beneath a prop, which is the wrong floor for a box on a roof, on sand or on
        a surface the compiler gave no lightmap: it finds the interior a storey down, 1000
        times dimmer than the sun on the sand (surf_dust2's crates drew black in full
        sun), and a prop with no floor at all drew unlit, white. What is lit around it, at
        the median, is what the map says about the light at that spot without being
        decided by one luxel."""
        x, y, _z = point
        r0, r1 = int((x - radius) // self.CELL), int((x + radius) // self.CELL)
        c0, c1 = int((y - radius) // self.CELL), int((y + radius) // self.CELL)
        seen, lit = set(), []
        for cx in range(r0, r1 + 1):
            for cy in range(c0, c1 + 1):
                for f, pts, pl in self.grid.get((cx, cy), []):
                    if id(f) in seen:
                        continue
                    seen.add(id(f))
                    c = (sum(p[0] for p in pts) / len(pts), sum(p[1] for p in pts) / len(pts),
                         sum(p[2] for p in pts) / len(pts))
                    if (c[0] - x) ** 2 + (c[1] - y) ** 2 > radius * radius:
                        continue
                    v = self._luxel(f, c)
                    if v is not None:
                        lit.append(v)
        if len(lit) < 3:
            return None
        return _typical(lit, share)

    def _luxel(self, f, p):
        ti = self.bsp.texinfo[f[5]]
        s = p[0] * ti[8] + p[1] * ti[9] + p[2] * ti[10] + ti[11] - f[11]
        t = p[0] * ti[12] + p[1] * ti[13] + p[2] * ti[14] + ti[15] - f[12]
        w, h = f[13] + 1, f[14] + 1
        i = min(max(int(round(s)), 0), w - 1)
        j = min(max(int(round(t)), 0), h - 1)
        o = f[9] + (j * w + i) * 4
        if o + 4 > len(self.light):
            return None
        return _rgbe(self.light, o)


def _typical(lit, share):
    """One colour for a set of luxels: the `share` luxel's brightness, in the average colour
    of the bright half (see GroundLight.open_sky for why not one luxel's colour)."""
    lum = lambda v: 0.2126 * v[0] + 0.7152 * v[1] + 0.0722 * v[2]
    lit = sorted(lit, key=lum)
    target = lum(lit[min(len(lit) - 1, int(len(lit) * share))])
    band = lit[len(lit) // 2:]
    mean = tuple(sum(v[c] for v in band) / len(band) for c in range(3))
    scale = target / lum(mean) if lum(mean) > 0 else 0.0
    return tuple(c * scale for c in mean)


def _inside_xy(pts, x, y):
    inside = False
    n = len(pts)
    for k in range(n):
        x1, y1 = pts[k][0], pts[k][1]
        x2, y2 = pts[(k + 1) % n][0], pts[(k + 1) % n][1]
        if (y1 > y) != (y2 > y) and x < (x2 - x1) * (y - y1) / ((y2 - y1) or 1e-9) + x1:
            inside = not inside
    return inside


def lit_cube(cube, ground):
    """The ambient cube with the floor's light added: all of it from above, most of it
    from the sides, a quarter from below. `cube` may be None (no probe)."""
    base = cube or [(0.0, 0.0, 0.0)] * 6
    if ground is None:
        return base if cube else None
    weight = (0.7, 0.7, 0.7, 0.7, 1.0, 0.25)
    return [tuple(base[k][c] + ground[c] * weight[k] for c in range(3)) for k in range(6)]
