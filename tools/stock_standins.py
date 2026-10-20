"""Stand-ins for the solid stock-model props a map placed but could not carry (g2g-maps-stock-1).

A map's pakfile carries only the models its mapper added. A prop naming a model from the
source game's own archives was counted and left out, drawn nowhere and collided nowhere --
and 1,610 of 2,083 such placements are SOLID, so a crate, a fence or a rock a route stands
on was simply not there. This turns the ones that are *solid mass* into a plain box:

  * the box is the model's own hull (the MDL header's hull_min/hull_max), read from the
    archives on /extra at import time and used for nothing but its size. No vertex, no
    texture and no collision shape is read; the box is drawn in a stand-in material
    (`wood/`, `metal/`, `concrete/`, `models/props_wasteland/rockcliff`) that
    textures/stock/substitutes.json already maps to Kenney or ambientCG CC0 art.
  * the base engine's models are not on /extra: a variant's size from the archive stands in
    (`_sibling`), else a written estimate (`ESTIMATES`), counted apart in the manifest.
  * a machine without the archives gets only the estimates, so a map imported there differs
    from one imported here by the exact and variant boxes.

Everything else is a written `none` (RULES, last block), each with its why. The deciding
question is "is a solid box a faithful stand-in?": a window frame, an arch, a pipe elbow or a
ramp has a bounding box that fills the opening or the slope a player passes through, and an
invisible-but-wrong wall is worse than a missing prop. Lights and foliage are decided in
tools/stock_props_survey.py (none).
"""
import fnmatch
import re
import struct

import stock_archives

# (glob on the model's file name without .mdl, stand-in material or None, why). First match wins.
RULES = [
    # Not a faithful box: the bbox fills what a player passes through, or climbs.
    ("*window*", None, "frame with an opening: the bbox would wall it up"),
    ("*arch*", None, "an opening"),
    ("*door*", None, "an opening"),
    ("*dome*", None, "hollow"),
    ("*pipe*", None, "curved or thin: the bbox is far larger than the pipe"),
    ("*truss*", None, "open lattice"),
    ("*ladder*", None, "climbed, not stood on; the ladder volume is the map's own func_ladder"),
    ("*ramp*", None, "a slope: the bbox is a block"),
    ("*corner*", None, "an L: the bbox fills the inside"),
    ("*broken*", None, "irregular"),
    ("*weapon*", None, "decor"),
    # Open furniture (2026-10-17, surf_lore): the bbox of a shelving unit is a solid slab 3 m
    # wide and 2.5 m high where the original had boards with air between them.
    ("*shelves_metal*", None, "open shelving: the bbox walls up what is between the boards"),
    ("*warehouse_shelf*", None, "open shelving: the bbox walls up what is between the boards"),
    ("*bookcase*", None, "open shelving: the bbox walls up what is between the boards"),
    ("*shelves_wood*", None, "open shelving: the bbox walls up what is between the boards"),
    ("*shelf*", None, "open shelving"),
    ("*table_*", None, "a top on legs: the bbox fills the space under it"),
    ("*workspace*", None, "a bench on legs: the bbox fills the space under it"),
    ("*sawhorse*", None, "two trestles: the bbox fills the gap between them"),
    ("*forklift*", None, "an open frame with a cab: the bbox is far bigger than the machine"),
    ("*building*", None, "a skybox building: 3D sky only"),
    ("*skybx*", None, "3D sky"),
    # Solid mass.
    ("*crate*", "wood/standin_crate", "a box"),
    ("*pallet*", "wood/standin_pallet", "a stack"),
    ("*grainbasket*", "wood/standin_basket", "a low solid"),
    ("*logpile*", "wood/standin_logs", "a solid"),
    ("*box_stack*", "wood/standin_boxes", "a solid"),
    ("*paperbox*", "wood/standin_boxes", "a solid"),
    ("*fence*", "metal/standin_fence", "a wall"),
    ("*handrail*", "metal/standin_rail", "a rail"),
    ("*payphone*", "metal/standin_payphone", "a post"),
    ("*barrel*", "metal/standin_barrel", "a drum"),
    ("car_nuke*", "metal/standin_car", "a vehicle"),
    ("car00*", "metal/standin_car", "a vehicle"),
    ("*truck*", "metal/standin_truck", "a vehicle"),
    ("*trailer*", "metal/standin_trailer", "a vehicle"),
    ("*boxcar*", "metal/standin_boxcar", "a train car"),
    ("*tanker*", "metal/standin_tanker", "a train car"),
    ("*cargo_container*", "metal/standin_container", "a box"),
    ("*dumpster*", "metal/standin_dumpster", "a box"),
    ("*vending*", "metal/standin_vending", "a box"),
    ("*utilitypole*", "metal/standin_pole", "a pole"),
    ("pole_448*", "metal/standin_pole", "a pole"),
    ("*piling*", "wood/standin_piling", "a pole"),
    ("dock01_pole*", "wood/standin_piling", "a pole"),
    ("*dock_bumper*", "wood/standin_piling", "a pole"),
    ("*coolingtank*", "metal/standin_tank", "a drum"),
    ("*generator*", "metal/standin_generator", "a box"),
    ("*firehydrant*", "metal/standin_hydrant", "a post"),
    ("*concrete*", "concrete/standin_block", "a block"),
    ("*barrier*", "concrete/standin_barrier", "a block"),
    ("*barricade*", "concrete/standin_barrier", "a block"),
    ("*cinderblock*", "concrete/standin_block", "a block"),
    ("*stoneblock*", "concrete/standin_block", "a block"),
    ("*gravestone*", "concrete/standin_block", "a block"),
    ("*rockcliff*", "models/props_wasteland/rockcliff_standin", "a rock"),
    ("*rock_riverbed*", "models/props_wasteland/rockcliff_standin", "a rock"),
    ("*rockgranite*", "models/props_wasteland/rockcliff_standin", "a rock"),
    ("*militiarock*", "models/props_wasteland/rockcliff_standin", "a rock"),
    ("rocks01", "models/props_wasteland/rockcliff_standin", "a rock"),
    ("*steppingstones*", "models/props_wasteland/rockcliff_standin", "stepping stones, stood on"),
]

