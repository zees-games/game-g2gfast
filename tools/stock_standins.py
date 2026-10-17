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
  * a machine without the archives gets no stand-ins (the same as before this existed), so a
    map imported there differs from one imported here by exactly these boxes.

Everything else is a written `none` (RULES, last block), each with its why. The deciding
question is "is a solid box a faithful stand-in?": a window frame, an arch, a pipe elbow or a
ramp has a bounding box that fills the opening or the slope a player passes through, and an
invisible-but-wrong wall is worse than a missing prop. Lights and foliage are decided in
tools/stock_props_survey.py (none).
"""
import fnmatch
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
    ("*building*", None, "a skybox building: 3D sky only"),
    ("*skybx*", None, "3D sky"),
    # Solid mass.
    ("*crate*", "wood/standin_crate", "a box"),
    ("*pallet*", "wood/standin_pallet", "a stack"),
    ("*sawhorse*", "wood/standin_sawhorse", "a low solid"),
    ("*grainbasket*", "wood/standin_basket", "a low solid"),
    ("*bookcase*", "wood/standin_shelf", "a solid"),
    ("*shelves_wood*", "wood/standin_shelf", "a solid"),
    ("*workspace*", "wood/standin_bench", "a solid"),
    ("*logpile*", "wood/standin_logs", "a solid"),
    ("*table_*", "wood/standin_table", "a solid"),
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
    ("*shelves_metal*", "metal/standin_shelf", "a solid"),
    ("*warehouse_shelf*", "metal/standin_shelf", "a solid"),
    ("*coolingtank*", "metal/standin_tank", "a drum"),
    ("*generator*", "metal/standin_generator", "a box"),
    ("*forklift*", "metal/standin_forklift", "a vehicle"),
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


def hull(model):
    """(min, max) of the model's hull from the archive's MDL header, or None."""
    if model in _cache:
        return _cache[model]
    out = None
    raw = stock_archives.original(model)
    if raw is not None and len(raw) >= 128 and raw[:4] == b"IDST":
        # id, version, checksum, name[64], length, eyeposition, illumposition, hull_min, hull_max
        v = struct.unpack_from("<6f", raw, 104)
        lo, hi = v[0:3], v[3:6]
        sides = [hi[i] - lo[i] for i in range(3)]
        if all(s == s for s in v) and min(sides) > 0.5 and MIN_SIDE <= max(sides) <= MAX_SIDE:
            out = (lo, hi)
    _cache[model] = out
    return out


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