# Small enough, or thin enough, that a solid box is noise: below this on its longest side.
MIN_SIDE = 12.0
# Past this the bounds are a misread (a 3D-sky model or a bad header).
MAX_SIDE = 3000.0

_cache = {}


def material_for(model):
    """The stand-in material for a stock model path, or None (a written `none`)."""
    name = model.rsplit("/", 1)[-1]
    if name.endswith(".mdl"):
        name = name[:-4]
    for pat, mat, _why in RULES:
        if fnmatch.fnmatch(name, pat):
            return mat
    return None


def _exact(model):
    """(min, max) from the archive's own MDL header, or None."""
    raw = stock_archives.original(model)
    if raw is not None and len(raw) >= 128 and raw[:4] == b"IDST":
        # id, version, checksum, name[64], length, eyeposition, illumposition, hull_min, hull_max
        v = struct.unpack_from("<6f", raw, 104)
        lo, hi = v[0:3], v[3:6]
        sides = [hi[i] - lo[i] for i in range(3)]
        if all(s == s for s in v) and min(sides) > 0.5 and MIN_SIDE <= max(sides) <= MAX_SIDE:
            return (lo, hi)
    return None


def _median(xs):
    xs = sorted(xs)
    return xs[len(xs) // 2]


def _sibling(model):
    """The median hull of the archive's variants of this model (rockcliff05f -> rockcliff07e), or None.

    The base engine's models are not on /extra, but the shooter's archive carries some of
    the same families; a variant is the right order of size and the right orientation, which
    beats a guess. Only sizes are read, as for `_exact`."""
    d, _, name = model.lower().rpartition("/")
    if name.endswith(".mdl"):
        name = name[:-4]
    stem = re.sub(r"\d+[a-z]?$", "", name)
    if not stem or stem == name:
        return None
    pat = re.compile(r"^" + re.escape(stem) + r"\d+[a-z]?$")
    found = []
    for key in stock_archives._load():
        kd, _, kn = key.rpartition("/")
        if kd == d and kn.endswith(".mdl") and pat.match(kn[:-4]) and kn[:-4] != name:
            h = _exact(key)
            if h:
                found.append(h)
    if not found:
        return None
    return (tuple(_median([h[0][i] for h in found]) for i in range(3)),
            tuple(_median([h[1][i] for h in found]) for i in range(3)))


# Where neither the archive nor a variant has the model: (glob on the file name, x, y, z size,
# z of the floor under the model's origin). Sizes are estimates from the name and the closest
# shooter-archive models of the same kind (fences, rails and barriers run along y, a car's
# length is y: measured on car_nuke 85x197x63, tides_fences, handrail_*); the box is centred
# on x and y. They are written down as estimates, and the manifest counts them apart.
ESTIMATES = [
    ("exterior_fence003a", 8, 256, 128, 0),
    ("exterior_fence00*", 8, 192, 112, 0),
    ("interior_fence00*", 8, 128, 96, 0),
    ("fence0*", 8, 112, 90, 0),
    ("handrail04_long", 4, 256, 40, 0),
    ("handrail04_*", 4, 128, 40, 0),
    ("payphone001a", 14, 22, 64, 0),
    ("utilitypole0*", 24, 24, 448, 0),
    ("pole_448*", 24, 24, 448, 0),
    ("dock01_polecluster*", 96, 96, 256, 0),
    ("piling_cluster*", 96, 96, 256, 0),
    ("*_256", 32, 32, 256, 0),
    ("prefab_piling*", 32, 32, 256, 0),
    ("concrete_barrier001a", 28, 120, 48, 0),
    ("concrete_debris256barricade*", 64, 256, 64, 0),
    ("concrete_debris256pile*", 128, 256, 64, 0),
    ("concrete_debris128pile*", 128, 128, 48, 0),
    ("concrete_section128wall*", 24, 128, 128, 0),
    ("concrete_wall02a", 24, 128, 96, 0),
    ("concrete_wallpile*", 128, 128, 64, 0),
    ("truck001a", 120, 300, 140, 0),
    ("generatortrailer*", 90, 220, 110, 0),
    ("trailer*", 100, 400, 130, 0),
    ("car0*", 80, 190, 64, 0),
    ("cargo_container*", 133, 388, 130, 0),
    ("horizontalcoolingtank*", 108, 316, 123, 0),
    ("gravestone*", 32, 16, 64, 0),
    ("rockgranite*", 128, 128, 100, 0),
    ("rock_riverbed*", 180, 180, 110, 0),
    ("rockcliff*", 160, 160, 200, 0),
]


def _estimate(model):
    name = model.rsplit("/", 1)[-1]
    if name.endswith(".mdl"):
        name = name[:-4]
    for pat, sx, sy, sz, z0 in ESTIMATES:
        if fnmatch.fnmatch(name, pat):
            return ((-sx / 2.0, -sy / 2.0, float(z0)), (sx / 2.0, sy / 2.0, float(z0 + sz)))
    return None


def hull(model):
    """(min, max) of the model's hull, or None. Exact from the archive's MDL header when it
    has the model, else the median of its variants there, else `ESTIMATES`; see `source`."""
    return _resolve(model)[0]


def source(model):
    """"exact", "variant", "estimate" or None: where `hull(model)` got its size."""
    return _resolve(model)[1]


def _resolve(model):
    if model not in _cache:
        out = (_exact(model), "exact")
        if out[0] is None:
            out = (_sibling(model), "variant")
        if out[0] is None:
            out = (_estimate(model), "estimate")
        _cache[model] = out if out[0] is not None else (None, None)
    return _cache[model]


def box_mesh(lo, hi, material):
    """One mesh in read_model's shape: an axis box in the model's space, six quads."""
    pos, nrm, uvs, tris = [], [], [], []
    sx, sy, sz = (hi[i] - lo[i] for i in range(3))
    faces = [  # normal, then the quad's corners, counter-clockwise seen from outside
        ((1, 0, 0), [(hi[0], lo[1], lo[2]), (hi[0], hi[1], lo[2]), (hi[0], hi[1], hi[2]), (hi[0], lo[1], hi[2])]),
        ((-1, 0, 0), [(lo[0], hi[1], lo[2]), (lo[0], lo[1], lo[2]), (lo[0], lo[1], hi[2]), (lo[0], hi[1], hi[2])]),
        ((0, 1, 0), [(hi[0], hi[1], lo[2]), (lo[0], hi[1], lo[2]), (lo[0], hi[1], hi[2]), (hi[0], hi[1], hi[2])]),
        ((0, -1, 0), [(lo[0], lo[1], lo[2]), (hi[0], lo[1], lo[2]), (hi[0], lo[1], hi[2]), (lo[0], lo[1], hi[2])]),
        ((0, 0, 1), [(lo[0], lo[1], hi[2]), (hi[0], lo[1], hi[2]), (hi[0], hi[1], hi[2]), (lo[0], hi[1], hi[2])]),
        ((0, 0, -1), [(lo[0], hi[1], lo[2]), (hi[0], hi[1], lo[2]), (hi[0], lo[1], lo[2]), (lo[0], lo[1], lo[2])]),
    ]
    for n, quad in faces:
        base = len(pos)
        for c in quad:
            pos.append(c)
            nrm.append(n)
        # UVs in 128-unit tiles, so a stand-in texture is not stretched over a long fence.
        w = (sy if n[0] else sx) / 128.0
        h = (sz if n[2] == 0 else sy) / 128.0
        uvs.extend([(0.0, h), (w, h), (w, 0.0), (0.0, 0.0)])
        tris.extend([(base, base + 1, base + 2), (base, base + 2, base + 3)])
    return {"materials": [[material]], "positions": pos, "normals": nrm, "uvs": uvs, "triangles": tris}
