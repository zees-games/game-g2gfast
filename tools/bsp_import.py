#!/usr/bin/env python3
"""Turn a Source .bsp into an importable g2gfast map: mesh, textures, baked light, zones.

    tools/bsp_import.py ../inspirations/g2gfast/surf_kitsune.bsp maps/imported --id surf_kitsune

Writes into <out>/<id>/:

    <id>.bin              vertex and index data, one block per material
    <id>.json             the manifest: surfaces, materials, zones, spawns
    <id>_lightmap.png     the map's own baked lighting, packed into one atlas
    textures/*.png        every texture the .bsp carried in its pakfile

That directory IS the map. There is no scene and no script per map: every imported map
is the one `maps/imported_map.tscn` that ships inside the build, pointed at a different
manifest. A generated `<id>.tscn` cannot work for a map that arrives after the export --
`res://` is a read-only PCK in a shipped build -- so a map is data at a path, and the
paths the game searches include ones outside `res://` for exactly that reason.

[b]Why a mesh binary and not glTF.[/b] The baked lighting needs a second UV set,
and the route through glTF into Godot's importer decides for you what a second UV
set means -- it lands on `ao_texture` (greyscale, so the coloured neon that is this
map's entire character goes grey) or on `emission` (additive, so it washes out).
Building the [ArrayMesh] in [method ArrayMesh.add_surface_from_arrays] costs about
twenty lines, keeps ARRAY_TEX_UV2 as what it is, and is the shape every other map in
this repository already has: geometry made in code.

[b]Units.[/b] Positions are in genre units, Godot axes. See tools/bsp_read.py.
"""

import argparse
import collections
import fnmatch
import hashlib
import io
import json
import math
import os
import re
import struct
import sys
import zipfile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from bsp_read import (Bsp, SKIP_MASK, SURF_SKY, SURF_SKY2D, clean_material, to_godot, yaw_to_godot,  # noqa: E402
                      LUMP_ENTITIES, MASK_PLAYERSOLID, CONTENTS_PLAYERCLIP,
                      SOLID_BRUSH_ENTITIES, NONSOLID_BRUSH_ENTITIES)
import vtf  # noqa: E402
import stock_archives  # noqa: E402
import bsp_mechanics  # noqa: E402
import bsp_props  # noqa: E402
import stock_standins  # noqa: E402

LUMP_LIGHTING, LUMP_PAKFILE, LUMP_PLANES = 8, 40, 1
ATLAS_W = 1024

# Where a map's MEDIAN luxel lands, as a linear value. See build_lightmap.
#
# [b]Anchored on the median rather than on a high quantile, and that is the robust half
# of the exposure.[/b] Setting the white point to the 99th percentile is the obvious
# reading of "use the range", and it hands the exposure of the whole map to whatever its
# brightest few luxels are: `surf_mesa` has a sky and a sane spread and exposed fine,
# `surf_beginner2` has a handful of very bright sources over an otherwise dim map and
# rendered almost black, because its p99 was an outlier rather than its top end. The
# median is a statistic an outlier cannot move.
#
# 0.023 is a code value of about 47 in the sRGB atlas, which is where surf_mesa's median
# sat when it was exposed to its own p99 and rendered against a reference frame. It is a
# level, not a curve: the scale below is linear, so every ratio in the map is the same
# whatever this number is, and changing it moves the whole map up or down together.
EXPOSURE_MEDIAN_TARGET = 0.023
LM_PAD = 1

# The least a zone volume may measure on any axis, in genre units.
#
# [b]Source sweeps its trigger tests and dot-timer samples a point per tick.[/b] A
# `trigger_teleport` in a surf map is the pit, and a mapper draws it as a 16-unit
# plane because Source asks "did the player's path cross this". dot-timer's index asks
# `contains(point)` once a tick, so at 3500 u/s and 128 Hz -- 27 units of travel per
# tick -- a falling player steps straight over a 16-unit plane and keeps falling for
# ever, which is precisely the bug dot-timer's RESPAWN zones exist to prevent.
#
# The plane is therefore inflated into a slab centred on it. Centred, and not extended
# downward: downward is right for a pit and wrong for a boundary trigger above the
# play space, and a slab centred on the original plane is the honest approximation of
# the swept test Source was doing. 192 units is seven ticks of travel at the genre's
# ceiling speed.
MIN_ZONE_THICKNESS = 192.0

# One tick of travel at the genre's ceiling, rounded up: 3500 u/s at 128 Hz is 27.3
# units. A pit the importer could not grow to MIN_ZONE_THICKNESS is still made this deep.
TICK_DEPTH = 32.0

# Where the g2gfast roles come from: the angle of the surface, not the name on it.
#
# [b]The material name was a guess and the slope is a fact.[/b] This used to be a list
# of regexes over texture names -- `concretefloor039a` is a ramp, `nodraw` is a
# platform -- on the reasoning that the name is the only intent a compiled .bsp still
# carries. It is not. The geometry carries the one piece of intent that matters here,
# because in this genre what a surface is FOR is exactly what its angle lets a player
# do with it, and that is a number in the plane lump. Measured over the maps in
# `inspirations/`, face area by normal Z comes out in three clean bands every time:
# ~30-43% at +1.0 (floors), ~46-55% at 0.0 (walls) and a distinct 1.6-8.5% at +0.6/+0.7
# -- the ride. The regexes scored none of that: surf_beginner2 came out 97% FLOOR, one
# flat grey mass with the ramps in it invisible.
#
# The threshold is the game's own. A player stands on a surface up to
# `G2GConfig.max_slope` and slides off anything steeper, so that angle is precisely the
# line between "a platform" and "a ramp" -- and painting it anywhere else would be a
# texture that lies about what the movement will do. The default below is that cvar's
# default; `--max-slope` is there for an operator who has changed it.
MAX_SLOPE_DEGREES = 45.57

# Below this the surface is a wall, not a ride. A plane at 87 degrees is vertical for
# every purpose a player has, and calling it a ramp paints slivers of ride colour down
# every wall in the map that was not drawn exactly on the grid.
RAMP_MIN_NORMAL_Z = 0.05


def role_for_normal(nz, cos_limit):
    """What a surface is for, from which way it faces. Source axes: +Z is up."""
    if nz >= cos_limit:
        return "PLATFORM"       # a player stands here
    if nz > RAMP_MIN_NORMAL_Z:
        return "RAMP"           # a player slides off here: the ride
    return "FLOOR"              # walls, ceilings and undersides


# How many of the genre's units one grid square covers. [G2GTextures]'s own
# UNITS_PER_SQUARE, and it has to stay that way: a square is 64 units on every surface
# in this game, in a hand-built map and an imported one alike, because its size in the
# world is the only cue a player has for how fast the ground is moving past them.
#
# [b]A prototype UV here is measured in SQUARES, not in tiles.[/b] How many squares are
# in one tile is a property of the image -- the vendored Kenney tile has eight and the
# generated fallback has four -- and it is not known here, because which of the two a
# map ends up drawn in is decided at load time by what is installed. So the mesh
# carries the part that is about the world and the material scales it by the part that
# is about the texture. Baking a tile count in instead would be a map that silently
# halves its grid the day the texture set is swapped.
UNITS_PER_SQUARE = 64.0


def tangent_frame(n):
    """Two unit axes in the plane of a face, for projecting a prototype grid onto it.

    [b]Not an axis-aligned projection, which is the obvious alternative.[/b] Dropping
    the dominant axis and using the other two is one line, and on a 45-degree surf ramp
    it stretches the grid by a factor of root two along the exact direction the player
    is travelling -- so the one surface whose texture is being read for speed is the one
    surface whose texture is the wrong size. A frame built in the plane has no stretch
    anywhere, and it falls out of it that one axis runs straight down the slope, which
    is the line a surfer steers by.
    """
    up = (0.0, 0.0, 1.0) if abs(n[2]) < 0.9 else (0.0, 1.0, 0.0)
    t = (up[1] * n[2] - up[2] * n[1], up[2] * n[0] - up[0] * n[2],
         up[0] * n[1] - up[1] * n[0])
    ln = math.sqrt(t[0] ** 2 + t[1] ** 2 + t[2] ** 2) or 1.0
    t = (t[0] / ln, t[1] / ln, t[2] / ln)
    b = (n[1] * t[2] - n[2] * t[1], n[2] * t[0] - n[0] * t[2], n[0] * t[1] - n[1] * t[0])
    return t, b


# ---------------------------------------------------------------- pakfile ----
def read_pak(bsp, notes):
    """Every file the .bsp carried in its embedded zip, by lowercased name.

    [b]Read one entry at a time, and let a broken one be missing rather than fatal.[/b]
    The obvious version is a dict comprehension over `namelist()`, and it was one until
    `bhop_platformer_fxd` -- a fifteen-year-old map whose pakfile has a bad CRC on a single
    soundscape .txt that nothing here reads. `ZipFile.read` raises on that entry, the
    comprehension propagates it, and 121 MB of perfectly good geometry imports as a
    traceback. At one map a person re-packs the zip by hand; at fifty, one bad byte in a
    file the importer does not even look at must not cost the map.

    A skipped entry is reported rather than swallowed: if the missing file turns out to
    have been a .vtf or a .vmt, the map imports with a prototype grid where its own
    texture should be, and the note is the only thing that says why.
    """
    off, ln, _ = bsp.dir[LUMP_PAKFILE]
    if not ln:
        return {}
    try:
        z = zipfile.ZipFile(io.BytesIO(bsp.d[off:off + ln]))
    except zipfile.BadZipFile as e:
        notes.append("pakfile is unreadable (%s); every surface falls back to the "
                     "prototype grid" % e)
        return {}
    pak, bad = {}, []
    for info in z.infolist():
        n = info.filename
        # [b]A name the zip did not flag as UTF-8 is decoded by Python as cp437[/b], which
        # turns the mapper's codepage byte for ü into `ⁿ` (and Ü into `▄`), so it never
        # matched the material name. Re-read those bytes as Latin-1, as Bsp.texnames is.
        key = n if info.flag_bits & 0x800 else n.encode("cp437").decode("latin-1")
        try:
            pak[key.lower()] = z.read(info)
        except (zipfile.BadZipFile, EOFError, OSError) as e:
            bad.append("%s (%s)" % (n, e.__class__.__name__))
    if bad:
        notes.append("%d of %d pakfile entries could not be read and were skipped: %s"
                     % (len(bad), len(z.namelist()), ", ".join(sorted(bad)[:5])
                        + (" ..." if len(bad) > 5 else "")))
    return pak


def vmt_basetexture(src):
    """The $basetexture out of a VMT.

    A patch material (`Patch { include ... replace { $basetexture x } }`) names its
    base inside a nested block, so a first-match regex over the whole file is right
    and walking only the top level is not.
    """
    txt = src.decode("latin-1")  # the codepage the names are in; see Bsp.texnames
    txt = re.sub(r"//[^\n]*", "", txt)
    # [b]A quoted value runs to the closing quote, spaces and all.[/b] Matching up to the
    # first space read `"hammer textures/bhop_eazy/31_e_brick_blue"` as `hammer`, found no
    # such VTF, and drew every face of bhop_eazy in the prototype grid with its own
    # textures sitting in the pakfile. A leading `/` goes for `clean_material`'s reason
    # (bhop_tesquo_v2's `/cncr04s/...`, a quarter of that map).
    m = (re.search(r'"?\$basetexture"?\s+"([^"\n]+)"', txt, re.I)
         or re.search(r'"?\$basetexture"?\s+([^"\s]+)', txt, re.I))
    base = m.group(1).replace("\\", "/").lower().strip().lstrip("/") if m else None
    if base and base.endswith(".vtf"):
        base = base[:-4]
    translucent = bool(re.search(r'"?\$(translucent|alphatest)"?\s+"?1', txt, re.I))
    return base, translucent


def vmt_additive(src):
    """Whether a VMT draws ADDED to what is behind it (`$additive 1`), and whether it is
    two-sided (`$nocull 1`).

    [b]An additive texture is drawn on black, and the black is the transparent part.[/b]
    surf_lt_unicorn rings its spawn with rainbow bands and tubes that are white streaks on
    black in `unlitgeneric $additive` materials: added, the black adds nothing and the
    streaks glow; drawn opaque, as every one of them was until 2026-10-11, they are black
    sheets with white blobs on them, wrapped round the camera. Read with comments stripped,
    because mappers comment `$nocull` out and leave it in the file.
    """
    txt = re.sub(r"//[^\n]*", "", src.decode("latin-1"))
    additive = bool(re.search(r'"?\$additive"?\s+"?1', txt, re.I))
    nocull = bool(re.search(r'"?\$nocull"?\s+"?1', txt, re.I))
    return additive, nocull


def vmt_blend(src):
    """The `$basetexture2` of a `WorldVertexTransition` VMT, or None.

    Only that shader blends. bhop_supernova's rock is `LightmappedGeneric` with a
    `$basetexture2` in it, which that shader never reads, so naming one is not enough.
    """
    txt = re.sub(r"//[^\n]*", "", src.decode("latin-1")).strip()
    shader = txt.split(None, 1)[0].strip('"').lower() if txt else ""
    if shader != "worldvertextransition":
        return None
    m = (re.search(r'"?\$basetexture2"?\s+"([^"\n]+)"', txt, re.I)
         or re.search(r'"?\$basetexture2"?\s+([^"\s]+)', txt, re.I))
    base = m.group(1).replace("\\", "/").lower().strip().lstrip("/") if m else None
    if base and base.endswith(".vtf"):
        base = base[:-4]
    return base or None


SKY_SUFFIXES = ("rt", "bk", "lf", "ft", "up", "dn")


def packed_sky_faces(bsp, pak, tex_dir, notes):
    """The map's own 2D sky, when its pakfile carries all six faces: {suffix: png} or {}.

    [b]A packed sky was drawn as one flat colour.[/b] Thirty-six of the seventy-five held
    maps ship `materials/skybox/<skyname><rt|bk|lf|ft|up|dn>`, and the game drew each as
    G2GLighting's procedural sky, coloured from a table of stock sky NAMES -- surf_beginner2's
    `sky47` is a sunset, and it rendered as a clear blue noon (against the WR run's own
    footage, 2026-10-09). The six faces are decoded here and drawn by g2g_sky.gdshader in
    the engine's own face layout. All six or nothing: a sky with a missing face is a hole
    in the horizon, which is worse than a colour. An HDR sky the decoder cannot read
    (`militia_hdr`) falls back to the colour, with a note.
    """
    world = next((e for e in bsp.entities if e.get("classname") == "worldspawn"), {})
    sky = str(world.get("skyname", "")).strip().lower()
    if not sky:
        return {}
    out = {}
    for suffix in SKY_SUFFIXES:
        vmt = pak.get("materials/skybox/%s%s.vmt" % (sky, suffix))
        base = vmt_basetexture(vmt)[0] if vmt is not None else ""
        raw = pak.get("materials/%s.vtf" % base) if base else None
        if raw is None:
            raw = pak.get("materials/skybox/%s%s.vtf" % (sky, suffix))
        if raw is None:
            return {}
        if stock_archives.is_stock("materials/%s.vtf" % (base or "skybox/%s%s" % (sky, suffix)), raw, vtf.decode):
            # The source game's own sky, packed by the mapper (bhop_arcane_v2's `hav`): not
            # ours to draw, so the sky is the procedural one from the map's own colours.
            notes.append("sky %s is the source game's own, packed into the map; drawn as a "
                         "colour instead" % sky)
            for face in SKY_SUFFIXES:
                for stale in ("sky_%s.png" % face, "sky_%s.png.import" % face):
                    if os.path.exists(os.path.join(tex_dir, stale)):
                        os.remove(os.path.join(tex_dir, stale))
            return {}
        try:
            w, h, px = vtf.decode(raw)
        except ValueError as e:
            notes.append("sky %s%s does not decode (%s); the sky stays a colour" % (sky, suffix, e))
            return {}
        os.makedirs(tex_dir, exist_ok=True)
        name = "sky_%s.png" % suffix
        vtf.write_png(os.path.join(tex_dir, name), w, h, px, opaque=True)
        out[suffix] = name
    return out


PRIVATE_REFERENCE = "/extra/g2g-ref/materials"
_private_hashes = None


def is_private_copy(png_path):
    """Whether a decoded texture is byte for byte one of the private reference copies.

    [b]A mapper can pack the source game's own texture into the .bsp[/b] (bhop_arcane_v2's
    number decals, a river sheet four maps copied), and then it decodes like the map's
    own. Christian's rule is that the source game's textures are never used, and
    publish_maps.gd refuses a map holding one, so the importer drops it here and the
    surface goes to a stand-in or the grid like any texture that did not ship. Only
    where `/extra/g2g-ref` exists, which is the machine maps are imported on; the
    reference copies are written by the same decoder, so equal bytes mean the same image.
    """
    global _private_hashes
    if _private_hashes is None:
        _private_hashes = set()
        for root, _, files in os.walk(PRIVATE_REFERENCE):
            for f in files:
                with open(os.path.join(root, f), "rb") as fh:
                    _private_hashes.add(hashlib.sha256(fh.read()).hexdigest())
    if not _private_hashes:
        return False
    with open(png_path, "rb") as fh:
        return hashlib.sha256(fh.read()).hexdigest() in _private_hashes


def png_name(base):
    """The file a decoded texture is written to: the path flattened, and ASCII.

    A non-ASCII name (`customs/früchte/...`) is spelled out as `_xx` hex, because the
    file travels in a pack through a URL, a zip and a browser's IndexedDB, and an ASCII
    path is one fewer encoding for each of them to disagree about.
    """
    flat = base.replace("/", "_")
    return "".join(c if ord(c) < 128 else "_%02x" % ord(c) for c in flat) + ".png"


def extract_textures(pak, materials, tex_dir, blends=None, notes=None):
    """Decode every referenced texture the map carried with it.

    Returns {material: (png filename or None, translucent)}. A material whose texture
    lives in the source game's own archives -- `concrete/concretefloor039a` is stock -- is
    not an error and not a guess: it comes back None and the map script paints it with
    the prototype set instead, keyed by what the surface is FOR.

    [b]A texture that is flat black comes back None too.[/b] It decodes, it is the
    right size, and it is 1024x1024 pixels of nothing -- `tools/toolsblack` and
    `cs_italy/black` between them cover 5.9 billion square units of the eight maps.
    Drawn faithfully that is a hole in the map as far as anybody playing can tell, and
    the whole reason the prototype set exists is to stand in for a surface there is no
    picture of. Having one and having a black one are the same situation. See
    [method vtf.is_blank] for why the rule is flat-and-dark rather than just dark.

    `blends`, when given, is filled with {material: png} for the second texture of every
    `WorldVertexTransition` material whose two textures both shipped -- see `vmt_blend`.
    """
    os.makedirs(tex_dir, exist_ok=True)
    out, written = {}, {}

    def dropped_private(name):
        """Remove [param name] again when it is a private reference copy; see is_private_copy."""
        path = os.path.join(tex_dir, name)
        if not is_private_copy(path):
            return False
        for stale in (path, path + ".import"):
            if os.path.exists(stale):
                os.remove(stale)
        if notes is not None:
            notes.append("%s is the source game's own texture packed into the map; dropped "
                         "(stand-in or grid instead)" % name)
        return True

    def stock(base, raw):
        """True, and any earlier import's file removed, when [param raw] is the source game's
        own texture packed into the map; see tools/stock_archives.py."""
        if not stock_archives.is_stock("materials/%s.vtf" % base, raw, vtf.decode):
            return False
        path = os.path.join(tex_dir, png_name(base))
        for stale in (path, path + ".import"):
            if os.path.exists(stale):
                os.remove(stale)
        if notes is not None:
            notes.append("%s is the source game's own texture packed into the map; dropped "
                         "(stand-in or grid instead)" % base)
        return True

    def decode(base):
        """png name, or None for a texture that is absent, undecodable or blank."""
        if base in written:
            return written[base]
        raw = pak.get("materials/%s.vtf" % base)
        if raw is None:
            return None
        if stock(base, raw):
            written[base] = None
            return None
        try:
            w, h, px = vtf.decode(raw)
        except ValueError:
            return None
        if vtf.is_blank(px):
            written[base] = None
            return None
        name = png_name(base)
        vtf.write_png(os.path.join(tex_dir, name), w, h, px, opaque=vtf.is_opaque(px))
        if dropped_private(name):
            written[base] = None
            return None
        ask_for_mipmaps(os.path.join(tex_dir, name))
        written[base] = name
        return name

    for mat in materials:
        vmt = pak.get("materials/%s.vmt" % mat)
        if vmt is None:
            out[mat] = (None, False)
            continue
        base, translucent = vmt_basetexture(vmt)
        if not base:
            out[mat] = (None, translucent)
            continue
        raw = pak.get("materials/%s.vtf" % base)
        if raw is None:
            out[mat] = (None, translucent)
            continue
        if base not in written and stock(base, raw):
            written[base] = None
            out[mat] = (None, translucent)
            continue
        if base in written:
            # None here is a texture already found to be blank, not one never seen:
            # `written` is keyed by base texture and a second material pointing at the
            # same blank one has to reach the same answer, translucency included.
            out[mat] = (written[base], translucent if written[base] else False)
            continue
        name = png_name(base)
        try:
            w, h, px = vtf.decode(raw)
        except ValueError:
            out[mat] = (None, translucent)      # HDR cubemaps and other oddities
            continue
        if vtf.is_blank(px):
            out[mat] = (None, False)
            written[base] = None
            continue
        opaque = not translucent and vtf.is_opaque(px)
        vtf.write_png(os.path.join(tex_dir, name), w, h, px, opaque=opaque)
        if dropped_private(name):
            written[base] = None
            out[mat] = (None, translucent)
            continue
        ask_for_mipmaps(os.path.join(tex_dir, name))
        written[base] = name
        out[mat] = (name, translucent and not opaque)
    for mat in materials if blends is not None else ():
        second = vmt_blend(pak["materials/%s.vmt" % mat]) if out[mat][0] else None
        png2 = decode(second) if second else None
        if png2:
            blends[mat] = png2
    return out


def ask_for_mipmaps(png_path):
    """Makes Godot import [param png_path] with mipmaps, by writing its `.import` first.

    [b]Every texture the importer wrote was imported without mipmaps[/b] (`g2g-maps-1`):
    Godot writes a new `.png.import` with `mipmaps/generate=false`, and it would only turn
    them on itself on noticing the texture in a 3D material, which a texture assigned to a
    shader parameter from a script never is. The shaders sample with
    `filter_linear_mipmap_anisotropic` and had one level to sample, so a textured floor
    shimmered at distance. An existing `.import` keeps everything Godot wrote in it except
    that one line, and loses its `[remap]` and `[deps]` so the next `--import` rebuilds the
    texture rather than trusting the cached one; a new one is the two lines Godot needs.
    Idempotent: a file already asking for mipmaps is left alone.
    """
    imp = png_path + ".import"
    params, uid = {}, None
    if os.path.exists(imp):
        with open(imp, encoding="utf-8") as f:
            text = f.read()
        if "mipmaps/generate=true" in text:
            return
        section = None
        for line in text.splitlines():
            line = line.strip()
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
            elif section == "remap" and line.startswith("uid="):
                uid = line
            elif section == "params" and "=" in line:
                k, v = line.split("=", 1)
                params[k] = v
    params["mipmaps/generate"] = "true"
    with open(imp, "w", encoding="utf-8") as f:
        f.write('[remap]\n\nimporter="texture"\ntype="CompressedTexture2D"\n')
        if uid:
            f.write(uid + "\n")
        f.write("\n[params]\n\n")
        for k, v in params.items():
            f.write("%s=%s\n" % (k, v))


# --------------------------------------------------------------- lightmap ----
def lightmap_quantile(light, lit, q, stride=7):
    """The q-th quantile of a map's lit luxel luminances, in Source's linear units.

    Sampled rather than counted in full -- a big map has two million luxels and every
    one of them costs a Python loop -- and every seventh is plenty for a quantile that
    only has to be right to within a stop. Falls back to 1.0 for a map with no lighting
    at all, which makes the exposure below a no-op rather than a divide by zero.
    """
    vals = []
    for f in lit:
        o, w, h = f[9], f[13] + 1, f[14] + 1
        end = o + w * h * 4
        for t in range(o, min(end, len(light) - 3), 4 * stride):
            e = light[t + 3]
            scale = 2.0 ** (e - 256 if e > 127 else e)
            vals.append((light[t] * 0.2126 + light[t + 1] * 0.7152
                         + light[t + 2] * 0.0722) * scale)
    if not vals:
        return 1.0
    vals.sort()
    return max(vals[min(int(q * (len(vals) - 1)), len(vals) - 1)], 1e-6)


def build_lightmap(bsp, faces, path, blocks=()):
    """Pack every lit face's luxels into one atlas and return its placements.

    Source stores lighting as RGBE -- three bytes and a shared signed exponent -- so a
    luxel can be far brighter than white, which is the point: it is light, not a
    colour. It is tone-mapped down here rather than in the shader so the atlas is an
    ordinary sRGB PNG that Godot imports with no special handling.

    [b]Exposed and gamma-encoded, and NOT tone-mapped. A tone map here is the bug.[/b]
    Two encodings stood here before this one and both were wrong in the same place.
    `v = min(1, c * 2**e / 255)` divided by the range of the MANTISSA byte rather than
    by anything the number means, and put the median luxel at 0.03. Reinhard,
    `v / (v + key)` against the map's own median, replaced it and fixed the darkness --
    but Reinhard is a DISPLAY operator and this is not a display, it is a light term
    that still has to be multiplied by an albedo. It compresses ratios everywhere,
    including the midtones where every readable thing in a map lives.

    That was measured against a reference frame of one of these maps as its own engine
    draws it. The reference spans a linear luminance ratio of 303:1 from its darkest
    fifth-percentile pixel to its brightest ninety-fifth; the same view of our import
    spanned 7.9:1. A cave lit by one warm lamp came out as an evenly grey room. Nothing
    about the geometry, the textures or the albedo was wrong -- the light had simply had
    its contrast removed before it ever reached the shader.

    So: expose, clip, encode. Linear light is divided by the map's own
    [code]EXPOSURE_QUANTILE[/code] luxel so that the bright end lands at white, anything
    above that clips -- which the source engine also does, since its overbright range is
    finite too -- and the result is written through gamma 2.2. **Every ratio below the
    clip survives exactly**, which is the entire point: gamma encoding is already the
    compression an 8-bit image needs, and a 500:1 linear range is what sRGB was designed
    to carry. The atlas is still an ordinary sRGB PNG that Godot imports with no special
    handling, and `source_color` on the sampler undoes the gamma on the way back to
    linear, so the shader multiplies an honest light value by an honest albedo.

    Each map still exposes itself against its own light, which is what "a map is
    content" has to mean when the content is somebody else's compile.
    """
    light = bsp._lump(LUMP_LIGHTING)
    lit = [f for f in faces if f[9] >= 0 and (f[9] + 4) <= len(light)]
    lit.sort(key=lambda f: -(f[14] + 1))
    # `blocks` are square tiles of linear light that are not faces -- a static prop's
    # light probe, see bsp_props.light_block. Packed after the faces on the same shelves
    # and exposed by the same white point, so a prop and the floor it stands on are lit
    # on one scale. Their placements come back keyed by position in `blocks`.
    tile = bsp_props.LIGHT_TILE

    # A 2x2 white patch first, so unlit faces have somewhere to point. Without it they
    # sample whatever face happens to sit at the atlas origin and wear its lighting.
    x, y, shelf = 4, 0, 4
    place = {}
    for f in lit:
        w, h = f[13] + 1, f[14] + 1
        if x + w + LM_PAD * 2 > ATLAS_W:
            x, y, shelf = 0, y + shelf, 0
        place[id(f)] = (x + LM_PAD, y + LM_PAD)
        x += w + LM_PAD * 2
        shelf = max(shelf, h + LM_PAD * 2)
    block_place = []
    for _b in blocks:
        if x + tile + LM_PAD * 2 > ATLAS_W:
            x, y, shelf = 0, y + shelf, 0
        block_place.append((x + LM_PAD, y + LM_PAD))
        x += tile + LM_PAD * 2
        shelf = max(shelf, tile + LM_PAD * 2)
    height = max(4, y + shelf)
    height = 1 << (height - 1).bit_length()

    atlas = bytearray(ATLAS_W * height * 4)
    for i in range(3, len(atlas), 4):
        atlas[i] = 255
    for j in range(4):                                   # the white patch
        for i in range(4):
            p = (j * ATLAS_W + i) * 4
            atlas[p] = atlas[p + 1] = atlas[p + 2] = 255

    white = lightmap_quantile(light, lit, 0.5) / EXPOSURE_MEDIAN_TARGET
    inv_gamma = 1.0 / 2.2
    clipped = 0
    total = 0
    for f in lit:
        px, py = place[id(f)]
        w, h = f[13] + 1, f[14] + 1
        o = f[9]
        for j in range(h):
            row = (py + j) * ATLAS_W
            for i in range(w):
                q = o + (j * w + i) * 4
                if q + 3 >= len(light):
                    continue
                e = light[q + 3]
                s = 2.0 ** (e - 256 if e > 127 else e)
                p = (row + px + i) * 4
                for k in range(3):
                    v = light[q + k] * s / white
                    total += 1
                    if v > 1.0:
                        v = 1.0
                        clipped += 1
                    atlas[p + k] = int(255.0 * (v ** inv_gamma))
    for (px, py), block in zip(block_place, blocks):
        for j in range(tile):
            row = (py + j) * ATLAS_W
            for i in range(tile):
                p = (row + px + i) * 4
                for k in range(3):
                    v = min(1.0, block[j][i][k] / white)
                    atlas[p + k] = int(255.0 * (v ** inv_gamma))
    vtf.write_png(path, ATLAS_W, height, bytes(atlas), opaque=True)
    # Reported because it is the one number that says whether a map's exposure is sane:
    # a few per cent is light sources doing what light sources do, and a large fraction
    # is a map whose midtones have been pushed off the top of the range.
    place["blocks"] = block_place
    return place, ATLAS_W, height, (100.0 * clipped / total if total else 0.0)


# ----------------------------------------------------------------- meshing ----
def face_normal(bsp, f):
    """A face's outward normal: its own plane's, and not conditionally flipped.

    [b]This used to negate when `dface_t.side` was set, and that is wrong here.[/b]
    `side` records which side of the NODE's plane the face fell on, which is a fact
    about the tree; the face's own `planenum` already points at the right one of the
    plane pair, because a Source BSP stores every plane twice with opposite normals and
    vbsp writes the twin. Negating on top of that inverted the normal of every face
    with the flag -- 26% of surf_year3000, 40% of surf_beginner2.

    Measured rather than reasoned about, because the documentation for that field reads
    both ways. For 1500 faces of surf_year3000 the centroid was pushed six units each
    way and tested against every solid brush in the map: where one side was solid and
    the other was not -- 908 of them -- the plane normal pointed away from the solid
    908 times with the side flag clear and 178 times with it set, and pointed into the
    solid twice in total.

    [b]Nothing could see it until now.[/b] The normals went into ARRAY_NORMAL and the
    shader that reads them is `unshaded`, so a map lit by its own baked lightmap looks
    identical either way, and backface culling follows the winding rather than the
    normal. It is visible for the first time because the surface roles are read off the
    slope now, and an inverted normal makes a ceiling a platform.
    """
    return bsp.planes[f[0]][:3]


def surface_colour(refl, name=""):
    """The colour a surface is painted when its texture is not in the .bsp, or None.

    [b]Most of a map's textures live in the game's own archives and cannot ship, but
    their average colour is inside the map.[/b] vrad stores each texture's mean albedo as
    `reflectivity`, linear, for its own bounce lighting -- so a stock wooden floor is
    known to be (0.09, 0.05, 0.03) even though its pixels are not. Painting the prototype
    grid in that colour makes an imported map read as its own palette, a green neon strip
    green and a lava pit red, where the role colour made every surface of every map the
    same four greys.

    sRGB out, because that is what a `source_color` uniform takes. Black stays black: a
    texture vrad measured as black (TOOLSBLACK, an unlit `$selfillum` light panel) is the
    one case where the average is not the look.

    [b]A measured black is only trusted when the texture says it is black.[/b] vrad
    measures albedo, and a `$selfillum` light panel -- `lights/white001`, the ramps of a
    whole neon map -- has none: it is black to the bounce and white to the eye. Painted
    black, surf_kitsune's ramps vanished into the sky. So a zero average returns None and
    the surface keeps its role colour, unless the name says black (`toolsblack`,
    `black_*`), which is the one texture whose average really is its look.
    """
    if refl is None or len(refl) < 3:
        return None
    if max(float(c) for c in refl[:3]) < 0.004 and "black" not in name.lower():
        return None
    def srgb(c):
        c = max(0.0, min(1.0, float(c)))
        return 12.92 * c if c <= 0.0031308 else 1.055 * (c ** (1.0 / 2.4)) - 0.055
    return [round(srgb(c), 4) for c in refl[:3]]


def build_mesh(bsp, lm_place, lm_w, lm_h, textured, cos_limit, prototype, drawn=None,
               blends=(), material_of=None):
    """One vertex block and one index block per (material, role).

    [b]Per role and not per material, because a role is per face.[/b] The role comes
    from the slope now (see `role_for_normal`), and one material is used at every angle
    a map has -- `concretefloor039a` is the ride surface AND the walls of the corridor
    around it. Keyed by material alone, the whole map takes whichever role its first
    face happened to have, which is how surf_beginner2 came out 97% FLOOR.

    `textured` says which materials the pakfile actually carried. A material it did not
    -- stock, which is most of what a surf map is built from -- gets the prototype
    set instead of the flat role colour it used to get, and needs a different UV to do
    it: the map's own UVs place a texture the way the mapper placed it, and a prototype
    grid has to be placed in the world instead, at one size everywhere. So the two UVs
    cannot both be written and the choice is made here, per surface.

    `blends` names the materials that blend two textures by vertex alpha
    (`WorldVertexTransition`, 67% of surf_mesa's triangles). A surface of one gets an
    `alpha_offset`: one float per vertex in its own block after the indices, so the
    vertex layout every other surface -- and every loader written before this -- reads
    is unchanged. A brush face of a blend material takes alpha 0, its first texture,
    which is what the engine draws there.

    `material_of` draws a face its own flags would skip, as another material: {id(face):
    (material, texdata index)}, from `sky_walls`. The texdata is the stand-in's, so its
    size is what the face's texture vectors are divided by.
    """
    material_of = material_of or {}
    groups = collections.defaultdict(lambda: ([], []))     # (mat, role) -> (verts, indices)
    dedupe = collections.defaultdict(dict)
    # The average colour of each material's texture, which vrad measured when the map was
    # compiled and left in `dtexdata_t.reflectivity` -- the one fact about a stock texture
    # that IS inside the .bsp. See `surface_colour`.
    reflectivity = {}

    def emit(key, pos_src, nrm_src, uv, uv2, alpha=0.0):
        verts, _ = groups[key]
        k = (round(pos_src[0], 2), round(pos_src[1], 2), round(pos_src[2], 2),
             round(nrm_src[0], 3), round(nrm_src[1], 3), round(nrm_src[2], 3),
             round(uv[0], 4), round(uv[1], 4), round(uv2[0], 5), round(uv2[1], 5),
             round(alpha, 3))
        d = dedupe[key]
        if k in d:
            return d[k]
        g, gn = to_godot(pos_src), to_godot(nrm_src)
        verts.append((g, gn, uv, uv2, alpha))
        d[k] = len(verts) - 1
        return len(verts) - 1

    white = (2.0 / lm_w, 2.0 / lm_h)

    if drawn is None:
        drawn = [(f, (0.0, 0.0, 0.0)) for f in bsp.model_faces(0)]
    for f, off in drawn:
        mat_raw, flags = bsp.face_material(f)
        stand_in = material_of.get(id(f))
        if flags & SKIP_MASK and stand_in is None:
            continue
        mat = clean_material(mat_raw) if stand_in is None else stand_in[0]

        def at(p, off=off):
            # Where the vertex IS; `p` stays where vbsp stored it, for the UVs.
            if len(off) == 4:
                # A 3D skybox face: drawn `scale` times larger about the sky camera,
                # which is where the engine draws it from. See `skybox_of`.
                o, k = off[:3], off[3]
                return ((p[0] - o[0]) * k, (p[1] - o[1]) * k, (p[2] - o[2]) * k)
            return (p[0] + off[0], p[1] + off[1], p[2] + off[2])
        n = face_normal(bsp, f)
        role = role_for_normal(n[2], cos_limit)
        # `all` repaints the map's own textures too; `auto` keeps them and only fills
        # in the ones that lived in the game's VPKs and were never in this file.
        use_prototype = prototype == "all" or (prototype == "auto" and mat not in textured)
        key = (mat, role, use_prototype, len(off) == 4)
        blended = mat in blends and not use_prototype

        ti = bsp.texinfo[f[5]]
        tw, th = 1, 1
        td = int(ti[17]) if stand_in is None else stand_in[1]
        if 0 <= td < len(bsp.texdata):
            tw, th = max(1, bsp.texdata[td][4]), max(1, bsp.texdata[td][5])
            reflectivity.setdefault(mat, tuple(bsp.texdata[td][0:3]))
        tan, bit = tangent_frame(n)

        def uv_of(p):
            if use_prototype:
                return ((p[0] * tan[0] + p[1] * tan[1] + p[2] * tan[2]) / UNITS_PER_SQUARE,
                        (p[0] * bit[0] + p[1] * bit[1] + p[2] * bit[2]) / UNITS_PER_SQUARE)
            u = (p[0] * ti[0] + p[1] * ti[1] + p[2] * ti[2] + ti[3]) / tw
            v = (p[0] * ti[4] + p[1] * ti[5] + p[2] * ti[6] + ti[7]) / th
            return (u, v)

        pl = lm_place.get(id(f))

        def uv2_of(p):
            if pl is None:
                return white
            lu = p[0] * ti[8] + p[1] * ti[9] + p[2] * ti[10] + ti[11] - f[11]
            lv = p[0] * ti[12] + p[1] * ti[13] + p[2] * ti[14] + ti[15] - f[12]
            lu = min(max(lu, 0.0), float(f[13]))
            lv = min(max(lv, 0.0), float(f[14]))
            return ((pl[0] + lu + 0.5) / lm_w, (pl[1] + lv + 0.5) / lm_h)

        _, idx = groups[key]
        if f[6] >= 0:
            # Each point comes back as (displaced, flat). The flat one is only used for
            # the lightmap coordinate -- see `displacement_tris` for why a displacement's
            # lighting is parameterised over the quad rather than over the terrain.
            tris = bsp.displacement_tris(f, with_base=True, with_alpha=True)
            # Displacements are terrain: average the normals over the grid so a
            # rock face is not a field of flat triangles. Brush faces below keep
            # their exact plane normal, because a surf ramp's edge IS sharp.
            acc = collections.defaultdict(lambda: [0.0, 0.0, 0.0])
            for t in tris:
                u = [t[1][0][i] - t[0][0][i] for i in range(3)]
                v = [t[2][0][i] - t[0][0][i] for i in range(3)]
                nn = [u[1] * v[2] - u[2] * v[1], u[2] * v[0] - u[0] * v[2],
                      u[0] * v[1] - u[1] * v[0]]
                for p, _flat, _alpha in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    for i in range(3):
                        acc[k][i] += nn[i]
            for t in tris:
                for p, flat, alpha in t:
                    k = (round(p[0], 2), round(p[1], 2), round(p[2], 2))
                    nn = acc[k]
                    ln = math.sqrt(sum(c * c for c in nn)) or 1.0
                    idx.append(emit(key, at(p), [c / ln for c in nn], uv_of(p), uv2_of(flat),
                                    alpha if blended else 0.0))
        else:
            pts = bsp.face_points(f)
            if len(pts) < 3:
                continue
            ring = [emit(key, at(p), n, uv_of(p), uv2_of(p)) for p in pts]
            for k in range(1, len(ring) - 1):
                # [b]In the order vbsp stored them, which is already Godot's front face.[/b]
                # Both engines draw a clockwise-from-the-viewer triangle, and `to_godot`
                # is a rotation (determinant +1), so nothing between them flips a
                # winding. This line used to reverse the ring "because Source winds the
                # other way", and every brush face of every imported map was drawn
                # inside out for as long as that stood: culled from the side a player is
                # on, and drawn from behind. Most surfaces hid it -- what a player saw of
                # a floor was the slab's own underside, and of a wall its far face -- and
                # a surf ramp could not, because its underside is nodraw: from on top of
                # it there was nothing behind the face, and the ramp a player was riding
                # was clear (surf_mesa's first ramp, in Christian's 2026-10-07 footage).
                # `headless_imported`'s "a brush face is drawn from the side its normal
                # points to" fails if this is ever reversed again.
                idx.extend((ring[0], ring[k], ring[k + 1]))

    surfaces, blob = [], bytearray()
    for key in sorted(groups):
        mat, role, use_prototype, sky = key
        verts, idx = groups[key]
        if not idx:
            continue
        voff = len(blob)
        for g, gn, uv, uv2, _alpha in verts:
            blob += struct.pack("<10f", g[0], g[1], g[2], gn[0], gn[1], gn[2],
                                uv[0], uv[1], uv2[0], uv2[1])
        ioff = len(blob)
        for i in idx:
            blob += struct.pack("<I", i)
        entry = {"material": mat, "role": role, "prototype": use_prototype,
                 **({"skybox": True} if sky else {}),
                 "vertex_offset": voff, "vertex_count": len(verts),
                 "index_offset": ioff, "index_count": len(idx)}
        if mat in blends and not use_prototype and any(v[4] > 0.0 for v in verts):
            # All-zero is the first texture alone -- a brush face, or a displacement the
            # mapper never painted -- and a second texture nothing shows is a cost only.
            entry["alpha_offset"] = len(blob)
            blob += struct.pack("<%df" % len(verts), *(v[4] for v in verts))
        colour = surface_colour(reflectivity.get(mat), mat)
        if colour is not None:
            entry["colour"] = colour
        surfaces.append(entry)
    return surfaces, bytes(blob)


def stock_standin(pr):
    """(prop, [box mesh]) for a solid stock-model prop that has a written stand-in, else None.

    The box is the model's own hull and its collision is that same box (`solid` 2, the
    model's bounding box, which `prop_hulls` already builds from the drawn mesh): a stand-in
    you can see is a stand-in you can stand on, and the other way round. See
    tools/stock_standins.py for which models, why the rest are `none`, and what it reads.
    """
    if pr["solid"] not in (2, 6) or pr.get("skybox") or pr["flags"] & 0x4:
        return None
    mat = stock_standins.material_for(pr["model"])
    box = stock_standins.hull(pr["model"]) if mat else None
    if box is None:
        return None
    return dict(pr, solid=2, standin=stock_standins.source(pr["model"])), [stock_standins.box_mesh(box[0], box[1], mat)]


def load_props(bsp, pak, notes, extra=()):
    """The static props this map can draw: [(prop, meshes)], plus what was skipped.

    Only models the pakfile carried; a stock model is counted, not drawn. A prop the
    map marked no-draw (flag 0x4) is left out the way the engine leaves it out.
    `extra` is more records of the same shape (see `sky_dynamic_props`).
    """
    props = bsp_props.static_props(bsp) + list(extra)
    cache, drawn, stock = {}, [], collections.Counter()
    standins = collections.Counter()
    for pr in props:
        if not pr["model"]:
            continue
        path = pr["model"]
        if path not in cache:
            try:
                cache[path] = bsp_props.read_model(pak, path)
            except (struct.error, ValueError, IndexError) as e:
                notes.append("static prop model %s could not be read (%s)" % (path, e))
                cache[path] = None
        if cache[path] is None:
            stock[path] += 1
            box = stock_standin(pr)
            if box is not None:
                drawn.append(box)
                standins[path] += 1
            continue
        drawn.append((pr, cache[path]))
    return props, drawn, stock, standins


# How far under a stand-in's base a floor may be, and how far into it, and still carry it.
STANDIN_SUPPORT_BELOW = 24.0
STANDIN_SUPPORT_ABOVE = 12.0


def drop_unsupported_standins(bsp, props_drawn, notes):
    """The drawn props, less every stock stand-in box with nothing under it.

    [b]A box the original did not obviously stand on is a wall the original did not
    have.[/b] A stand-in is the hull of a model whose floor we never see: on surf_lore a
    row of warehouse shelves hung in a room whose floor is a field of broken tiles a
    level below, and a box there drew as a slab in the middle of the route. So a box is
    kept only where some floor -- a world brush, a displacement triangle, or an already
    kept box -- spans the height of its base under its footprint. The test is on boxes
    (brush bounds), which over-accepts a ramp's low end and never rejects a real floor.
    """
    _blob, _info, _skipped, solids = build_collision(bsp, [], [])
    floors = list(solids)
    for f in bsp.faces:
        if f[6] < 0 or bsp.face_material(f)[1] & SKIP_MASK:
            continue
        for t in bsp.displacement_tris(f):
            floors.append(([min(p[a] for p in t) for a in range(3)],
                           [max(p[a] for p in t) for a in range(3)]))

    def world_box(pr, meshes):
        m = bsp_props.angle_matrix(pr["angles"])
        pts = [bsp_props.transform(m, q) for mesh in meshes for q in mesh["positions"]]
        o, sc = pr["origin"], pr["scale"]
        pts = [(w[0] * sc + o[0], w[1] * sc + o[1], w[2] * sc + o[2]) for w in pts]
        return ([min(q[a] for q in pts) for a in range(3)], [max(q[a] for q in pts) for a in range(3)])

    def carried(box):
        lo, hi = box
        base = lo[2]
        cx, cy = (lo[0] + hi[0]) * 0.5, (lo[1] + hi[1]) * 0.5
        ins = lambda a, b: a + (b - a) * 0.2
        probes = [(cx, cy)] + [(ins(lo[0], cx) if i & 1 == 0 else ins(hi[0], cx),
                                ins(lo[1], cy) if i & 2 == 0 else ins(hi[1], cy)) for i in range(4)]
        for flo, fhi in floors:
            if fhi[2] < base - STANDIN_SUPPORT_BELOW or flo[2] > base + STANDIN_SUPPORT_ABOVE:
                continue
            for x, y in probes:
                if flo[0] <= x <= fhi[0] and flo[1] <= y <= fhi[1]:
                    return True
        return False

    standins = [(i, world_box(pr, ms)) for i, (pr, ms) in enumerate(props_drawn) if pr.get("standin") and not pr.get("skybox")]
    standins.sort(key=lambda e: e[1][0][2])
    dropped = set()
    for i, box in standins:
        if carried(box):
            floors.append(box)
        else:
            dropped.add(i)
    if dropped:
        notes.append("%d stand-in boxes dropped for having no floor under them" % len(dropped))
    return [e for i, e in enumerate(props_drawn) if i not in dropped]


def prop_materials(pak, drawn):
    """{(model path, mesh index, skin): material name} -- the first candidate the pak has.

    A studio model names a texture and a list of directories to look for it in, and the
    engine takes the first directory that has it; so does this. A mesh none of whose
    candidates shipped keeps the first name, and is drawn in the prototype set.
    """
    out = {}
    for pr, meshes in drawn:
        for mi, mesh in enumerate(meshes):
            fams = mesh["materials"]
            cands = fams[pr["skin"]] if 0 <= pr["skin"] < len(fams) else fams[0]
            pick = next((c for c in cands if ("materials/%s.vmt" % c) in pak), cands[0] if cands else "")
            out[(pr["model"], mi, pr["skin"])] = clean_material(pick)
    return out


def build_props(drawn, materials, block_of, lm_place, lm_w, lm_h):
    """The props' triangles, one surface per material, in the manifest's vertex format.

    World position is Source's own: AngleMatrix(angles) times the model-space vertex, plus
    the origin, then the one axis swap. Winding is reversed for the reason build_mesh
    reverses a brush face's. The second UV is the vertex's normal, octahedrally encoded,
    inside that prop's light tile -- see bsp_props.light_block.
    """
    groups = collections.defaultdict(lambda: ([], []))
    tile = bsp_props.LIGHT_TILE
    blocks = lm_place.get("blocks", [])
    for n, (pr, meshes) in enumerate(drawn):
        m = bsp_props.angle_matrix(pr["angles"])
        o, sc = pr["origin"], pr["scale"]
        b = block_of[n]
        bx, by = blocks[b] if b is not None and b < len(blocks) else (None, None)
        for mi, mesh in enumerate(meshes):
            mat = materials[(pr["model"], mi, pr["skin"])]
            verts, idx = groups[mat]
            base = len(verts)
            for pos, nrm, uv in zip(mesh["positions"], mesh["normals"], mesh["uvs"]):
                w = bsp_props.transform(m, pos)
                w = (w[0] * sc + o[0], w[1] * sc + o[1], w[2] * sc + o[2])
                wn = bsp_props.transform(m, nrm)
                if bx is None:
                    uv2 = (2.0 / lm_w, 2.0 / lm_h)
                else:
                    ou, ov = bsp_props.octahedral_encode(wn)
                    # Kept half a texel inside the tile, so filtering never reads the
                    # neighbour's light.
                    ou = 0.5 + ou * (tile - 1)
                    ov = 0.5 + ov * (tile - 1)
                    uv2 = ((bx + ou) / lm_w, (by + ov) / lm_h)
                verts.append((to_godot(w), to_godot(wn), uv, uv2))
            for a, bb, c in mesh["triangles"]:
                idx.extend((base + a, base + c, base + bb))
    return groups


PROP_COLOUR_WORDS = ("rock", "cliff", "stone", "brick", "concrete", "cobble", "wood", "metal",
                     "dirt", "grass", "sand", "tile", "plaster", "marble", "glass", "leaf",
                     "foliage", "bark", "snow", "ice", "water", "lava", "crystal")


def prop_colours(bsp, materials):
    """{prop material: sRGB colour} for prop materials whose texture did not ship.

    [b]A prop's material is usually named after a texture the map's brushes use too.[/b]
    `propper/surf_summit/cobble02` is `cs_italy/cobble02` on summit's walls, surf_arcade's
    `models/comp/<model>/black` and `/white` are `cs_italy/black` and `/white`, and vrad
    measured every brush texture's average colour into `dtexdata_t.reflectivity` (see
    `surface_colour`). So a prop whose material's last path part names a brush texture
    takes that texture's colour; failing that, one whose name holds a material word
    (`rockcliff02c`: rock) takes the mean colour of the brush textures named with the same
    word -- the map's own rock. Otherwise it stays None and the surface keeps the flat
    0.5 grey, which is what every one of them drew before (`g2g-maps-1`).
    """
    names = []
    for td in bsp.texdata:
        n = clean_material(bsp.texnames[td[3]]).lower()
        if n.startswith(("tools/", "maps/")) or "skybox" in n:
            continue
        names.append((n, tuple(td[0:3])))
    by_base = {}
    for n, refl in names:
        by_base.setdefault(n.rsplit("/", 1)[-1], refl)
    out = {}
    for mat in materials:
        base = mat.lower().rsplit("/", 1)[-1]
        refl = by_base.get(base)
        how = "name"
        if refl is None:
            words = [w for w in PROP_COLOUR_WORDS if w in base]
            hits = [r for n, r in names if any(w in n.rsplit("/", 1)[-1] for w in words)]
            if hits:
                refl = tuple(sum(r[c] for r in hits) / len(hits) for c in range(3))
                how = "word"
        colour = surface_colour(refl, mat)
        if colour is not None:
            out[mat] = (colour, how)
    # A stand-in box has no name to look up, and 0.5 grey drew a crate darker than the
    # sand it stands on (surf_dust2). It takes the mean of what this map's brushes are made of.
    refls = [r for _n, r in names if max(r) > 0.004]
    if refls:
        mean = surface_colour(tuple(sum(r[c] for r in refls) / len(refls) for c in range(3)))
        for mat in materials:
            if "standin_" in mat and mat not in out and mean is not None:
                out[mat] = (mean, "map")
    return out


def emit_prop_surfaces(groups, textured, offset, colours=None):
    """Manifest entries and the blob for build_props' groups, offsets shifted by `offset`.

    `colours` is `prop_colours`' answer: a prototype prop is painted that instead of grey."""
    surfaces, blob = [], bytearray()
    for mat in sorted(groups):
        verts, idx = groups[mat]
        if not idx:
            continue
        voff = len(blob)
        for g, gn, uv, uv2 in verts:
            blob += struct.pack("<10f", g[0], g[1], g[2], gn[0], gn[1], gn[2],
                                uv[0], uv[1], uv2[0], uv2[1])
        ioff = len(blob)
        blob += struct.pack("<%dI" % len(idx), *idx)
        entry = {"material": mat, "role": "FLOOR", "prototype": mat not in textured,
                 "prop": True,
                 "vertex_offset": offset + voff, "vertex_count": len(verts),
                 "index_offset": offset + ioff, "index_count": len(idx)}
        if entry["prototype"]:
            entry["colour"] = list((colours or {}).get(mat, ([0.5, 0.5, 0.5], None))[0])
        surfaces.append(entry)
    return surfaces, bytes(blob)


# ---------------------------------------------------------------- collision ---
def solid_piece(points, least=0.5):
    """True when a convex piece has volume: four points not within `least` of a plane.

    [b]Godot's convex hull builder crashes the process on a flat one[/b] -- an assertion
    (`dot <= 0`) and then signal 11, from inside `build_from`, on bhop_interloper. A
    brush cannot be flat by construction; a .phy ledge can, so this is asked of props.
    """
    pts = list(dict.fromkeys((round(p[0], 2), round(p[1], 2), round(p[2], 2)) for p in points))
    if len(pts) < 4:
        return False
    a = pts[0]
    b = max(pts, key=lambda q: sum((q[i] - a[i]) ** 2 for i in range(3)))
    ab = [b[i] - a[i] for i in range(3)]
    best, c = 0.0, None
    for q in pts:
        aq = [q[i] - a[i] for i in range(3)]
        cr = [ab[1] * aq[2] - ab[2] * aq[1], ab[2] * aq[0] - ab[0] * aq[2],
              ab[0] * aq[1] - ab[1] * aq[0]]
        d = sum(x * x for x in cr)
        if d > best:
            best, c, n = d, q, cr
    if c is None or best < 1e-6:
        return False
    ln = math.sqrt(sum(x * x for x in n))
    return max(abs(sum(n[i] * (q[i] - a[i]) for i in range(3))) / ln for q in pts) >= least


def prop_hulls(pak, drawn):
    """The solid static props' collision, as convex hulls in world (Hammer) coordinates.

    `solid` 6 is SOLID_VPHYSICS, the default for a static prop: its .phy is the shape.
    2 is SOLID_BBOX, the model's own box. 0 is not solid. A prop whose model the pak did
    not carry has no collision here either -- it is not drawn, and an invisible wall is
    the one outcome worse than a missing one.
    """
    cache, out = {}, []
    for pr, meshes in drawn:
        if pr["solid"] not in (2, 6) or pr.get("skybox"):
            continue
        path = pr["model"]
        if pr["solid"] == 6:
            if path not in cache:
                try:
                    cache[path] = bsp_props.read_phy(pak, path) or []
                except (struct.error, ValueError, IndexError):
                    cache[path] = []
            pieces = cache[path]
            # A ledge whose points run far outside the model's own drawn extent is a
            # misread, not a shape: two models of 346 on surf_summit parse to points
            # of 1e38. It is dropped rather than trusted, and so is the model's whole
            # collision if nothing sane is left.
            pts = [p for m in meshes for p in m["positions"]]
            if pts:
                lim = max(abs(c) for p in pts for c in p) * 1.5 + 32.0
                pieces = [pc for pc in pieces
                          if all(abs(c) <= lim for q in pc for c in q)]
        else:
            pts = [p for m in meshes for p in m["positions"]]
            lo = [min(p[a] for p in pts) for a in range(3)]
            hi = [max(p[a] for p in pts) for a in range(3)]
            pieces = [[(x, y, z) for x in (lo[0], hi[0]) for y in (lo[1], hi[1])
                       for z in (lo[2], hi[2])]]
        m = bsp_props.angle_matrix(pr["angles"])
        o, sc = pr["origin"], pr["scale"]
        for piece in pieces:
            if not solid_piece(piece):
                continue
            world = []
            for p in piece:
                w = bsp_props.transform(m, p)
                world.append((w[0] * sc + o[0], w[1] * sc + o[1], w[2] * sc + o[2]))
            out.append(world)
    return out


MERGE_EPSILON = 0.05


def merge_convex_brushes(bsp, brushes):
    """The world's brushes as convex solids, with every seam that need not exist removed.

    [b]A seam between two brushes is an edge a sliding hull can catch, even when the two
    faces either side of it are one plane.[/b] Every brush is its own convex shape in
    the collider, and a hull crossing from one to the next meets the leading edge of
    the second: on Surf_Mesa's first ramp, which the mapper built as segments 500 units
    long, the real motor gets kicked off the face at 36 u/s at the seam and rises 1.5
    units before gravity brings it back -- a bump on a flat ramp, every half second, and
    "the ramps are a bit bumpy" (Christian's 2026-10-07 footage). Source's own trace
    walks one BSP tree and never sees the seam at all.

    So two brushes that touch on a plane -- one's side is the other's, facing the other
    way -- are merged when their union is convex, which is exactly when each one's
    corners are behind every OTHER side of the other. That is the merge test the
    classic brush compilers use, and it is exact: the merged solid is the same volume,
    so nothing a player can stand on or hit moves; only the edge between them goes.
    Repeated until nothing merges, so a ramp of twenty segments becomes one wedge.

    Bevel sides are left out of the test (vbsp adds them for its own tracing, and they
    can exclude a neighbour that the brush's real sides do not), and only brushes of
    the same contents merge, so a playerclip never swallows the solid beside it.
    Returns [(points, offset, contents)] in the shape `build_collision` keeps.
    """
    def key(n, d):
        return (round(n[0], 3), round(n[1], 3), round(n[2], 3), round(d, 1))

    items = []
    for i in brushes:
        first, count, contents = bsp.brushes[i]
        planes = []
        for side in bsp.brushsides[first:first + count]:
            if side[3]:
                continue
            pl = bsp.planes[side[0]]
            planes.append(((pl[0], pl[1], pl[2]), pl[3]))
        items.append({"pts": [tuple(p) for p in bsp.brush_hull(i)], "planes": planes,
                      "contents": contents, "alive": True})

    def behind(pts, planes, skip):
        for n, d in planes:
            if key(n, d) == skip:
                continue
            for p in pts:
                if n[0] * p[0] + n[1] * p[1] + n[2] * p[2] - d > MERGE_EPSILON:
                    return False
        return True

    by_plane = collections.defaultdict(list)
    for k, it in enumerate(items):
        it["keys"] = {key(n, d) for n, d in it["planes"]}
        for q in it["keys"]:
            by_plane[q].append(k)
    # A worklist rather than a restart after every merge: a brush that grew is asked
    # again, with the sides it gained, until nothing beside it will join it.
    pending = collections.deque(range(len(items)))
    while pending:
        a = pending.popleft()
        it = items[a]
        grew = it["alive"]
        while grew:
            grew = False
            for n, d in list(it["planes"]):
                mine = key(n, d)
                theirs = key((-n[0], -n[1], -n[2]), -d)
                for b in by_plane.get(theirs, ()):
                    other = items[b]
                    if b == a or not other["alive"] or other["contents"] != it["contents"] \
                            or theirs not in other["keys"]:
                        continue
                    if not (behind(other["pts"], it["planes"], mine)
                            and behind(it["pts"], other["planes"], theirs)):
                        continue
                    it["planes"] = [q for q in it["planes"] if key(*q) != mine] + \
                        [q for q in other["planes"] if key(*q) != theirs]
                    it["keys"] = {key(*q) for q in it["planes"]}
                    for q in it["keys"]:
                        by_plane[q].append(a)
                    # Keep the corners; the faces they shared are inside now and a convex
                    # shape built from these points is the merged hull regardless.
                    it["pts"] = list({(round(p[0], 3), round(p[1], 3), round(p[2], 3))
                                      for p in it["pts"] + other["pts"]})
                    other["alive"] = False
                    grew = True
                    break
                if grew:
                    break
    return [(it["pts"], (0.0, 0.0, 0.0), it["contents"]) for it in items if it["alive"]]


def build_collision(bsp, notes, props=()):
    """Every solid in the map as convex hulls, plus the displacements as triangles.

    [b]This is the half the importer did not have, and the one a player notices.[/b]
    Collision used to be `create_trimesh_collision()` over the drawn mesh, and the
    drawn mesh is not the solid: see MASK_PLAYERSOLID in bsp_read. A `nodraw` face is
    absent from it, a `toolsplayerclip` brush is absent from it entirely, and on
    Surf_Mesa 77% of the sides of a solid brush are one or the other -- so the
    collision shell had holes in it the size of the brushes it was meant to be, and a
    player fell through the map.

    [b]Convex per brush, and not one big trimesh, because this is a surf game.[/b] A
    concave shape collides as loose triangles, and a hull sliding across one meets
    every interior edge between them -- the classic catch on a seam in a flat floor,
    which on a 45-degree ramp at 3000 u/s is a run ended by a bump that is not there.
    A brush is convex by construction and Godot's solver treats a convex shape as one
    surface with no interior edges at all, which is exactly the guarantee Source's own
    player movement is built on. It is also what makes the count affordable: 2500
    boxes and wedges is cheap to broadphase, and it is the shape the mapper drew.

    Displacements are the exception and get triangles, because a displacement is
    terrain and is not convex in any useful way. There are 1850 of them in surf_summit
    and 1434 in Surf_Mesa, several of which are ramps players ride.
    """
    hulls = []

    def add_model(model, offset, why):
        for i in sorted(bsp.model_brushes(model)):
            contents = bsp.brushes[i][2]
            if not contents & MASK_PLAYERSOLID:
                continue
            pts = bsp.brush_hull(i)
            if len(pts) < 4:
                # A brush whose sides do not enclose anything. Not fatal and not
                # silent: it is either a reader bug or a brush the compiler broke,
                # and both are things a person wants to be told.
                notes.append("%s brush %d has no hull (%d corners)" % (why, i, len(pts)))
                continue
            hulls.append((pts, offset, contents))

    add_model(0, (0.0, 0.0, 0.0), "world")
    world_brushes = sorted(i for i in bsp.model_brushes(0)
                           if bsp.brushes[i][2] & MASK_PLAYERSOLID and len(bsp.brush_hull(i)) >= 4)
    merged_from = len(hulls)
    hulls = merge_convex_brushes(bsp, world_brushes)
    if len(hulls) < merged_from:
        notes.append("%d world brushes merged into %d convex solids along shared faces"
                     % (merged_from, len(hulls)))

    skipped = collections.Counter()
    for e in bsp.entities:
        model = e.get("model", "")
        if not model.startswith("*"):
            continue
        index = int(model[1:])
        if not 0 < index < len(bsp.models):
            continue
        name = e.get("classname", "?")
        if name in SOLID_BRUSH_ENTITIES and bsp_mechanics.solid_for_players(e):
            add_model(index, tuple(entity_origin(e)), name)
        elif name in SOLID_BRUSH_ENTITIES:
            skipped[name + " (not solid by its own keys)"] += 1
        else:
            skipped[name] += 1
            if name not in NONSOLID_BRUSH_ENTITIES and not name.startswith("trigger_"):
                notes.append("%s is a brush entity neither list in bsp_read knows; "
                             "treated as non-solid" % name)

    # Solid static props, after the brushes. They are convex pieces already (a .phy
    # ledge is a hull), so they go in as more of the same. Not in `solids`: the zone
    # rules were measured against the brushes, and what a prop does to a pit is a
    # question for when a map needs it.
    first_prop = len(hulls)
    for pts in props:
        hulls.append((pts, (0.0, 0.0, 0.0), 0))

    # No count in front of the hulls: the manifest already carries `hull_count`, and a
    # second copy of a number is a second thing that can be wrong. The block is a bare
    # run of <point count><points>, the way the surface blocks above are bare arrays.
    blob = bytearray()
    clips = 0
    # Each hull's box, in Hammer coordinates, for the zone rules: a pit is grown AWAY
    # from anything a player stands on (see Zoner.add), and this is the one place that
    # has already solved every brush into its corners.
    solids = []
    for n, (pts, off, contents) in enumerate(hulls):
        if n < first_prop:
            solids.append(([min(p[a] for p in pts) + off[a] for a in range(3)],
                           [max(p[a] for p in pts) + off[a] for a in range(3)]))
        if contents & CONTENTS_PLAYERCLIP:
            clips += 1
        blob += struct.pack("<I", len(pts))
        for p in pts:
            blob += struct.pack("<3f", *to_godot([p[a] + off[a] for a in range(3)]))

    # The displacement surface, welded across the whole map so that two displacements
    # sharing an edge share its vertices -- an unwelded seam is a crack a hull can
    # catch on, which is the one thing the convex half above exists to avoid.
    verts, index_of, tris = [], {}, []
    for f in bsp.faces:
        if f[6] < 0:
            continue
        if bsp.face_material(f)[1] & SKIP_MASK:
            continue
        for t in bsp.displacement_tris(f):
            for point in t:
                key = (round(point[0], 2), round(point[1], 2), round(point[2], 2))
                i = index_of.get(key)
                if i is None:
                    i = index_of[key] = len(verts)
                    verts.append(to_godot(point))
                tris.append(i)

    vertex_offset = len(blob)
    for v in verts:
        blob += struct.pack("<3f", *v)
    index_offset = len(blob)
    for i in tris:
        blob += struct.pack("<I", i)

    info = {
        "hull_count": len(hulls),
        "hull_offset": 0,
        "displacement_vertex_offset": vertex_offset,
        "displacement_vertex_count": len(verts),
        "displacement_index_offset": index_offset,
        "displacement_index_count": len(tris),
        "playerclip_hulls": clips,
        "prop_hulls": len(hulls) - first_prop,
    }
    return bytes(blob), info, skipped, solids


# -------------------------------------------------------------------- zones ---
def inflate(lo, hi, minimum):
    """A box grown about its own centre until no axis is thinner than `minimum`."""
    lo, hi = list(lo), list(hi)
    grown = False
    for i in range(3):
        span = hi[i] - lo[i]
        if span < minimum:
            centre = (lo[i] + hi[i]) * 0.5
            lo[i], hi[i] = centre - minimum * 0.5, centre + minimum * 0.5
            grown = True
    return lo, hi, grown


def stands_between(solids, box, bottom, top):
    """Whether any solid's top face lies in (bottom, top] over the footprint of `box`.

    A top face is somewhere a player stands. Strictly inside the footprint on both
    horizontal axes, because a pit drawn up against the side of a block shares an
    edge with it and that is not the block being over the pit.
    """
    (x0, y0, _), (x1, y1, _) = box
    for (a, b) in solids:
        if a[0] >= x1 or b[0] <= x0 or a[1] >= y1 or b[1] <= y0:
            continue
        if bottom < b[2] <= top:
            return True
    return False


def inflate_pit(lo, hi, minimum, solids):
    """A pit thickened the way `inflate` does, unless that would swallow a floor.

    [b]Centred is right until the pit is closer to the route than half the slab.[/b]
    `MIN_ZONE_THICKNESS` explains why a thin pit is grown at all and why centred was
    the choice: downward is wrong for a boundary trigger above the play space. But a
    bhop map draws its pit a block's height under the blocks -- 48 units on
    bhop_evolve -- and a 192-unit slab centred on that reaches 48 units ABOVE the
    block tops, so a player standing on a block is standing in the pit. 52 of that
    map's 82 pits did it, the start room of bhop_pandora2_fix sat inside one, and
    nothing about it reads as wrong from anywhere but a player's feet: the zone is in
    the right place, the right size, and respawns people who landed perfectly.

    So when the upper half of the centred slab has somewhere to stand in it, the slab
    hangs from the plane the mapper drew instead: its top stays where Source's
    trigger was and all the thickness goes downward, which is the side a falling
    player arrives from. A pit under open air stays centred, which keeps the old
    answer for every map it was already right on.
    """
    top = hi[2]
    lo, hi, grown = inflate(lo, hi, minimum)
    # Only the vertical axis can swallow a floor; a slab grown sideways is a wall.
    if not grown or top >= hi[2]:
        return lo, hi, grown, "centred" if grown else ""
    if not stands_between(solids, (lo, hi), top, hi[2]):
        return lo, hi, grown, "centred"
    lo[2], hi[2] = top - minimum, top
    return lo, hi, grown, "hung"


def entity_origin(e):
    try:
        return [float(x) for x in e.get("origin", "0 0 0").split()][:3]
    except ValueError:
        return [0.0, 0.0, 0.0]


# Brush entities a player SEES. The solid list in bsp_read decides collision and is the
# wrong list for drawing: `func_clip_vphysics` is solid and invisible, `func_illusionary`
# is visible and not solid.
DRAWN_BRUSH_ENTITIES = (SOLID_BRUSH_ENTITIES - {"func_clip_vphysics"}) | {
    "func_illusionary", "func_wall_illusionary",
}


def skybox_of(bsp):
    """The 3D skybox: (sky camera origin, scale, (lo, hi) of its room), or None.

    [b]A map's 3D skybox is a small room somewhere outside the play space, built at a
    sixteenth of the size (the `sky_camera`'s `scale`) and drawn by the engine behind
    everything, that many times larger, as if it surrounded the map.[/b] Ten of the 26
    maps have one. Imported as ordinary faces it was two faults at once: the backdrop
    was missing -- the maps floated in the procedural sky -- and a miniature of it hung
    in the distance where the mapper had compiled it.

    The room is the area the sky camera stands in: every leaf with that area number,
    boxed. A face all of whose corners are inside that box belongs to it.
    """
    cams = [e for e in bsp.entities if e.get("classname") == "sky_camera"]
    if not cams:
        return None
    o = entity_origin(cams[0])
    try:
        k = float(cams[0].get("scale", "16"))
    except ValueError:
        k = 16.0
    leaf = bsp_props._leaf_of(bsp, o)
    if not 0 <= leaf < len(bsp.leafs):
        return None
    area = bsp.leafs[leaf][2] & 0x1FF
    boxes = [(lf[3:6], lf[6:9]) for lf in bsp.leafs
             if (lf[2] & 0x1FF) == area and not lf[0] & 1]
    if not boxes or area == 0:
        return None
    lo = [min(b[0][a] for b in boxes) - 1 for a in range(3)]
    hi = [max(b[1][a] for b in boxes) + 1 for a in range(3)]
    return o, k, (lo, hi)


# Model entities a 3D skybox is drawn with when its mapper did not use static props.
SKY_PROP_CLASSES = ("prop_dynamic", "prop_dynamic_override")


def sky_dynamic_props(bsp, sky):
    """The `prop_dynamic`s standing in the 3D skybox's room, as static-prop records.

    [b]Two maps build their whole sky out of them and drew nothing.[/b] bhop_pandora2_fix
    (six: clouds, asteroids, floating islands) and bhop_supernova (three: two islands
    and an asteroid field) put nothing in the sky room but `tools/toolsskybox` walls and
    these, so `skybox_of` found the room and the importer, reading static props only,
    found no faces in it. Only the sky room's are taken: there they are scenery seen
    from far away, never solid and never moved by anything a player does, which is a
    static prop in all but name. One in the play space may be animated, toggled or
    parented, and this importer runs none of a map's outputs.
    """
    if sky is None:
        return []
    out = []
    for e in bsp.entities:
        if e.get("classname") not in SKY_PROP_CLASSES or not e.get("model", "").endswith(".mdl"):
            continue
        if str(e.get("rendermode", "0")).strip() == "10" or str(e.get("StartDisabled", "0")).strip() == "1":
            continue
        o = tuple(entity_origin(e))
        if not in_box(o, sky[2]):
            continue
        try:
            angles = tuple(float(x) for x in e.get("angles", "0 0 0").split()[:3])
            scale = float(e.get("modelscale", "1") or 1.0) or 1.0
            skin = int(float(e.get("skin", "0") or 0))
        except ValueError:
            angles, scale, skin = (0.0, 0.0, 0.0), 1.0, 0
        out.append({"model": e["model"].lower(), "origin": o, "angles": angles,
                    "solid": 0, "skin": skin, "flags": 0, "lighting_origin": o,
                    "scale": scale, "dynamic": True})
    return out


# How far from the map's centre a 3D skybox may be drawn, in units: inside the player
# camera's far plane (Camera3D's default 4000 m, which G2GCamera keeps) with room to
# spare for a player standing at the edge of a map ~300 m across.
SKY_REACH = 3500.0 / 0.01905


def sky_drawn_scale(bsp, sky, drawn, props_drawn):
    """(scale, nearest, farthest): the scale the 3D skybox is drawn at, and how far from
    the world's origin (where the sky camera lands) its nearest and farthest vertex then
    are, in units. None for a map with no 3D skybox.

    The sky camera's own scale, unless that puts everything in the sky past SKY_REACH;
    then the largest that brings the farthest of it inside -- but never so small that the
    NEAREST of it comes inside the map's own bounds, because the engine draws its sky
    behind everything and here it is drawn into the world, where it could stand in the
    play space. Where the two disagree the sky stays out of the map and its far edge is
    clipped.

    [b]bhop_pandora2_fix's sky camera says 512.[/b] The engine draws the sky in its own
    pass, so there the scale only sets parallax and never clips; drawn here at 512 its
    nearest asteroid was 5 km out and its islands past 20 km, all behind a 4 km far plane:
    imported and invisible. Seen from the middle of the map a sky scaled down is the same
    picture (size and distance shrink together); only parallax changes. bhop_supernova's
    asteroid field reaches from 586 to 6,966 units off its camera, so at its own 64 the
    outer half was past the far plane, and no scale both fits it and keeps the inner
    rocks out of the map. Every 16 in the 26 already fits and is unchanged.
    """
    if sky is None:
        return None
    o, k, box = sky
    # Measured over every vertex: a skybox model is built for the sky's scale, and an
    # asteroid field reaches thousands of units past its origin.
    near, far = math.inf, 0.0
    for f, off in drawn:
        pts = [(p[0] + off[0], p[1] + off[1], p[2] + off[2]) for p in bsp.face_points(f)]
        if pts and all(in_box(p, box) for p in pts):
            for p in pts:
                d = math.dist(o, p)
                near, far = min(near, d), max(far, d)
    for pr, meshes in props_drawn:
        if not in_box(pr["origin"], box):
            continue
        m, sc, po = bsp_props.angle_matrix(pr["angles"]), pr["scale"], pr["origin"]
        for mesh in meshes:
            for pos in mesh["positions"]:
                w = bsp_props.transform(m, pos)
                d = math.dist(o, (w[0] * sc + po[0], w[1] * sc + po[1], w[2] * sc + po[2]))
                near, far = min(near, d), max(far, d)
    if far <= 0.0:
        return k, 0.0, 0.0
    lo, hi = bsp.model_bounds(0)
    radius = max(math.dist((0.0, 0.0, 0.0), (x, y, z))
                 for x in (lo[0], hi[0]) for y in (lo[1], hi[1]) for z in (lo[2], hi[2]))
    scale = k
    if far * k > SKY_REACH:
        scale = min(k, max(float(int(SKY_REACH / far)), float(math.ceil(radius / near))))
    return scale, near * scale, far * scale


def in_box(p, box):
    return all(box[0][a] <= p[a] <= box[1][a] for a in range(3))


def sky_walls(bsp, rule, drawn, room):
    """World sky faces a map's zones file asks to have drawn as walls: ([(face, offset)],
    {id(face): (material, texdata index)}).

    [b]A sky face is a wall in the engine these maps were built for, and it was a window
    here.[/b] `tools/toolsskybox` draws the sky, and nothing behind it: the world on the
    far side is never drawn through one. Skipped, which is right for a map whose sky faces
    are its ceiling and its horizon, it is a hole -- and surf_kitsune builds the end wall of
    every one of its nine sections from them, so from each stage start a player saw the
    whole of the rest of the map hanging in the sky (Christian's 2026-10-08 footage). The
    sky itself cannot be drawn on it (its textures are another game's), so the face takes a
    material the map does carry: `{"nearest": "grids/"}` is, per face, the material of the
    nearest drawn face whose name starts with that, which on a map built in coloured
    sections is the section's own. Opt-in per map, because on most maps a sky face is open
    sky and a wall there would close it. Faces inside the 3D skybox's room are left alone:
    that room is the backdrop, not the play space.
    """
    if not rule:
        return [], {}
    prefix = str(rule.get("nearest", "")).strip().lower()
    if not prefix:
        raise ValueError("sky_walls needs `nearest`, the material prefix to draw them in")

    def centre(f, off):
        pts = bsp.face_points(f)
        return [sum(p[a] for p in pts) / len(pts) + off[a] for a in range(3)]

    candidates = []
    for f, off in drawn:
        name = clean_material(bsp.face_material(f)[0])
        if name.startswith(prefix) and len(off) == 3:
            candidates.append((centre(f, off), name, int(bsp.texinfo[f[5]][17])))
    if not candidates:
        raise ValueError("sky_walls: no drawn face's material starts with %r" % prefix)
    walls, material_of = [], {}
    for f in bsp.model_faces(0):
        flags = bsp.face_material(f)[1]
        if not flags & (SURF_SKY | SURF_SKY2D) or f[6] >= 0:
            continue
        pts = bsp.face_points(f)
        if len(pts) < 3 or (room is not None and all(in_box(p, room) for p in pts)):
            continue
        c = centre(f, (0.0, 0.0, 0.0))
        _, name, td = min(candidates,
                          key=lambda k: sum((k[0][a] - c[a]) ** 2 for a in range(3)))
        walls.append((f, (0.0, 0.0, 0.0)))
        material_of[id(f)] = (name, td)
    return walls, material_of


def drawn_faces(bsp):
    """Every face a player sees, as (face, offset): the world's, then the brush entities'.

    [b]The world alone was 53% of bhop_eazy.[/b] A jump map's blocks are `func_door`s
    (they sink when stood on, which is the genre's anti-camping rule) and its
    decoration is `func_brush` and `func_illusionary`; all of them are separate brush
    models, and this importer drew model 0 only. Collision already came from the
    brushes, so every one of those blocks was there to stand on and invisible -- across
    the 25 maps, between 0% and 47% of what a mapper drew (aztec 30%, monster_jam 22%,
    tesquo 16%). Measured by counting drawable faces per model, before and after.

    The offset is the entity's `origin`, for the reason `brush_box` gives: vbsp stores a
    brush entity's geometry relative to it. UVs stay computed from the stored position,
    because texinfo and the lightmap were computed there too.

    A brush the map hides is left out: `rendermode 10` is "do not render", a brush in an
    alpha render mode at `renderamt 0` is fully transparent (`invisible_by_alpha`), and a
    `func_brush` that starts disabled is not there until something turns it on.
    """
    out = [(f, (0.0, 0.0, 0.0)) for f in bsp.model_faces(0)]
    for e in bsp.entities:
        model = e.get("model", "")
        if not model.startswith("*") or e.get("classname") not in DRAWN_BRUSH_ENTITIES:
            continue
        if str(e.get("rendermode", "0")).strip() == "10":
            continue
        if invisible_by_alpha(e):
            continue
        if e.get("classname") == "func_brush" and str(e.get("StartDisabled", "0")).strip() == "1":
            continue
        index = int(model[1:]) if model[1:].isdigit() else -1
        if not 0 < index < len(bsp.models):
            continue
        o = tuple(entity_origin(e))
        out.extend((f, o) for f in bsp.model_faces(index))
    return out


# Render modes whose alpha is `renderamt`: Color, Texture, Glow, Solid, Additive, and the
# additive fractional-frame and world-space glow variants. Normal (0) ignores renderamt.
ALPHA_RENDER_MODES = {"1", "2", "3", "4", "5", "7", "8", "9"}


def invisible_by_alpha(e):
    """Whether a brush entity starts fully transparent: a render mode that reads its alpha
    from `renderamt`, and `renderamt 0`.

    surf_kitsune hangs nine `func_brush`es named `kitsune` -- rainbowscroll tunnels up to
    29,000 units long -- in `rendermode 4` at `renderamt 0`: there, invisible, for an output
    to fade in. Drawn at full strength they were a wall of rainbow behind every section,
    the brightest thing in a map that is neon lines on black, where both reference runs
    (CS:GO and CS2) show black. Only `rendermode 10` was treated as hidden.
    """
    mode = str(e.get("rendermode", "0")).strip()
    amount = str(e.get("renderamt", "255")).strip()
    try:
        return mode in ALPHA_RENDER_MODES and float(amount) <= 0.0
    except ValueError:
        return False


def entity_yaw(e):
    try:
        return float(e["angles"].split()[1])
    except (KeyError, ValueError, IndexError):
        return 0.0


def brush_box(bsp, e):
    """A brush entity's volume in world (Hammer) coordinates, or None.

    [b]A brush model's bounds are relative to the entity's `origin` key.[/b] vbsp
    moves a brush entity's geometry so that its origin sits at (0,0,0) and records
    where that was; the two are only the same thing for worldspawn, whose origin is
    the world's. A reader that takes the bounds alone gets every trigger in the map
    piled around the map's centre -- which is exactly what this importer did, so every
    pit volume in the two maps it had imported was drawn somewhere the player never
    goes, and caught nobody. Nothing errored: a RESPAWN volume that is never entered
    is indistinguishable from one nobody has fallen into yet.

    Confirmed against the faces rather than reasoned about: for every trigger in
    surf_kitsune the model's own vertices span exactly the model's bounds, and the
    entity's origin is the offset to where the mapper drew it.
    """
    model = e.get("model", "")
    if not model.startswith("*"):
        return None
    index = int(model[1:])
    if index >= len(bsp.models):
        return None
    lo, hi = bsp.model_bounds(index)
    o = entity_origin(e)
    return ([lo[i] + o[i] for i in range(3)], [hi[i] + o[i] for i in range(3)])


def union_box(boxes):
    lo = [min(b[0][i] for b in boxes) for i in range(3)]
    hi = [max(b[1][i] for b in boxes) for i in range(3)]
    return lo, hi


def box_contains(box, point, margin=0.0):
    return all(box[0][i] - margin <= point[i] <= box[1][i] + margin for i in range(3))


def _norm_name(name):
    return re.sub(r"^(tm_|tr_|trigger_)", "", name.strip().lower())


def zone_role(name):
    """(kind, stage number, track key) for a trigger's targetname, or None.

    [b]These maps label their own zones, and the importer used to throw the labels
    away.[/b] The comment that stood here said a surf map of this genre has no convention for
    a start and a finish. That is true of surf_kitsune, which really does drive its
    stages with a filter chain -- and false of five of the eight maps beside it, which
    carry `zone_start`, `map_end_zone`, `startzone_s4` and `tm_bonus2_endzone` in
    plain text, because they were built for a timer. Reading a label the mapper wrote
    is not guessing.

    What is still not guessed: a map with no such names gets no start and no end from
    here. It gets them from `maps/zones/<id>.json`, where somebody wrote down what
    they worked out, next to why.
    """
    n = _norm_name(name)

    m = re.match(r"^(?:startzone|start_zone|zone_start)_s(\d+)$", n)
    if m:
        return ("STAGE", int(m.group(1)), "")

    # surf_lt_unicorn's `stage_startzone_01`..`_06`: the stage first, then the label.
    # Read by the general START rule below it was a START on a track called `stage_01`,
    # six tracks for one route. Stage 1's line is the route's start, as with
    # `checkpoint_N` below; no map imported before 2026-10-10 carries this name.
    m = re.match(r"^stage_?start_?zone_?(\d+)$", n)
    if m:
        number = int(m.group(1))
        return ("START", 0, "") if number <= 1 else ("STAGE", number, "")

    m = re.match(r"^checkpoint[_-]?(\d+)$", n)
    if m:
        # A numbered checkpoint is a split, and a split opens the section after it.
        # Stage 1 is the map's own start line, so checkpoint 1 is the start of stage 2.
        return ("STAGE", int(m.group(1)) + 1, "")

    if "checkpoint" in n:
        # A NAMED checkpoint is not a split. surf_interference's are `center`, `left`
        # and `right`: three routes through one section, of which a player takes
        # exactly one -- so numbering them would put a different set of splits on
        # every run and make the column meaningless.
        return ("CHECKPOINT", 0, "")

    # [b]`start_trigger` is the same evidence as `zone_start`, and only one of them
    # was being read.[/b] The gate here was `"zone" not in n`, so a mapper who called
    # the volume a trigger rather than a zone had the label thrown away -- which is
    # this function's own docstring happening again, one convention further out.
    # `surf_greensway` names all four of its volumes `start_trigger`, `end_trigger`,
    # `checkpoint_1` and `checkpoint_2`, and got a timer out of the two that happened
    # to match. Over the eighteen maps imported here the widened gate changes exactly
    # those two labels and nothing else, which is the only reason it is safe: this
    # runs over `trigger_multiple` and `trigger_once` targetnames, where "start" and
    # "end" are already about as unambiguous as a compiled map gets.
    if "zone" not in n and "trigger" not in n:
        return None
    if "start" in n:
        kind = "START"
    elif "end" in n:
        kind = "END"
    else:
        return None

    # "trigger" comes off with the rest, or `start_trigger` leaves `trigger` behind as
    # a track key and the map's main route becomes bonus 1.
    rest = n.replace("zone", "").replace("trigger", "").replace("start", "").replace("end", "")
    rest = re.sub(r"[_\s]+", "_", rest).strip("_")
    # `mod_zone_start` / `mod_zone_end_bonus` (bhop_overthinker): a timer plugin's
    # prefix, like `map_`, and left on it made the main route a track called `mod`.
    rest = re.sub(r"^(map|the|mod)_?", "", rest).strip("_")
    return (kind, 0, rest)


def assign_tracks(keys):
    """Track key -> track number, using the map's own numbering wherever it has one.

    `bonus2` is bonus 2 because the people who play it call it that. A track the map
    names rather than numbers -- surf_beginner2's `koga`, `sagan`, `spy`, `frag` --
    gets the lowest free number in alphabetical order, which is arbitrary but stable:
    the same map imported twice numbers them the same way, and a records table keyed
    on track 3 keeps meaning the same route.
    """
    out = {"": 0}
    taken = {0}
    named = []
    for key in sorted(k for k in keys if k):
        m = re.search(r"bonus[_ ]?(\d+)", key) or re.match(r"^b(\d+)$", key)
        if m and 1 <= int(m.group(1)) <= 8:
            out[key] = int(m.group(1))
            taken.add(int(m.group(1)))
        else:
            named.append(key)
    n = 1
    for key in named:
        while n in taken:
            n += 1
        if n > 8:
            break
        out[key] = n
        taken.add(n)
    return out


class Zoner:
    """Everything the manifest's `zones` list is worked out from.

    Holds the entity lump, what each rule has claimed out of it, and the zones built
    so far. [b]Claiming matters.[/b] A trigger that is the finish line must not also
    be one of the hundred-odd pit volumes, and the only thing separating the two is
    that something already decided what it was.
    """

    def __init__(self, bsp, min_thickness=MIN_ZONE_THICKNESS, solids=None):
        self.bsp = bsp
        self.min_thickness = min_thickness
        self.solids = solids or []
        self.claimed = set()
        # The conditional teleports `conditional_teleports` dropped: an anti-standing trap
        # is one, and bsp_mechanics turns it into a per-player block.
        self.traps = []
        self.zones = []
        self.notes = []
        self.track_names = {}

    # -- reading the entity lump ------------------------------------------
    def entities(self, *classnames):
        for i, e in enumerate(self.bsp.entities):
            if i in self.claimed:
                continue
            if not classnames or e.get("classname", "") in classnames:
                yield i, e

    def destinations(self, name):
        """Every `info_teleport_destination` with that targetname, case-insensitively.

        Case-insensitively because Source is: surf_kitsune's triggers target `Red`,
        `yellow` and `WHITE` while its destinations are named `red`, `YELLOW` and
        `white`, and the game does not care.
        """
        want = name.strip().lower()
        out = []
        others = []
        brushes = []
        for e in self.bsp.entities:
            if e.get("targetname", "").strip().lower() != want or not want:
                continue
            if e.get("classname", "") == "info_teleport_destination":
                out.append((entity_origin(e), entity_yaw(e)))
            elif "origin" in e and not e.get("model", "").startswith("*"):
                # A teleport may aim at ANY point entity, and mappers use that:
                # surf_greatriver_xdre4m aims twelve at `info_target`s and
                # surf_grave_reloaded all eight at `info_landmark`s. A destination wins
                # where both carry the name.
                others.append((entity_origin(e), entity_yaw(e)))
            elif "origin" in e:
                # Or at a BRUSH entity, which the engine sends to that entity's origin
                # (the centre vbsp moved its brushes about). surf_29_12_06 aims all 13
                # of its live teleports at other teleports' brushes, `g1`..`b4`, `a`,
                # `b`, `jail`; taken as unresolved, every one sent the player to the
                # spawn. Last, because a point entity is what a mapper usually meant.
                brushes.append((entity_origin(e), entity_yaw(e)))
        return out or others or brushes

    def teleports_to(self, name):
        """Every unclaimed `trigger_teleport` aimed at that destination name."""
        want = name.strip().lower()
        return [(i, e) for i, e in self.entities("trigger_teleport")
                if e.get("target", "").strip().lower() == want]

    def named(self, name):
        """Every unclaimed brush entity with that targetname."""
        want = name.strip().lower()
        return [(i, e) for i, e in self.entities()
                if e.get("targetname", "").strip().lower() == want and brush_box(self.bsp, e)]

    # -- building zones ----------------------------------------------------
    def add(self, kind, track, box=None, number=0, destination=None, yaw=0.0, comment=""):
        zone = {"kind": kind, "track": int(track)}
        if number:
            zone["number"] = float(number)
        if box is not None:
            if kind == "RESPAWN":
                lo, hi, grown, how = inflate_pit(box[0], box[1], self.min_thickness, self.solids)
                if how == "hung":
                    zone["hung"] = True
            else:
                lo, hi, grown = inflate(box[0], box[1], self.min_thickness)
            zone["min"], zone["max"] = lo, hi
            zone["original_min"], zone["original_max"] = list(box[0]), list(box[1])
            zone["inflated"] = grown
        if destination is not None:
            zone["destination"] = list(destination)
            zone["destination_yaw"] = float(yaw)
        if comment:
            zone["comment"] = comment
        self.zones.append(zone)
        return zone

    def of_kind(self, kind, track=None):
        return [z for z in self.zones
                if z["kind"] == kind and (track is None or z["track"] == track)]

    def tracks(self):
        return sorted({z["track"] for z in self.zones})


def label_zones(z, ignore=None):
    """The zones the map labelled itself, from `trigger_multiple` targetnames.

    [param ignore] is the zones file's `ignore_labels`: names the map labels as a zone
    that are not one here, each list with a `why`. surf_lt_unicorn's `bonus_startzone_01`
    is a 32-unit trigger inside the portal that drops a player into stage 1, and its
    `bonus_endzone_01` a box round the whole stage: a collectables challenge the map
    scores with logic, not a route a timer can run. A listed name that labels nothing
    stops the import, like every other stale list in a zones file."""
    ignore = ignore or {}
    names = {str(n).strip().lower() for n in ignore.get("names", [])}
    if names and not str(ignore.get("why", "")).strip():
        raise ValueError("ignore_labels names %s without a why" % ", ".join(sorted(names)))
    seen = set()
    found = []
    for i, e in z.entities("trigger_multiple", "trigger_once"):
        name = e.get("targetname", "")
        if not name:
            continue
        if name.strip().lower() in names:
            seen.add(name.strip().lower())
            continue
        role = zone_role(name)
        box = brush_box(z.bsp, e)
        if role is None or box is None:
            continue
        found.append((i, e, name, role, box))

    stale = names - seen
    if stale:
        raise ValueError("ignore_labels names no labelled trigger: %s" % ", ".join(sorted(stale)))
    if names:
        z.notes.append("labels not read (ignore_labels): %s" % ", ".join(sorted(names)))
    tracks = assign_tracks({role[2] for _, _, _, role, _ in found})
    z.track_names = {str(v): (k or "main") for k, v in tracks.items()}

    # Two brushes sharing a targetname are ONE entity in Source, and a mapper uses
    # that: surf_summit's `tm_checkpoint1` is a pair, one in each of the map's two
    # mirrored lanes. Emitted as two zones they are two stage zones with the same
    # number, which `DotTimerZoneSet.problems()` refuses and is right to -- so they
    # are unioned back into the one volume the map always meant them to be.
    merged = {}
    for i, e, name, role, box in found:
        z.claimed.add(i)
        key = name.strip().lower()
        if key in merged:
            merged[key][1].append(box)
        else:
            merged[key] = (role, [box], name)

    for role, boxes, name in merged.values():
        kind, number, track_key = role
        if len(boxes) > 1:
            z.notes.append("%s is %d volumes and was unioned into one"
                           % (name, len(boxes)))
        z.add(kind, tracks.get(track_key, 0), box=union_box(boxes),
              number=number, comment=name)


def resolve_overrides(z, doc):
    """The zones a person worked out, from `maps/zones/<id>.json`.

    [b]Coordinates in that file are Hammer's, not Godot's.[/b] They are read out of
    the .bsp with the tools in this directory and typed in as they were read; the axis
    swap happens once, here, where everything else's does. A file that mixed the two
    would be a file nobody can check against the map.
    """
    for spec in doc.get("zones", []):
        kind = str(spec.get("kind", "")).upper()
        track = int(spec.get("track", 0))
        box = resolve_box(z, spec)
        dest, yaw = resolve_point(z, spec)
        if kind == "STAGE" and box is None and dest is None and spec.get("restart") is False:
            # A stage the MAP labelled that has nowhere to put a player: a gate across
            # open air (surf_greensway's `checkpoint_1`). It stays a split and `!s<n>`
            # is refused with the reason, rather than sending anybody into the canyon.
            number = float(spec.get("number", 0))
            hits = [zz for zz in z.zones if zz["kind"] == "STAGE"
                    and zz["track"] == track and float(zz.get("number", 0)) == number]
            if not hits:
                raise ValueError("stage %g on track %d is marked no-restart and has no zone" % (number, track))
            why = str(spec.get("restart_why", "")).strip()
            if not why:
                raise ValueError("stage %g on track %d is marked no-restart without restart_why" % (number, track))
            for zz in hits:
                zz["no_restart"] = why
            continue
        if kind == "STAGE" and box is None and dest is not None:
            # A destination for a stage the MAP labelled, with no volume of its own:
            # the line is the mapper's and only where `!s<n>` puts a player is ours.
            # surf_summit's `tm_checkpoint2` is a gate whose floor is its fail plane.
            number = float(spec.get("number", 0))
            hits = [zz for zz in z.zones if zz["kind"] == "STAGE"
                    and zz["track"] == track and float(zz.get("number", 0)) == number]
            if not hits:
                raise ValueError("stage %g on track %d has a destination and no zone" % (number, track))
            for zz in hits:
                zz["destination"], zz["destination_yaw"] = list(dest), yaw
            continue
        if kind not in POINT_KINDS and box is None:
            raise ValueError("zone %r in the override resolves to no volume" % spec)
        if box is not None and dest is None and kind in ("STAGE", "SPAWN", "TELEPORT"):
            dest, yaw = floor_of(box), float(spec.get("destination_yaw", around_yaw(z, spec)))
        z.add(kind, track, box=box, number=float(spec.get("number", 0)),
              destination=dest, yaw=yaw, comment=str(spec.get("note", "")))


POINT_KINDS = ("SPAWN",)


# How far above the point it names a destination puts a player, in genre units.
#
# A Source `info_teleport_destination` is at the player's feet and so is the middle of
# a zone's floor, so SOMETHING has to lift a player off it: a foot resting at exactly
# the floor's height is the state dot-player-controller's own notes describe as never
# reporting ground again. It was 8 units, which is 15 cm, and 15 cm turns out to be
# inside the noise.
#
# Measured on Surf_Mesa, whose spawn destination sits 25 units over the platform.
# Dropped from 10168 the player lands; from 10170 the player lands; from **10169**,
# which is where an 8-unit lift put them, the player goes through the floor and keeps
# going -- and moving them one unit in x, or 320 units in y, fixes it. One point on
# one map, and it was the point the map shipped with. A capsule that starts that close
# to a triangle seam is a coin toss, so the answer is not to start there: 24 units is
# clear of the seam and still leaves a 94.5-unit player 9 units of headroom under
# Source's own minimum 128-unit ceiling.
DESTINATION_LIFT = 24.0


def floor_of(box):
    """The middle of a box's floor. Where a `!s3` puts a player.

    [b]A trigger's floor is not the map's floor, and this is where a player is left
    standing inside one.[/b] `box[0][2]` is the bottom of the VOLUME, and a mapper sinks
    a trigger into the ground on purpose so nobody can walk under its lower edge — so on
    every map whose start zone has no `info_player_*` inside it, the spawn came out
    somewhere below the surface. Measured afterwards with `tools/spawn_check.gd`:
    surf_aquaflow's main spawn was **64 units** inside solid, against a 72-unit player.

    The box is still the right answer for WHERE; [method lift_out_of_solid] is what makes
    it an answer for HOW HIGH, and it has the brush data to know.
    """
    return [(box[0][0] + box[1][0]) * 0.5, (box[0][1] + box[1][1]) * 0.5, box[0][2]]


def point_in_brush(bsp, index, point, epsilon=0.1):
    """Is a point inside one brush? True when it is behind every one of its sides.

    A Source brush is the intersection of its half-spaces, so this is the definition
    rather than an approximation of it.
    """
    first, count, _ = bsp.brushes[index]
    for side in bsp.brushsides[first:first + count]:
        pl = bsp.planes[side[0]]
        if pl[0] * point[0] + pl[1] * point[1] + pl[2] * point[2] - pl[3] > epsilon:
            return False
    return True


def lift_out_of_solid(bsp, point, height=72.0, limit=256.0):
    """Raise a spawn point until a player standing on it is not inside a brush.

    Source is Z-up here -- this runs before the axis swap -- so "up" is +Z.

    [b]Checked at the FEET and at the head, because a spawn can be wrong either way.[/b]
    A point on a trigger's floor is usually a few units into the ground; a point under a
    low ceiling is clear at the feet and not at the head, and a player spawned there is
    stuck just as thoroughly.

    Gives up at [param limit] and returns the point unchanged rather than teleporting
    somebody an arbitrary distance: a spawn that is a quarter of the map deep in solid is
    a map this importer has read wrongly somewhere else, and moving it would hide that.

    [b]IT CANNOT SEE DISPLACEMENTS, AND THAT IS THE CASE IT WAS WRITTEN FOR.[/b] Brushes
    are half-spaces and a point test against them is exact; a displacement is terrain,
    welded triangles with no inside, and there is no cheap containment test for one here.
    `surf_aquaflow`'s main spawn — the one that prompted this, 64 units under the surface
    against a 72-unit player — is buried in the reef, which is displacement, so this
    function looks at it and correctly reports it clear. It fixes a spawn inside a BRUSH
    and nothing else, and `tools/spawn_check.gd` still finds 36 bad points across five
    maps after it runs.
    
    The answer is almost certainly not here: the game has a physics world and one shape
    query per spawn at map load would settle brushes and terrain alike, in the one place
    that knows about both. Left in because a brush-buried spawn is still a real case and
    the next person needs to know which half is covered.
    """
    solid = [i for i in range(len(bsp.brushes))
             if bsp.brushes[i][2] & MASK_PLAYERSOLID]

    def blocked(at):
        for probe in (at, [at[0], at[1], at[2] + height * 0.5],
                      [at[0], at[1], at[2] + height - 1.0]):
            for i in solid:
                if point_in_brush(bsp, i, probe):
                    return True
        return False

    if not blocked(point):
        return point

    step = 4.0
    raised = 0.0
    while raised < limit:
        raised += step
        lifted = [point[0], point[1], point[2] + raised]
        if not blocked(lifted):
            return lifted
        step *= 1.5
    return point


def resolve_box(z, spec):
    """A volume from whichever of the override's five ways of naming one it used."""
    ways = [k for k in ("box", "named", "teleport_to", "around", "near") if k in spec]
    if len(ways) > 1:
        raise ValueError("zone %r names its volume %d ways" % (spec, len(ways)))
    if not ways:
        return None
    way = ways[0]

    if way == "box":
        lo, hi = spec["box"]
        return ([min(lo[i], hi[i]) for i in range(3)], [max(lo[i], hi[i]) for i in range(3)])

    if way == "named":
        hits = z.named(spec["named"])
        if not hits:
            raise ValueError("no brush entity is named %r" % spec["named"])
        for i, _ in hits:
            z.claimed.add(i)
        return union_box([brush_box(z.bsp, e) for _, e in hits])

    if way == "teleport_to":
        hits = z.teleports_to(spec["teleport_to"])
        if "max_horizontal" in spec:
            # A destination that is both walked to and fallen to needs telling apart:
            # surf_kitsune's `start` is reached by one door at the end of white and by
            # a pit 6144 units across in the section before it.
            limit = float(spec["max_horizontal"])
            hits = [(i, e) for i, e in hits
                    for b in [brush_box(z.bsp, e)]
                    if b and max(b[1][0] - b[0][0], b[1][1] - b[0][1]) <= limit]
        if not hits:
            raise ValueError("nothing teleports to %r" % spec["teleport_to"])
        if len(hits) > 1 and not spec.get("all", False):
            raise ValueError("%d triggers teleport to %r; say \"all\": true to mean all of them"
                             % (len(hits), spec["teleport_to"]))
        for i, _ in hits:
            z.claimed.add(i)
        return union_box([brush_box(z.bsp, e) for _, e in hits])

    if way == "around":
        around = spec["around"]
        points = resolve_points(z, around["point"])
        if not points:
            raise ValueError("nothing to build a box around in %r" % around)
        e = around.get("extents", [128.0, 128.0, 64.0])
        lo = [min(p[i] for p in points) - e[i] for i in range(3)]
        hi = [max(p[i] for p in points) + e[i] for i in range(3)]
        return lo, hi

    near = spec["near"]
    want = near["point"]
    best, best_d = None, float(near.get("within", 512.0)) ** 2
    for i, ent in z.entities(*near.get("class", "trigger_multiple").split()):
        b = brush_box(z.bsp, ent)
        if b is None:
            continue
        c = [(b[0][k] + b[1][k]) * 0.5 for k in range(3)]
        d = sum((c[k] - want[k]) ** 2 for k in range(3))
        if d <= best_d:
            best, best_d = (i, b), d
    if best is None:
        raise ValueError("no %s near %r" % (near.get("class", "trigger_multiple"), want))
    z.claimed.add(best[0])
    return best[1]


def resolve_points(z, spec):
    """A list of Hammer points from a destination name, a list of them, or a literal."""
    if isinstance(spec, str):
        return [p for p, _ in z.destinations(spec)]
    if spec and isinstance(spec[0], (int, float)):
        return [list(spec)]
    out = []
    for one in spec:
        out.extend(resolve_points(z, one))
    return out


def around_yaw(z, spec):
    """The way a zone built `around` named destinations should face a player it puts there.

    [b]It was always 0, and on surf_kitsune that faced every stage arrival at a wall.[/b] A
    box around `red` puts the player on the box's floor, and the yaw came from the zones
    file or nothing -- so `!s<n>`, a stage restart and the single-R restart turned the
    player a quarter turn from where the mapper's `info_teleport_destination` faces them:
    on kitsune, side-on to a neon wall 3 m away instead of down the section (found against
    two reference runs, 2026-10-09). The named points' own yaw is the mapper's statement
    of which way is forward. Only when they agree: a box around two mirrored team points
    (surf_year3000's `stage02_t` / `stage02_ct`) has no single forward, and keeps 0.
    """
    around = spec.get("around")
    if not isinstance(around, dict):
        return 0.0
    names = around.get("point")
    names = [names] if isinstance(names, str) else names
    if not names or not all(isinstance(n, str) for n in names):
        return 0.0
    yaws = {round(y, 3) for n in names for _, y in z.destinations(n)}
    return yaws.pop() if len(yaws) == 1 else 0.0


def resolve_point(z, spec):
    """The `destination` an override gave a zone, with the yaw that came with it."""
    if "destination" not in spec:
        return None, 0.0
    want = spec["destination"]
    if isinstance(want, str):
        hits = z.destinations(want)
        if not hits:
            raise ValueError("there is no destination named %r" % want)
        return hits[0][0], float(spec.get("destination_yaw", hits[0][1]))
    return list(want), float(spec.get("destination_yaw", 0.0))


def stage_destinations(z):
    """Give every stage zone somewhere `!s<n>` can put a player.

    A stage zone with no destination resolves to the origin, which on every one of
    these maps is a point in the sky -- and nothing errors, because the request
    succeeds. Preferring a destination the mapper drew INSIDE the zone over the middle
    of the zone's own floor matters for the same reason: `failman_s4` faces down the
    map and the middle of a floor faces north.
    """
    for zone in z.zones:
        if zone["kind"] not in ("STAGE", "START", "END") or "min" not in zone:
            continue
        if "destination" in zone:
            continue
        box = (zone.get("original_min", zone["min"]), zone.get("original_max", zone["max"]))
        inside = [(p, y) for e in z.bsp.entities
                  if e.get("classname", "") == "info_teleport_destination"
                  for p, y in [(entity_origin(e), entity_yaw(e))]
                  if box_contains(box, p, 32.0)]
        if inside:
            zone["destination"], zone["destination_yaw"] = inside[0][0], inside[0][1]
        elif zone["kind"] == "STAGE":
            zone["destination"], zone["destination_yaw"] = floor_of(box), 0.0


def implied_zones(z):
    """The two zones a labelled map means without saying.

    A track whose stages start at 1 has already drawn its start line -- stage 1 IS the
    start, in this genre and in Shavit -- and a track whose stages start at 2 has
    drawn a start line and called it that. Both are one zone short of what
    [code]DotTimerZoneSet.problems()[/code] will accept, and in opposite directions.
    """
    for track in z.tracks():
        starts = z.of_kind("START", track)
        stages = z.of_kind("STAGE", track)
        if not stages:
            continue
        first = min(int(s.get("number", 0)) for s in stages)
        if first == 1 and not starts:
            s1 = [s for s in stages if int(s.get("number", 0)) == 1][0]
            z.add("START", track, box=(s1["original_min"], s1["original_max"]),
                  comment="stage 1 is the start line")
        elif first > 1 and starts:
            box = (starts[0]["original_min"], starts[0]["original_max"])
            z.add("STAGE", track, box=box, number=1,
                  destination=starts[0].get("destination"),
                  yaw=starts[0].get("destination_yaw", 0.0),
                  comment="the start line is stage 1")


def spawn_zones(z, spawns, doc, bsp=None):
    """One SPAWN per track: where `spawn_for(track)` puts a player.

    The main track's is NOT simply the biggest cluster of `info_player_*`. On a map
    with a hub -- surf_arcade, surf_beginner2 -- that cluster is the hub, which is not
    on the timed route at all, so a player spawned there can walk around for ever
    without ever crossing a start line. What the start zone contains beats what the
    map's team spawns say, every time.
    """
    given = {int(s.get("track", 0)) for s in doc.get("zones", []) if str(s.get("kind", "")).upper() == "SPAWN"}
    for track in z.tracks():
        if track in given:
            continue
        starts = z.of_kind("START", track)
        at, yaw = None, 0.0
        if starts:
            box = (starts[0].get("original_min", starts[0]["min"]),
                   starts[0].get("original_max", starts[0]["max"]))
            if "destination" in starts[0]:
                at, yaw = starts[0]["destination"], starts[0].get("destination_yaw", 0.0)
            else:
                inside = [s for s in spawns if box_contains(box, s["origin_src"], 32.0)]
                if inside:
                    at, yaw = inside[0]["origin_src"], inside[0]["yaw_src"]
                else:
                    at, yaw = floor_of(box), 0.0
        elif track == 0 and spawns:
            best = pick_spawn(spawns)
            at, yaw = best["origin_src"], best["yaw_src"]
        if at is not None:
            # [b]Every route to `at` above can land inside a brush, and only one of them
            # is obviously wrong.[/b] `floor_of` takes a trigger's own underside, which
            # is below the ground by design; a `destination` is wherever the mapper put
            # an entity, which on a teleport aimed at a doorway can be in the door frame;
            # and an `info_player_*` origin is at the feet, so a map that moved its floor
            # after placing one leaves it buried. Checked here rather than per-route,
            # because the failure is the same and a player stuck in a wall does not care
            # which of the three put them there.
            if bsp is not None:
                at = lift_out_of_solid(bsp, at)
            z.add("SPAWN", track, destination=at, yaw=yaw,
                  comment="the spawn for %s" % z.track_names.get(str(track), "track %d" % track))


def drop_unrunnable_tracks(z):
    """A track with a start and no end cannot be run, so it is not offered as one.

    surf_summit's third bonus is the case: a start zone, eight checkpoints and no
    finish anywhere in the map. Left in, it is a track a player can begin and never
    complete, and one [code]DotTimerZoneSet.problems()[/code] refuses the whole map
    over. Dropped silently it would be a bonus that quietly does not exist, so it is
    reported.
    """
    dropped = []
    for track in z.tracks():
        if track == 0:
            continue
        if z.of_kind("START", track) and not z.of_kind("END", track):
            dropped.append((track, z.track_names.get(str(track), str(track))))
        elif z.of_kind("END", track) and not z.of_kind("START", track):
            dropped.append((track, z.track_names.get(str(track), str(track))))
    gone = {t for t, _ in dropped}
    z.zones = [zone for zone in z.zones if zone["track"] not in gone]
    return dropped


def doorway_teleports(z, rule):
    """Teleports a player walks through, as TELEPORT rather than as RESPAWN.

    [b]The difference decides whether a staged map can be played at all.[/b] Every
    `trigger_teleport` in surf_kitsune targets one of nine colours: the flat ones the
    size of a room are the pit under that colour's section, and the ones the size of a
    door are how you leave one section for the next. Treated alike -- which is what
    "every teleport is a RESPAWN" does -- walking out of the first section ends the run
    and puts the player back at the start, for ever.

    The rule is a measurement, opted into per map, because it is only true of a map
    whose sections are joined by doors: nothing here is a door and 512 units wide.
    """
    limit = float(rule.get("max_horizontal", 512.0))
    made = 0
    for i, e in list(z.entities("trigger_teleport")):
        box = brush_box(z.bsp, e)
        if box is None:
            continue
        if max(box[1][0] - box[0][0], box[1][1] - box[0][1]) > limit:
            continue
        hits = z.destinations(e.get("target", ""))
        if not hits:
            continue
        z.claimed.add(i)
        at, yaw = hits[0]
        z.add("TELEPORT", 0, box=box, destination=at, yaw=yaw,
              comment="through to %s" % e.get("target", ""))
        made += 1
    return made


def brush_boxes(bsp, e):
    """A brush entity's volume as one box PER BRUSH, in world (Hammer) coordinates.

    [b]A trigger is the union of its brushes, and the box around that union is not.[/b]
    A pit a mapper drew as an L, or as thirty-eight strips under thirty-eight gaps, has a
    bounding box that covers every block between them -- and dot-timer's zones are
    boxes, so a respawn zone built from [method brush_box] respawned players on the
    blocks. bhop_tesquo_v2 put three of its own stage arrivals inside one.

    Falls back to nothing, and the caller to [method brush_box], for a model whose tree
    reaches no brush with a hull.
    """
    return [box for _, _, box in brush_boxes_indexed(bsp, e)]


def brush_boxes_indexed(bsp, e):
    """[method brush_boxes], with each box's brush index and the entity's origin, so a
    caller can ask [method point_in_brush] about the brush the box was drawn around."""
    model = e.get("model", "")
    if not model.startswith("*"):
        return []
    index = int(model[1:])
    if not 0 < index < len(bsp.models):
        return []
    o = entity_origin(e)
    out = []
    for i in sorted(bsp.model_brushes(index)):
        pts = bsp.brush_hull(i)
        if len(pts) < 4:
            continue
        out.append((i, o, ([min(p[a] for p in pts) + o[a] for a in range(3)],
                           [max(p[a] for p in pts) + o[a] for a in range(3)])))
    return out


def conditional_teleports(z, rule):
    """Drop the teleports that only fire for a player the map has renamed.

    [b]A filtered `trigger_teleport` is a condition, and this game does not run the
    map's logic.[/b] Source fires one only for an activator its `filter_activator_*`
    passes, and the name a filter tests for is one the map's own outputs gave the
    player -- `AddOutput targetname bhop` on landing, `looking` while a `trigger_look`
    sees you, `fcp7` on reaching a checkpoint. Nothing here ever sets a name, so an
    unconditional translation fires them on everybody: bhop_badges_mini has 252 flat
    pads on its blocks that punish standing still, and every landing respawned.

    Opted into per map, by name, because the same mechanism is also how a checkpoint
    pit is built -- one teleport per checkpoint name over the same drop, each aimed at
    its own section -- and THOSE are pits and must stay RESPAWN. Which a map means is
    in its entity logic, so the map's own file says which filters are conditions, and
    why. A name is either the filter entity's own targetname (what the teleport's
    `filtername` key holds) or the activator name that filter passes; a listed name
    that matches no teleport stops the import, because a stale list is how a trap
    comes back.
    """
    names = [str(n).strip().lower() for n in rule.get("filters", [])]
    passes = {}
    for e in z.bsp.entities:
        if e.get("classname", "").startswith("filter_"):
            passes[e.get("targetname", "").strip().lower()] = \
                e.get("filtername", "").strip().lower()
    used = collections.Counter()
    dropped = 0
    for i, e in list(z.entities("trigger_teleport")):
        own = e.get("filtername", "").strip().lower()
        if not own:
            continue
        for n in names:
            if n == own or n == passes.get(own):
                z.claimed.add(i)
                z.traps.append(e)
                used[n] += 1
                dropped += 1
                break
    stale = [n for n in names if not used[n]]
    if stale:
        raise ValueError("conditional_teleports names filters no teleport uses: %s"
                         % ", ".join(stale))
    z.notes.append("%d conditional teleports dropped (%s)"
                   % (dropped, ", ".join("%s x%d" % kv for kv in sorted(used.items()))))
    return dropped


def clear_arrivals(zone, arrivals):
    """Trim a thickened pit back off any arrival its thickening swallowed.

    [b]The thickness is ours; the trigger is the mapper's.[/b] A grown slab that takes
    in a spawn, a stage or the far side of a door respawns every player the moment they
    arrive, and neither growth direction is always safe: bhop_pandora2_fix puts stage 4
    between two checkpoint pits 136 units apart, so the lower one grown up and the upper
    one grown down each reach it. The importer knows every arrival it made, so the slab
    stops one unit short of one -- on the vertical axis, which is the only one a pit is
    thin on. An arrival inside the mapper's OWN trigger is left alone: that is the map,
    and `headless_imported` reports it rather than this hiding it.
    """
    if not zone.get("inflated"):
        return
    lo, hi = zone["min"], zone["max"]
    olo, ohi = zone["original_min"], zone["original_max"]
    under = over = False
    for p in arrivals:
        if not all(lo[a] <= p[a] < hi[a] for a in range(3)):
            continue
        if all(olo[a] <= p[a] <= ohi[a] for a in range(3)):
            continue
        if p[2] < olo[2]:
            lo[2] = max(lo[2], p[2] + 1.0)
            under = True
        elif p[2] > ohi[2]:
            hi[2] = min(hi[2], p[2] - 1.0)
            over = True
        zone["cleared"] = True
    # [b]Trimmed back toward the mapper's plane, a pit can be thin again[/b], and a
    # player falling at the genre's ceiling steps over it between two ticks
    # (bhop_badges2: a one-unit plane, hung, then trimmed to 16 units by another pit's
    # arrival just under it). It takes back one tick's depth on the side away from the
    # arrival, never over another arrival: at most TICK_DEPTH units, which is less than
    # any block is drawn over its pit.
    if zone.get("cleared") and hi[2] - lo[2] < TICK_DEPTH and under != over:
        want = TICK_DEPTH - (hi[2] - lo[2])

        def clear_of(z0, z1):
            return not any(all(lo[a] <= p[a] < hi[a] for a in range(2)) and z0 <= p[2] <= z1
                           for p in arrivals)

        if under and clear_of(hi[2], hi[2] + want):
            hi[2] += want
        elif over and clear_of(lo[2] - want, lo[2]):
            lo[2] -= want


def pit_tracks(z, e):
    """Which tracks a leftover teleport is a pit FOR: the ones whose start it sends to.

    [b]A zone carries a track and the timer only acts on the run's own, so a pit on
    track 0 catches nobody running a bonus.[/b] Every leftover teleport used to be a
    RESPAWN on the main track, which left surf_beginner2's four bonuses, surf_summit's
    two, surf_arcade's and bhop_pit's with no pit at all -- a player who fell off one
    fell for ever. The map says whose pit it is: a mapper's fail teleport sends a player
    back to the start of the route they fell off, so a teleport whose destination is in
    track N's START volume belongs to track N. One whose destination is in several (a
    shared start) is copied to each; one aimed anywhere else -- a stage reset, a hub --
    stays on the main track, which is what it always was.
    """
    hits = z.destinations(e.get("target", ""))
    if not hits:
        return [0]
    at = hits[0][0]
    tracks = sorted({zz["track"] for zz in z.zones if zz["kind"] == "START"
                     and box_contains((zz.get("original_min", zz["min"]),
                                       zz.get("original_max", zz["max"])), at, 64.0)})
    return tracks or [0]


HULL_SLAB = 256.0
HULL_SLAB_RISE = 48.0
HULL_SLAB_MIN = 48.0
HULL_SLABS_MAX = 64


def hull_boxes(bsp, brush, origin, box):
    """A teleport brush as boxes that are all inside it, rather than one box around it.

    [b]The box around a wedge is not the wedge, and a box is all a zone can be.[/b] A
    mapper's pit under a ramp is routinely a brush whose top follows the slope, and its
    bounding box reaches up over the ramp the slope runs beneath. Surf_Mesa's
    `trigger_teleport` under its last descent is 2,816 by 9,192 units with a roof that
    climbs 3,776 units along it: its box held 158 ramp triangles, and riding them sent
    a player back to the start in the middle of the run (Christian's 2026-10-07 footage,
    0:40 on the timer). [method trim_to_hull] only ever cut the box back off an
    ARRIVAL, so it had lowered this one's top to the door and left everything above the
    slope where it was.

    A brush that IS its box -- every corner on the box -- is returned as it is, which
    is nearly all of them. Anything else is cut into slabs along its longer horizontal
    axis, and each slab is given the vertical extent that is inside the brush at all
    four of its corner columns, solved from the brush's own planes. A convex brush holds
    a box exactly when it holds the box's eight corners, so such a slab is inside the
    mapper's trigger: a player is never teleported from somewhere the map would not, and
    the stair-steps under a slope are at most one slab's rise, which a falling player
    crosses into the slab below.

    [b]A thin sloped sheet has no box inside it at all.[/b] The one under Surf_Mesa's
    island descent is 24 units thick and climbs 4,240, so across any slab wider than a
    few dozen units its top end is above its bottom end's roof. There the slab BOUNDS
    the brush instead -- the lowest floor to the highest roof of its four columns -- and
    the slabs are made narrow enough (`HULL_SLAB_RISE` of climb each) that what it
    over-reaches by is a few dozen units, not the 4,264 of the whole box.
    """
    lo, hi = box
    pts = [[p[a] + origin[a] for a in range(3)] for p in bsp.brush_hull(brush)]
    if all(min(abs(p[a] - lo[a]), abs(p[a] - hi[a])) < 0.5 for p in pts for a in range(3)):
        return [box]
    first, count, _ = bsp.brushes[brush]
    planes = []
    for side in bsp.brushsides[first:first + count]:
        pl = bsp.planes[side[0]]
        # Shifted by the entity's origin, so the box is solved where it is drawn.
        planes.append((pl[0], pl[1], pl[2],
                       pl[3] + pl[0] * origin[0] + pl[1] * origin[1] + pl[2] * origin[2]))

    def column(x, y):
        """The z interval of the brush on one vertical line, or None if it misses."""
        zlo, zhi = -1e9, 1e9
        for nx, ny, nz, d in planes:
            rest = d - nx * x - ny * y
            if abs(nz) < 1e-6:
                if rest < -0.1:
                    return None
            elif nz > 0:
                zhi = min(zhi, rest / nz)
            else:
                zlo = max(zlo, rest / nz)
        return (zlo, zhi) if zlo < zhi else None

    def slabs(axis):
        """Cut along one horizontal axis; also returns how far the cut over-reaches."""
        other = 1 - axis
        n = max(1, min(HULL_SLABS_MAX, int(math.ceil(max((hi[axis] - lo[axis]) / HULL_SLAB,
                                                         (hi[2] - lo[2]) / HULL_SLAB_RISE)))))
        # Never so thin along the cut that a fast player crosses one between two ticks
        # (3500 u/s at 128 Hz is 27 units; `headless_imported` asks every zone that).
        n = max(1, min(n, int((hi[axis] - lo[axis]) // HULL_SLAB_MIN)))
        step = (hi[axis] - lo[axis]) / n
        out, over = [], 0.0
        for i in range(n):
            s0, s1 = lo[axis] + step * i, lo[axis] + step * (i + 1)
            o0, o1 = lo[other] + 1.0, hi[other] - 1.0
            cols = []
            for s in (s0, s1):
                for o in (o0, o1):
                    xy = [0.0, 0.0]
                    xy[axis], xy[other] = s, o
                    cols.append(column(xy[0], xy[1]))
            if any(c is None for c in cols):
                continue
            zb = max(c[0] for c in cols)
            zt = min(c[1] for c in cols)
            if zt - zb < 1.0:
                zb = max(lo[2], min(c[0] for c in cols))
                zt = min(hi[2], max(c[1] for c in cols))
                over += (zt - zb) * step
            a, b = [0.0, 0.0, zb], [0.0, 0.0, zt]
            a[axis], b[axis] = s0, s1
            a[other], b[other] = o0, o1
            out.append((a, b))
        return out, over

    # Along whichever axis the brush climbs: a wedge cut across its slope is a row of
    # slabs each holding the whole climb, which bounds it no better than its box did.
    # The cut that over-reaches less wins, the longer axis on a tie.
    first_axis = 0 if hi[0] - lo[0] >= hi[1] - lo[1] else 1
    out, over = slabs(first_axis)
    alt, alt_over = slabs(1 - first_axis)
    if alt_over < over - 1e-6 or (not out and alt):
        out = alt
    # A brush no slab fits inside (a sliver, a spike) keeps its box: a pit that catches
    # a little too much is a run lost, and one that catches nothing is a player falling
    # forever, which no run survives.
    return out or [box]


def trim_to_hull(zone, arrivals, bsp, brush, origin):
    """Cut a pit's box back off an arrival that is inside the box but not the brush.

    [b]A brush is a hull and a zone is a box, and the box around a wedge is not the
    wedge.[/b] A mapper's pit under a ramp is routinely a sloped or wedge-shaped brush,
    and its bounding box reaches up over whatever the slope leaves clear -- Surf_Mesa's
    door lands 237 units above the sloped top of a 2,816 by 9,072 unit teleport brush and
    well inside its box, so walking through that door respawned the player. Asked with
    [method point_in_brush], which is the definition of inside rather than a guess at it.

    An arrival that IS inside the hull is left alone: that is the map's own trigger, and
    `headless_imported` reports it (`ARRIVES_IN_PIT`) rather than this hiding it. The cut
    is the one of the box's six faces that loses the least volume, the top winning a tie
    because a player a lowered top misses keeps falling into what is left of the box.
    """
    for p in arrivals:
        lo, hi = zone["min"], zone["max"]
        if not all(lo[a] <= p[a] < hi[a] for a in range(3)):
            continue
        if point_in_brush(bsp, brush, [p[a] - origin[a] for a in range(3)]):
            continue
        size = [hi[a] - lo[a] for a in range(3)]
        best = None
        for a in (2, 0, 1):
            for side in ("hi", "lo"):
                removed = (hi[a] - (p[a] - 1.0)) if side == "hi" else ((p[a] + 1.0) - lo[a])
                if removed <= 0.0 or removed >= size[a]:
                    continue
                if best is None or removed / size[a] < best[0] - 1e-9:
                    best = (removed / size[a], a, side)
        if best is None:
            continue
        _, a, side = best
        if side == "hi":
            hi[a] = p[a] - 1.0
        else:
            lo[a] = p[a] + 1.0
        zone["trimmed"] = True


def dead_teleports(z):
    """Drop the teleports whose filter can never pass a player. Not opt-in: a fact.

    A `filter_activator_class` that is not negated passes an activator whose classname
    is its `filterclass`, and a player's is `player`. bhop_tesquo_v2 has seven teleports
    behind four class filters naming classes `filter1`..`filter4`, which nothing in the
    game is, so in Source they never fire for anybody -- and imported as pits they sat
    in a section's start. Unlike [method conditional_teleports] there is nothing to
    decide here: the map's own file says the teleport is inert.
    """
    # Any class but `player`, whether or not the map's logic renames a player's class:
    # bhop_tesquo_v2 does (`AddOutput classname filter1` on each stage line), which makes
    # these checkpoint returns that fire only for a player who reached that stage -- logic
    # this game does not run, and imported unconditionally they are pits in a section's
    # start. Dropped either way. (bsp_mechanics.inert_filters is the assignment-aware
    # rule pushes and blocks are asked by, where being wrong costs a boost, not a run.)
    dead = set()
    for e in z.bsp.entities:
        if e.get("classname", "") != "filter_activator_class":
            continue
        negated = e.get("Negated", "0").strip().lower() in ("1", "filter out entities that match criteria")
        if not negated and e.get("filterclass", "").strip().lower() != "player":
            dead.add(e.get("targetname", "").strip().lower())
    dropped = 0
    noclient = 0
    for i, e in list(z.entities("trigger_teleport")):
        if e.get("filtername", "").strip().lower() in dead:
            z.claimed.add(i)
            dropped += 1
        elif not int(float(e.get("spawnflags", "1") or 0)) & 1:
            # No "Clients" flag: Source never fires it for a player. Five of the 42
            # maps carry one, and imported as a pit it caught people Source never did.
            z.claimed.add(i)
            noclient += 1
    if dropped:
        z.notes.append("%d teleports dropped whose class filter no player passes" % dropped)
    if noclient:
        z.notes.append("%d teleports dropped that do not fire for players (no Clients flag)"
                       % noclient)
    return dropped + noclient


def round_teleports(z, rule):
    """Drop the teleports a round's logic switches on, by name.

    [b]A race surf map runs a round, and this game does not.[/b] The maps of that kind
    end a round when somebody reaches the end: a `trigger_once` there enables a
    `youlose<n>` teleport over every section and a `timesup<n>` a while later, each one
    aimed at a jail, and until then every one of them is `StartDisabled`. This importer
    runs none of a map's outputs, so a teleport that starts disabled was imported as the
    pit it is only after somebody has won: a floor-to-ceiling volume over each section
    that sent a runner to the jail the moment they entered it.

    Not every start-disabled teleport is that. Some are how a map opens its next section
    (a `level<n>` teleport a button enables), and some of the held maps were zoned
    against today's behaviour, so this is opted into per map, by name, exactly like
    [method conditional_teleports]. `fnmatch` patterns (`youlose*`), matched against the
    teleport's targetname, and only a teleport that starts disabled is ever dropped. A
    pattern that drops nothing stops the import: a stale list is how a jail comes back.
    """
    pats = [str(n).strip().lower() for n in rule.get("names", [])]
    used = collections.Counter()
    dropped = 0
    for i, e in list(z.entities("trigger_teleport")):
        if str(e.get("StartDisabled", "0")).strip() != "1":
            continue
        name = e.get("targetname", "").strip().lower()
        # Every pattern a name matches is credited, so overlapping ones (`youlose*` and
        # `youlose3`) are not reported stale; the teleport is dropped once.
        hits = [pat for pat in pats if name and fnmatch.fnmatchcase(name, pat)]
        for pat in hits:
            used[pat] += 1
        if hits:
            z.claimed.add(i)
            dropped += 1
    stale = [n for n in pats if not used[n]]
    if stale:
        raise ValueError("round_teleports names no start-disabled teleport: %s" % ", ".join(stale))
    z.notes.append("%d round teleports dropped (%s)"
                   % (dropped, ", ".join("%s matched %d" % kv for kv in sorted(used.items()))))
    return dropped


def floor_boxes(bsp, solids, props):
    """Everything a player can stand on, as boxes: the brushes, the solid props' hulls and
    each displacement triangle.

    [b]Only for asking whether a spawn has a floor under it[/b] (`pit_catches`). The zone
    rules that grow pits were measured against the brushes alone and keep `solids`; a
    spawn is a different question, and surf_lt_unicorn's bonus starts stand on cloud
    props over open sky, which the brushes say is a drop into the pit far below.
    """
    out = list(solids)
    for pts in props:
        out.append(([min(p[a] for p in pts) for a in range(3)],
                    [max(p[a] for p in pts) for a in range(3)]))
    for f in bsp.faces:
        if f[6] < 0 or bsp.face_material(f)[1] & SKIP_MASK:
            continue
        for t in bsp.displacement_tris(f):
            out.append(([min(p[a] for p in t) for a in range(3)],
                        [max(p[a] for p in t) for a in range(3)]))
    return out


def classify_zones(bsp, min_thickness=MIN_ZONE_THICKNESS, doc=None, solids=None, floors=None):
    """Spawns, and every volume a timer cares about.

    Three passes, in the order of how much they know: what the map labelled, what a
    person worked out and wrote in `maps/zones/<id>.json`, and what is left over --
    which is the pit, and always was.
    """
    doc = doc or {}
    z = Zoner(bsp, min_thickness, solids)
    z.floors = floors if floors is not None else z.solids

    spawns = []
    for e in bsp.entities:
        cls = e.get("classname", "")
        if cls in ("info_player_terrorist", "info_player_counterterrorist",
                   "info_player_start") and "origin" in e:
            src = entity_origin(e)
            # `yaw` is stored converted, like every position beside it: the manifest
            # is Godot axes throughout, and a field that were half-converted is the
            # kind nobody notices until a player spawns facing a wall.
            spawns.append({"origin_src": src, "origin": list(to_godot(src)),
                           "yaw": yaw_to_godot(entity_yaw(e)), "yaw_src": entity_yaw(e)})

    label_zones(z, doc.get("ignore_labels"))
    resolve_overrides(z, doc)
    # After the overrides, which may name a filtered teleport on purpose -- bhop_pit's
    # finish is the one only a player who reached the last checkpoint is sent through.
    dead_teleports(z)
    if "conditional_teleports" in doc:
        conditional_teleports(z, doc["conditional_teleports"])
    if "round_teleports" in doc:
        round_teleports(z, doc["round_teleports"])
    if "doorways" in doc:
        doorway_teleports(z, doc["doorways"])
    implied_zones(z)
    stage_destinations(z)
    spawn_zones(z, spawns, doc, bsp)
    dropped = drop_unrunnable_tracks(z)

    push, other = [], []
    for i, e in z.entities("trigger_push", "trigger_multiple", "trigger_once"):
        box = brush_box(bsp, e)
        if box is None:
            continue
        if e.get("classname") == "trigger_push":
            push.append({"min": list(to_godot(box[0])), "max": list(to_godot(box[1]))})
        else:
            other.append({"min": list(to_godot(box[0])), "max": list(to_godot(box[1])),
                          "targetname": e.get("targetname", ""),
                          "filtername": e.get("filtername", "")})

    # What is left of the teleports is the pit: the volume that catches a player who
    # fell off the ride, which is what RESPAWN is and always was the reliable half.
    arrivals = [[zz["destination"][0], zz["destination"][1],
                 zz["destination"][2] + DESTINATION_LIFT]
                for zz in z.zones
                if zz.get("destination") is not None and zz["kind"] in ("SPAWN", "STAGE", "TELEPORT")]
    # And every place a pit sends somebody, now that a pit sends somebody somewhere: a
    # slab grown over its own section's start would catch the player it just put there,
    # on every tick, for ever.
    for _i, e in z.entities("trigger_teleport"):
        for at, _yaw in z.destinations(e.get("target", ""))[:1]:
            arrivals.append([at[0], at[1], at[2] + DESTINATION_LIFT])
    respawn = []
    for i, e in z.entities("trigger_teleport"):
        # [b]A pit sends a player where the map says, not to the start.[/b] Every one of
        # these used to send a player back to the track's spawn, which is a restart --
        # on a staged bhop map, falling in section five put you back in section one and
        # took the run with it, and on bhop_eazy every gate between its sections did the
        # same, because a gate is a teleport too. Source sends the player to the
        # trigger's own destination and the run goes on, so that is what the zone carries
        # now; only a teleport whose target resolves to nothing still means the spawn.
        sends = z.destinations(e.get("target", ""))
        sends_to, sends_yaw = (sends[0] if sends else (None, 0.0))
        boxes = brush_boxes_indexed(bsp, e)
        if not boxes:
            box = brush_box(bsp, e)
            if box is None:
                continue
            boxes = [(None, None, box)]
        z.claimed.add(i)
        pieces = []
        for brush, origin, box in boxes:
            cut = hull_boxes(bsp, brush, origin, box) if brush is not None else [box]
            for piece in cut:
                pieces.append((brush, origin, piece, box if len(cut) > 1 else None))
        for track in pit_tracks(z, e):
            for brush, origin, box, full in pieces:
                sliced = full is not None
                zone = z.add("RESPAWN", track, box=box, destination=sends_to, yaw=sends_yaw)
                if sliced:
                    # A slab of a sloped brush has the route right above it by
                    # construction, and its neighbours on either side by construction
                    # too: `inflate_pit` growing it sideways reaches over the next
                    # slab's slope, and growing it up reaches the ride. So it is not
                    # grown sideways at all -- the slabs tile the brush, and a pit needs
                    # depth, not width -- and every unit of depth it needs goes down.
                    lo, hi = list(box[0]), list(box[1])
                    zone["inflated"] = False
                    for a in (0, 1):
                        # Across the cut a slab spans the whole brush, so growing it
                        # there reaches over nothing a neighbour has; along the cut it
                        # would. A brush narrower than a pit may be still gets its
                        # width, centred, as it did before it was cut.
                        whole = abs(lo[a] - full[0][a]) < 1.5 and abs(hi[a] - full[1][a]) < 1.5
                        if whole and hi[a] - lo[a] < z.min_thickness:
                            grow = (z.min_thickness - (hi[a] - lo[a])) / 2.0
                            lo[a], hi[a] = lo[a] - grow, hi[a] + grow
                            zone["inflated"] = True
                    if hi[2] - lo[2] < z.min_thickness:
                        lo[2] = hi[2] - z.min_thickness
                        zone["hung"] = True
                        zone["inflated"] = True
                    zone["min"], zone["max"] = lo, hi
                clear_arrivals(zone, arrivals)
                if brush is not None:
                    trim_to_hull(zone, arrivals, bsp, brush, origin)
                respawn.append({"min": zone["min"], "max": zone["max"],
                                "inflated": zone["inflated"],
                                "hung": bool(zone.get("hung")),
                                "cleared": bool(zone.get("cleared")),
                                "trimmed": bool(zone.get("trimmed")),
                    "track": track,
                                "original_min": zone["original_min"],
                                "original_max": zone["original_max"]})

    # A pit whose destination is inside another pit is usually a HUB, not a loop: the
    # speed-stopping box mappers send a fallen player into so that the second teleport,
    # the one in the box, puts them at the stage start with no speed (bhop_arcane_v2's
    # `stage1_stop`: 239 of its 334 pits). The chain is followed to where it ends and the
    # pit sends there; a chain that comes back round, or runs into a pit with nowhere to
    # send, falls back to the spawn, which is what every pit did before, and is counted.
    pits = [zz for zz in z.zones if zz["kind"] == "RESPAWN"]

    def pit_at(point):
        p = [point[0], point[1], point[2] + DESTINATION_LIFT]
        for o in pits:
            if all(o["min"][a] <= p[a] <= o["max"][a] for a in range(3)):
                return o
        return None

    # A pit around a team spawn, or in the drop right under one, keeps sending to the
    # spawn -- unless a SPAWN zone stands in it, when the spawn follows it instead
    # (spawn_through_pits, below). What stays here is the maps with no SPAWN zone, the
    # combat maps, whose spawn rooms lead into the round's own logic (a random stage, a
    # jail; followed, players fell 80 to 500 m), and pits under a spawn that stands on a
    # floor. Sending to the spawn is what every pit did before 2026-10-08.
    spawn_zones_now = [zz for zz in z.zones
                       if zz["kind"] == "SPAWN" and zz.get("destination") is not None]
    followed = {id(p) for p in pits for sz in spawn_zones_now
                if p.get("destination") is not None and p["track"] == sz["track"]
                and pit_catches(z, p, sz["destination"])}
    spawn_points = [zz["destination"] for zz in spawn_zones_now]
    spawn_points += [sp["origin_src"] for sp in spawns if "origin_src" in sp]
    held = 0
    for zz in pits:
        if zz.get("destination") is None or id(zz) in followed:
            continue
        for sp in spawn_points:
            inside_xy = all(zz["min"][a] - 16.0 <= sp[a] <= zz["max"][a] + 16.0 for a in (0, 1))
            inside = inside_xy and zz["min"][2] - 16.0 <= sp[2] <= zz["max"][2] + 16.0
            if inside or (inside_xy and sp[2] - 512.0 <= zz["max"][2] <= sp[2] + 96.0):
                del zz["destination"]
                zz.pop("destination_yaw", None)
                held += 1
                break
    if held:
        z.notes.append("%d pits around or under a team spawn send to the spawn" % held)

    looped = chained = 0
    for zz in pits:
        at = zz.get("destination")
        if at is None:
            continue
        yaw = zz.get("destination_yaw", 0.0)
        seen = {id(zz)}
        ok = True
        for _hop in range(8):
            q = pit_at(at)
            if q is None:
                break
            if id(q) in seen or q.get("destination") is None:
                ok = False
                break
            seen.add(id(q))
            at, yaw = q["destination"], q.get("destination_yaw", 0.0)
        else:
            ok = False
        if not ok:
            del zz["destination"]
            zz.pop("destination_yaw", None)
            looped += 1
        elif len(seen) > 1:
            zz["destination"], zz["destination_yaw"] = list(at), yaw
            chained += 1
    if chained:
        z.notes.append("%d pits send through a hub teleport; they send to where it ends" % chained)
    if looped:
        z.notes.append("%d pits send round a loop; they send to the spawn instead" % looped)

    moved = spawn_through_pits(z, pits)
    if moved:
        z.notes.append("%d spawns stand in or over a teleport; they spawn where it sends" % moved)

    return z, spawns, respawn, push, other, dropped


def pit_catches(z, pit, at):
    """Whether a player put at [param at] (feet, Hammer axes) is taken by [param pit] at once.

    Inside the zone as the game will test it (grown, hung and trimmed off the arrivals),
    or over it with nothing to stand on in between: a player who appears there falls into
    it on the first ticks. A spawn on a platform with a pit under the platform is neither,
    which is what the floor test is for -- every start pad over a canyon has a pit
    somewhere below. Not the trigger as the mapper drew it: surf_lt_unicorn's bonus 3
    starts inside a 32,000-unit teleport the importer has already cut back off that start.
    """
    lo, hi = pit["min"], pit["max"]
    if not all(lo[a] - 16.0 <= at[a] <= hi[a] + 16.0 for a in (0, 1)):
        return False
    # Touching: the feet inside the trigger's height, or within the two units under the feet
    # that G2GMapMechanics.TOUCH_BELOW also gives (a trigger sheet lying on the floor). Not
    # sixteen: bhop_badges' `1.1` stands nine units over its own section's fail sheet.
    if lo[2] - 16.0 <= at[2] <= hi[2] + 2.0:
        return True
    if not hi[2] < at[2] <= hi[2] + 512.0:
        return False
    feet = ([at[0] - 16.0, at[1] - 16.0, 0.0], [at[0] + 16.0, at[1] + 16.0, 0.0])
    return not stands_between(getattr(z, "floors", z.solids), feet, hi[2], at[2] + 1.0)


def spawn_through_pits(z, pits):
    """Move every spawn that stands in or over a teleport to where that teleport sends.

    [b]A spawn room is how some maps start, and the room is not where you play.[/b]
    bhop_lego2, kz_bhop_yonkoma's `map0stato` and bhop_badges put the player in a sealed box
    -- `tools/toolsblack` or `cs_italy/black` walls, which the original engine draws black
    too -- whose floor is a `trigger_teleport`: you appear, you drop, and the first touch
    sends you to the course. From 2026-10-08 to 2026-10-11 such a pit sent to the spawn
    instead (so a start zone drawn round the spawn kept its player), and three maps held
    every player in a black box for ever, which is how it was found: "renders black from
    spawn". The spawn goes where the map sends it, as the original does, and a start zone
    belongs round where the player lands (bhop_badges' zones file).

    Followed through a chain (a spawn room into a hub into the course), at most eight
    hops, never round a loop. Only SPAWN zones move: a map with none (no start, no zones
    file saying where) keeps the picked team spawn, because those are the combat maps,
    whose spawn rooms lead into the map's own round logic (a random stage, a jail) and
    not to a course; bhop_lego2's zones file names its `spawn_tele`.
    """
    targets = [zz for zz in z.zones if zz["kind"] == "SPAWN" and zz.get("destination") is not None]
    moved = 0
    for zz in targets:
        seen = []
        for _hop in range(8):
            # Only the spawn's own track's pits: the timer acts on no other, so a pit of the
            # main track around a bonus start (surf_lt_unicorn's 32,000-unit cheater
            # teleport round bonus 3) moves nobody who spawns there.
            pit = next((p for p in pits if p.get("destination") is not None and p is not zz
                        and p["track"] == zz["track"] and pit_catches(z, p, zz["destination"])),
                       None)
            if pit is None or any(pit is q for q in seen):
                break
            seen.append(pit)
            zz["destination"] = list(pit["destination"])
            zz["destination_yaw"] = pit.get("destination_yaw", 0.0)
        if seen:
            zz["comment"] = (zz.get("comment", "") + "; through the teleport it stands in").lstrip("; ")
            moved += 1
    return moved


def emit_zones(z):
    """The zone list as the manifest carries it: genre units, Godot axes."""
    out = []
    for zone in z.zones:
        one = {"kind": zone["kind"], "track": zone["track"]}
        if "number" in zone:
            one["number"] = zone["number"]
        if "min" in zone:
            a, b = to_godot(zone["min"]), to_godot(zone["max"])
            one["min"] = [min(a[i], b[i]) for i in range(3)]
            one["max"] = [max(a[i], b[i]) for i in range(3)]
            one["inflated"] = zone["inflated"]
        if "destination" in zone and zone["destination"] is not None:
            at = to_godot(zone["destination"])
            one["destination"] = [at[0], at[1] + DESTINATION_LIFT, at[2]]
            one["destination_yaw"] = yaw_to_godot(zone.get("destination_yaw", 0.0))
        if zone.get("comment"):
            one["comment"] = zone["comment"]
        if zone.get("no_restart"):
            one["restart"] = False
            one["restart_why"] = zone["no_restart"]
        out.append(one)
    return out


def pick_spawn(spawns):
    """The spawn a map should start you at.

    One of these maps has up to 144 of them in two team blocks. The lowest-numbered
    is arbitrary; the CENTRE of the biggest cluster is where the mapper put the start
    pad, and taking the mean over all of them is wrong the moment a map spawns two
    teams at opposite ends.
    """
    if not spawns:
        return {"origin": [0.0, 64.0, 0.0], "origin_src": [0.0, 0.0, 64.0],
                "yaw": yaw_to_godot(0.0), "yaw_src": 0.0}
    best, bestn = spawns[0], 0
    for s in spawns:
        n = sum(1 for o in spawns
                if sum((o["origin"][i] - s["origin"][i]) ** 2 for i in range(3)) < 512 ** 2)
        if n > bestn:
            best, bestn = s, n
    return best


# ------------------------------------------------------------------- driver ---
def _numbers(value, count):
    """The first [param count] numbers out of a Source key like `"235 222 177 600"`."""
    parts = str(value).replace(",", " ").split()
    out = []
    for token in parts[:count]:
        try:
            out.append(float(token))
        except ValueError:
            return None
    return out if len(out) == count else None


def tonemap_exposure(bsp):
    """{"min", "max"} of the auto-exposure range a map sets on its `env_tonemap_controller`.

    Maps set it from a `logic_auto`'s `OnMapSpawn` (`@tonemap,SetAutoExposureMin,0.2,...`),
    never on the controller itself, so every entity's outputs are scanned for a call on a
    controller's targetname. Empty when the map does not say. Why it is read: the engine's
    exposure sits between min and max, and a map that caps max at 0.2-1 is darker than the
    lightmap alone says. surf_aquaflow's floor measured 136 in ours and 85 in the footage.
    """
    names = {str(e.get("targetname", "")) for e in bsp.entities
             if e.get("classname") == "env_tonemap_controller" and e.get("targetname")}
    got = {}
    for e in bsp.entities:
        for value in e.values():
            if not isinstance(value, str):
                continue
            for line in value.split("\n"):
                parts = line.split(",")
                if len(parts) >= 3 and parts[0] in names:
                    key = {"setautoexposuremin": "min", "setautoexposuremax": "max"}.get(parts[1].lower())
                    if key:
                        try:
                            got[key] = float(parts[2])
                        except ValueError:
                            pass
    return got if len(got) == 2 else {}


def lighting_of(bsp):
    """The lighting the map already describes, as a document a renderer can read.

    [b]Every one of these maps says how it is lit and nothing has ever read it.[/b] The
    geometry, the zones, the spawns and the baked lightmap all come out of the .bsp, and
    then the sun angle, the sun colour, the ambient colour, the fog and the sky name --
    which the mapper set deliberately and which vrad and the engine both used -- were
    left in the entity lump. So an imported map is drawn under a hardcoded sun at
    (-55, -35) with a flat blue-grey background, on every map, whatever the map says.
    `Surf_Mesa` wants a sun at -28 degrees in warm 235/222/177 with fog from 5000 units;
    `surf_beginner2` wants one straight overhead in 255/211/168. They looked like two
    different games and they were lit like one.

    Everything here is optional: a map with no `light_environment` returns a document
    with no sun in it, and the consumer keeps its own default. That is the same contract
    as every other block in this manifest -- absent means "nothing said", never zero.

    Source's `_light` is four numbers, RGB plus a brightness that is NOT a multiplier on
    a 0-255 colour but the intensity vrad compiled with; it is carried through as it
    stands rather than folded in, because what a renderer should do with 600 is a
    renderer's decision and folding it here would throw the colour away.
    """
    out = {}

    env = next((e for e in bsp.entities if e.get("classname") == "light_environment"), None)
    if env is not None:
        sun = {}
        angles = _numbers(env.get("angles", ""), 3)
        # `pitch` overrides the pitch in `angles` when both are present, which is a
        # Source quirk rather than a choice: the entity has a separate pitch key because
        # angles[0] is clamped in Hammer's UI and mappers need the range.
        pitch = _numbers(env.get("pitch", ""), 1)
        if angles:
            sun["yaw_src"] = angles[1]
            sun["pitch_src"] = pitch[0] if pitch else angles[0]
        elif pitch:
            sun["pitch_src"] = pitch[0]
        light = _numbers(env.get("_light", ""), 4)
        if light:
            sun["colour"] = [c / 255.0 for c in light[:3]]
            sun["brightness"] = light[3]
        ambient = _numbers(env.get("_ambient", ""), 4)
        if ambient:
            sun["ambient_colour"] = [c / 255.0 for c in ambient[:3]]
            sun["ambient_brightness"] = ambient[3]
        spread = _numbers(env.get("SunSpreadAngle", ""), 1)
        if spread:
            sun["spread_degrees"] = spread[0]
        if sun:
            out["sun"] = sun

    fog_ent = next((e for e in bsp.entities
                    if e.get("classname") == "env_fog_controller"), None)
    if fog_ent is not None:
        fog = {}
        for key, name in (("fogstart", "start"), ("fogend", "end"),
                          ("fogmaxdensity", "max_density")):
            value = _numbers(fog_ent.get(key, ""), 1)
            if value:
                fog[name] = value[0]
        colour = _numbers(fog_ent.get("fogcolor", ""), 3)
        if colour:
            fog["colour"] = [c / 255.0 for c in colour]
        # `fogenable` absent means off in Source, so absence is a real answer here and
        # not a missing one.
        fog["enabled"] = str(fog_ent.get("fogenable", "0")).strip() in ("1", "true")
        if len(fog) > 1:
            out["fog"] = fog

    exposure = tonemap_exposure(bsp)
    if exposure:
        out["exposure"] = exposure

    world = next((e for e in bsp.entities if e.get("classname") == "worldspawn"), None)
    if world is not None and world.get("skyname"):
        out["sky_name"] = str(world["skyname"])

    # The 3D skybox's camera, read here from the entity and not from `skybox_of`, so the
    # suite has a second path to "this map has a skybox" that does not trust the one
    # that draws it.
    cam = next((e for e in bsp.entities if e.get("classname") == "sky_camera"), None)
    if cam is not None:
        out["sky_camera"] = {"origin": _numbers(cam.get("origin", ""), 3),
                             "scale": (_numbers(cam.get("scale", "16"), 1) or [16.0])[0]}

    # The count only, not the lights. A point light in Source is an input to vrad and
    # its output is already in the lightmap this importer bakes down -- placing 148 real
    # lights would light the map twice. It is carried because "this map has 148 lights
    # in it and none of them are dynamic" is worth being able to say out loud, and
    # because a renderer that ever wants glow around them needs to know they exist.
    out["baked_light_count"] = sum(
        1 for e in bsp.entities
        if e.get("classname") in ("light", "light_spot")
    )

    return out


def load_overrides(path, map_id):
    """What a person worked out about a map, from `maps/zones/<id>.json`.

    [b]Kept beside the repository and not beside the import, because the import is
    output.[/b] `tools/import_maps.sh --force` rewrites every manifest; a hand-written
    zone that lived in one would survive exactly until somebody re-imported the map it
    describes, and would then be gone with nothing saying so.
    """
    if not path:
        return {}
    doc_path = os.path.join(path, map_id + ".json")
    if not os.path.exists(doc_path):
        return {}
    with open(doc_path) as fh:
        return json.load(fh)


ATTRIBUTION_FIELDS = ("author", "source", "recorded")


def attribution_problem(doc, map_id):
    """Why [param doc] does not credit the map, or None when it does.

    [b]An imported map is somebody else's work, kept on the condition that its author is
    credited[/b] (`[credit-1]`). Every map in `maps/zones/` carries an `attribution`
    block -- author, where it came from, the date it was recorded -- and this refuses one
    that does not, the way a finish that does not resolve makes a map unimportable: it is
    the only thing that stops the next forty maps arriving uncredited. The fix is always a
    person writing it down, in `maps/zones/<id>.json`; see its README.
    """
    block = doc.get("attribution")
    if not isinstance(block, dict):
        return ("maps/zones/%s.json has no `attribution` block (author, source, "
                "archive, recorded); an imported map is not importable until its "
                "author is written down" % map_id)
    missing = [k for k in ATTRIBUTION_FIELDS if not str(block.get(k) or "").strip()]
    if missing:
        return "maps/zones/%s.json's attribution has no %s" % (map_id, ", ".join(missing))
    return None


def open_doors(bsp, specs):
    """Take the doors a map's button opens out of the import (`"open_doors"`), and say how many.

    Each spec is `{"name": "<door targetname>", "note": "..."}`. A `func_door*` of that name is
    removed from the entity list before anything reads it, so it is neither solid nor drawn:
    the doorway it closed is open, which is where the map's own button leaves it a moment
    after a press. [b]This importer runs no outputs[/b], so a door that only a button opens
    stayed shut for good and sealed whatever was behind it. surf_ski_2's catch-all floor
    teleport puts a fallen player in a jail whose only way out is such a door: every player
    and bot that fell was stuck. Opt-in and by name (a keypad door is a puzzle, a round's
    door is a rule), and a name that matches no door stops the import.
    """
    opened = 0
    for spec in specs:
        want = str(spec["name"]).strip().lower()
        doors = [e for e in bsp.entities
                 if e.get("classname", "").startswith("func_door")
                 and e.get("targetname", "").strip().lower() == want]
        if not doors:
            raise ValueError("open_doors: no func_door is named %r" % spec["name"])
        bsp.entities[:] = [e for e in bsp.entities if not any(e is d for d in doors)]
        opened += len(doors)
    return opened


def remove_geometry(bsp, specs):
    """Cut world geometry out of a map, where its zones file says to (`"remove"`).

    Each spec is `{"box": [[x, y, z], [x, y, z]], "note": "..."}` in Hammer units. A
    world brush whose whole hull is inside a box is dropped, and so is every world face
    that belongs only to dropped brushes -- judged by its centre, which a face shares
    with the brush it was cut from. "Only" is what keeps a floor: the face under a
    dropped wall also lies on the floor brush that stays, so it stays too.

    [b]On the Bsp, not in each consumer.[/b] Collision, drawing, water, ladders, clips
    and the mechanics all read `model_brushes(0)` and `model_faces(0)`; filtering those
    two drops the geometry from every one of them at once, where a filter in each would
    be six places for the next consumer to miss. Brush entities are untouched.

    surf_year3000's spawn was a sealed 240 x 128 unit void between two arrival booths,
    and the request was to take the middle building away rather than move the spawn.
    Returns (brushes dropped, faces dropped).
    """
    boxes = []
    for spec in specs:
        lo, hi = spec["box"]
        boxes.append(([min(lo[k], hi[k]) for k in range(3)], [max(lo[k], hi[k]) for k in range(3)]))

    def inside(pts):
        return bool(pts) and any(
            all(lo[k] - 0.5 <= p[k] <= hi[k] + 0.5 for p in pts for k in range(3))
            for lo, hi in boxes)

    world = bsp.model_brushes(0)
    gone = {i for i in world if inside(bsp.brush_hull(i))}
    kept = world - gone

    def on_any(point, brushes):
        return any(point_in_brush(bsp, i, point, 0.5) for i in brushes)

    # Only kept brushes near a box can share a face with a dropped one.
    near = {i for i in kept if any(
        all(lo[k] - 16 <= c[k] <= hi[k] + 16 for k in range(3))
        for c in bsp.brush_hull(i) for lo, hi in boxes)}
    gone_faces = set()
    for f in bsp.model_faces(0):
        pts = bsp.face_points(f)
        if not pts:
            continue
        centre = [sum(p[k] for p in pts) / len(pts) for k in range(3)]
        if on_any(centre, gone) and not on_any(centre, near):
            gone_faces.add(id(f))

    model_brushes, model_faces = bsp.model_brushes, bsp.model_faces
    bsp.model_brushes = lambda model=0: model_brushes(model) - gone if model == 0 else model_brushes(model)
    bsp.model_faces = lambda model=0: ([f for f in model_faces(0) if id(f) not in gone_faces]
                                       if model == 0 else model_faces(model))
    return len(gone), len(gone_faces)


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bsp")
    ap.add_argument("out_dir")
    ap.add_argument("--id", default=None, help="map id (default: the file stem)")
    ap.add_argument("--tier", type=int, default=3)
    ap.add_argument("--zones-dir", default=None, dest="zones_dir",
                    help="where per-map zone overrides live "
                         "(default <repo>/maps/zones; see load_overrides)")
    ap.add_argument("--prototype", choices=("auto", "all", "off"), default="auto",
                    help="paint surfaces with the prototype texture set: `auto` only "
                         "where the .bsp carried no texture of its own (default), "
                         "`all` everywhere, `off` never")
    ap.add_argument("--max-slope", type=float, default=MAX_SLOPE_DEGREES,
                    dest="max_slope",
                    help="the steepest a player can stand on, in degrees; the line "
                         "between a PLATFORM and a RAMP. Must match G2GConfig.max_slope "
                         "(default %g)" % MAX_SLOPE_DEGREES)
    ap.add_argument("--min-zone-thickness", type=float, default=MIN_ZONE_THICKNESS,
                    dest="min_zone_thickness",
                    help="least a zone volume may measure on any axis, in genre units "
                         "(default %d; see MIN_ZONE_THICKNESS)" % MIN_ZONE_THICKNESS)
    a = ap.parse_args(argv)

    map_id = (a.id or os.path.splitext(os.path.basename(a.bsp))[0]).lower()
    zones_dir = a.zones_dir
    if zones_dir is None:
        zones_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "maps", "zones")
    doc = load_overrides(zones_dir, map_id)

    out_dir = a.out_dir
    if doc.get("kind") == "arena" and os.path.basename(os.path.normpath(out_dir)) == "imported":
        # A combat map is not a course and is not kept in g2gfast-maps (2026-10-17): it goes
        # to the repository game-arena links at its own maps/imported, so the .import
        # markers written here still match the path they are mounted at.
        out_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..",
                               "arena-surf-dm-maps", "maps")
        print("  kind arena: written to %s" % os.path.normpath(out_dir))
    d = os.path.join(out_dir, map_id)
    os.makedirs(d, exist_ok=True)

    uncredited = attribution_problem(doc, map_id)
    if uncredited is not None:
        print("refused: %s" % uncredited, file=sys.stderr)
        return 2

    bsp = Bsp(a.bsp).load()
    if doc.get("remove"):
        gone_b, gone_f = remove_geometry(bsp, doc["remove"])
        print("  removed %d brush(es) and %d face(s) the zones file cuts out" % (gone_b, gone_f))
    if doc.get("open_doors"):
        print("  opened %d door(s) the zones file names" % open_doors(bsp, doc["open_doors"]))
    # A "fake skybox" is a brush a mapper painted to look like sky -- a custom texture,
    # not `tools/toolsskybox`, so SKIP_MASK does not know it. Its pixels never ship, so
    # it came out as a pale prototype slab across the sky (surf_interference's white
    # wedge over the start). Not drawing it lets the real sky show, which is what it was
    # standing in for. Collision comes from the brushes and is untouched.
    drawn = [(f, o) for f, o in drawn_faces(bsp)
             if not (bsp.face_material(f)[1] & SKIP_MASK)
             and "skybox" not in clean_material(bsp.face_material(f)[0])]
    # A map's zones file can turn the backdrop off (`"skybox": false`) where drawing it
    # is measurably not what the map looks like -- see maps/zones/README.md. Its faces are
    # then left out entirely: drawing the miniature where it was compiled is never right.
    sky = skybox_of(bsp)
    sky_off = sky is not None and doc.get("skybox", True) is False
    sky_faces = 0
    walls, wall_material = sky_walls(bsp, doc.get("sky_walls"), drawn,
                                     None if sky is None else sky[2])

    notes = []
    if walls:
        notes.append("%d sky faces drawn as walls (sky_walls: %s)" % (
            len(walls), ", ".join("%s x%d" % kv for kv in sorted(
                collections.Counter(m for m, _td in wall_material.values()).items()))))
    pak = read_pak(bsp, notes)

    # Static props, and one light probe per prop drawn -- they have to be known before
    # the atlas is packed, because their light goes into it, and before the 3D skybox is
    # placed, because how far its props reach decides the scale it is drawn at.
    all_props, props_drawn, props_stock, props_standin = load_props(bsp, pak, notes, sky_dynamic_props(bsp, sky))
    sky_scale, sky_near, sky_far = sky_drawn_scale(bsp, sky, drawn, props_drawn) or (None, 0.0, 0.0)
    if sky is not None:
        o, k, box = sky[0], sky_scale, sky[2]
        moved = []
        for f, off in drawn:
            pts = bsp.face_points(f)
            if pts and all(in_box((p[0] + off[0], p[1] + off[1], p[2] + off[2]), box)
                           for p in pts):
                sky_faces += 1
                if not sky_off:
                    moved.append((f, (o[0] - off[0], o[1] - off[1], o[2] - off[2], k)))
            else:
                moved.append((f, off))
        drawn = moved
    faces = [f for f, _ in drawn]

    if sky is not None:
        o, k, box = sky[0], sky_scale, sky[2]
        if sky_off:
            props_drawn = [(pr, m) for pr, m in props_drawn if not in_box(pr["origin"], box)]
        for pr, _m in props_drawn:
            if in_box(pr["origin"], box):
                pr["skybox"] = True
                pr["origin"] = tuple((pr["origin"][a] - o[a]) * k for a in range(3))
                pr["scale"] = pr["scale"] * k
    props_drawn = drop_unsupported_standins(bsp, props_drawn, notes)
    probes = bsp_props.AmbientProbes(bsp)
    ground = bsp_props.GroundLight(bsp, faces, bsp._lump(LUMP_LIGHTING)) if props_drawn else None
    blocks, block_of, block_index = [], [], {}
    open_sky = ground.open_sky() if ground is not None else None
    props_open_sky = 0
    for pr, _meshes in props_drawn:
        # A stand-in box takes the typical light around it (`GroundLight.local`), never the
        # floor `at` finds under it: on surf_dust2 that was an interior a storey down for a
        # crate on a roof or on sand, 1000 times dimmer than the sun, and a box with no probe
        # at all drew unlit, white, beside a basket lit black. The same number for every
        # box of a spot is what makes them read as part of it.
        if pr.get("standin"):
            under = ground.local(pr["lighting_origin"], share=0.75) or open_sky
            # No probe either: a leaf's cube adds to the ground light, so a crate in a
            # sunlit leaf drew pale beside its neighbour in a dark one, same texture.
            probe = None
        else:
            under = ground.at(pr["lighting_origin"])
            probe = probes.cube(pr["lighting_origin"])
        if under is None and probe is not None and not pr.get("standin"):
            # A probe and nothing lit under it: a 3D-skybox prop over its sky room's tool
            # walls, one hanging in the open, or one on displacement terrain, which `at`
            # cannot see. Lit by the cube alone it was a black silhouette -- 583 of
            # surf_greensway's trees and grass -- so it takes the light a sunlit floor of
            # this map gets instead (`g2g-maps-1`).
            #
            # [b]Not a prop with NO probe.[/b] That one has always pointed at the atlas's
            # white patch and drawn unlit, at its own texture's colour -- surf_arcade's
            # cabinets, surf_aquaflow's dome frames and half its `u_ramps` -- and lighting
            # those with this as well was tried and rendered: the cabinets went from their
            # purple and green to near-black against a white map, and the dome from white
            # to grey. Unlit is closer to what those maps are, measured by looking.
            under = open_sky
            props_open_sky += under is not None
        cube = bsp_props.lit_cube(probe, under)
        if cube is None:
            block_of.append(None)
            continue
        key = tuple(round(c, 3) for col in cube for c in col)
        if key not in block_index:
            block_index[key] = len(blocks)
            blocks.append(bsp_props.light_block(cube))
        block_of.append(block_index[key])

    lm_path = os.path.join(d, map_id + "_lightmap.png")
    place, lm_w, lm_h, lm_clipped = build_lightmap(bsp, faces, lm_path, blocks)

    # The textures are decoded BEFORE the mesh, because which of them the pakfile
    # actually carried is what decides whether a surface gets the map's own UVs or a
    # world-placed prototype grid, and a vertex can only carry one of the two.
    prop_mats = prop_materials(pak, props_drawn)
    materials = sorted({clean_material(bsp.face_material(f)[0]) for f in faces}
                       | set(prop_mats.values()))
    blends = {}
    tex = extract_textures(pak, materials, os.path.join(d, "textures"), blends, notes)
    packed_sky = packed_sky_faces(bsp, pak, os.path.join(d, "textures"), notes)
    textured = {m for m, (png, _) in tex.items() if png}

    cos_limit = math.cos(math.radians(a.max_slope))
    surfaces, mesh_blob = build_mesh(bsp, place, lm_w, lm_h, textured, cos_limit,
                                     a.prototype, drawn + walls, blends, wall_material)
    prop_groups = build_props(props_drawn, prop_mats, block_of, place, lm_w, lm_h)
    prop_tint = prop_colours(bsp, [m for m in prop_groups if m not in textured])
    prop_surfaces, prop_blob = emit_prop_surfaces(prop_groups, textured, len(mesh_blob), prop_tint)
    surfaces += prop_surfaces
    mesh_blob += prop_blob
    for s in surfaces:
        png, translucent = tex.get(s["material"], (None, False))
        s["texture"] = None if s["prototype"] else png
        if "alpha_offset" in s:
            s["texture2"] = blends[s["material"]]
        s["translucent"] = translucent and not s["prototype"]
        # [b]A stock material hides behind a map-local name.[/b] A model's materials are
        # the mapper's own VMTs (`models/comp/aaramp/unbreakable`), which name the
        # source game's texture (`glass/unbreakable`) as their $basetexture. The stand-in
        # table is keyed by the stock name, so it never matched the model's, and the ramp of
        # surf_arcade's stage 1 -- glass over purple and green stripes -- was an opaque
        # black grid with the stripes buried under it. The base is recorded so the
        # stand-in lookup can try it second; only on a surface left in the grid.
        if s["prototype"]:
            pvmt = pak.get("materials/%s.vmt" % s["material"])
            pbase = vmt_basetexture(pvmt)[0] if pvmt is not None else None
            if pbase and pbase != s["material"]:
                s["base"] = pbase
        # Drawn added, not over: see vmt_additive. Only a surface that has its own texture --
        # an additive material whose picture did not ship has nothing to add, and the grid
        # in its measured colour is the honest stand-in. Written only when true, so the
        # thousands of ordinary surfaces do not each carry two falses.
        vmt = pak.get("materials/%s.vmt" % s["material"]) if s["texture"] else None
        additive, nocull = vmt_additive(vmt) if vmt is not None else (False, False)
        if additive:
            s["additive"] = True
            if nocull:
                s["two_sided"] = True

    solid_props = prop_hulls(pak, props_drawn)
    collision_blob, collision, skipped_entities, solids = build_collision(bsp, notes, solid_props)
    # The collision block lives in the same .bin, after the mesh, so a map is still the
    # four files it was. Its offsets are written relative to its own block and shifted
    # here, which keeps build_collision independent of what precedes it.
    for key in ("hull_offset", "displacement_vertex_offset", "displacement_index_offset"):
        collision[key] += len(mesh_blob)
    with open(os.path.join(d, map_id + ".bin"), "wb") as fh:
        fh.write(mesh_blob)
        fh.write(collision_blob)

    z, spawns, respawn, push, other, dropped = classify_zones(
        bsp, a.min_zone_thickness, doc, solids, floor_boxes(bsp, solids, solid_props))
    zones = emit_zones(z)
    mech = bsp_mechanics.mechanics(bsp, entity_origin, z.destinations, DESTINATION_LIFT,
                                   yaw_to_godot, z.traps)
    for s in spawns:
        s.pop("origin_src", None)
        s.pop("yaw_src", None)

    world_ids = {id(f) for f in bsp.model_faces(0)}
    lo, hi = bsp.model_bounds(0)
    manifest = {
        "id": map_id,
        "source": os.path.basename(a.bsp),
        "units": "genre units (Source units), Godot axes; x metres = x * 0.01905",
        "tier": int(doc.get("tier", a.tier)),
        "bounds": {"min": list(to_godot(lo)), "max": list(to_godot(hi))},
        "lightmap": {"file": os.path.basename(lm_path), "width": lm_w, "height": lm_h},
        "lighting": dict(lighting_of(bsp), **({"sky_faces": packed_sky} if packed_sky else {})),
        "surfaces": surfaces,
        "collision": collision,
        # Two counts from two code paths, so a suite can tell "this map has no brush
        # entities" from "this importer stopped drawing them": the solid ones come from
        # the classname list collision uses, the drawn faces from `drawn_faces`.
        # Counted from the lump, not from what was drawn, so "this map has no props" and
        # "this importer stopped drawing them" are two different numbers.
        "skybox": None if sky is None else {
            "camera": list(sky[0]), "scale": sky[1], "drawn_scale": sky_scale,
            # From the world's origin, at drawn_scale: where the nearest and the farthest
            # of the sky end up. headless_imported holds them to the camera's far plane.
            "reach_units": [round(sky_near), round(sky_far)],
            "faces": sky_faces,
            "drawn": not sky_off,
            "props": sum(1 for pr, _m in props_drawn if pr.get("skybox")),
        },
        "static_props": {
            "placed": len(all_props),
            "drawn": len(props_drawn),
            "stock_models": sum(props_stock.values()),
            # Of those, the solid ones drawn and collided as a box (tools/stock_standins.py);
            # stock_models still counts them, because the model itself was not carried.
            "stock_standins": sum(1 for pr, _m in props_drawn if pr.get("standin")),
            # ...and of those, the boxes whose size is a variant's or a written estimate
            # (the base engine's models are not on /extra): see stock_standins.hull.
            "stock_standins_estimated": sum(1 for pr, _m in props_drawn
                                            if pr.get("standin") in ("variant", "estimate")),
            "surfaces": len(prop_surfaces),
            # Prototype prop surfaces painted a brush texture's colour (by name, or by a
            # material word), and props lit by the open-sky floor light for want of a lit
            # floor under them. See `prop_colours` and `GroundLight.open_sky`.
            "tinted": sum(1 for e in prop_surfaces if e.get("prototype") and e["material"] in prop_tint),
            "open_sky_lit": props_open_sky,
        },
        "brush_entities": {
            "solid": sum(1 for e in bsp.entities
                         if e.get("model", "").startswith("*")
                         and e.get("classname") in SOLID_BRUSH_ENTITIES),
            # Counted, not subtracted: the 3D skybox takes world faces out of `drawn`
            # (surf_kitsune's, which it leaves undrawn), and a difference of two totals
            # then goes negative and says a map draws no brush entities when it does.
            "faces_drawn": sum(1 for f, _o in drawn if id(f) not in world_ids),
        },
        "units_per_square": UNITS_PER_SQUARE,
        "max_slope": a.max_slope,
        "spawn": pick_spawn(spawns),
        "spawns": spawns,
        "min_zone_thickness": a.min_zone_thickness,
        "zones": zones,
        "track_names": z.track_names,
        "respawn_volumes": respawn,
        # What the volumes DO to a player: water, pushes, gravity, hurt, conveyors,
        # ladders and the blocks that sink. See tools/bsp_mechanics.py.
        "mechanics": mech,
        "push_volumes": mech["push"],
        "trigger_volumes": other,
    }
    for key in ("display_name", "author", "kind", "notes"):
        if key in doc:
            manifest[key] = doc[key]
    # The main track's spawn is what the game puts a player at, and it is not the
    # `spawn` field once a map has a start zone somewhere else -- see spawn_zones.
    main_spawn = [x for x in zones if x["kind"] == "SPAWN" and x["track"] == 0]
    if main_spawn:
        manifest["spawn"] = {"origin": main_spawn[0]["destination"],
                             "yaw": main_spawn[0]["destination_yaw"]}
    with open(os.path.join(d, map_id + ".json"), "w") as fh:
        json.dump(manifest, fh, indent=1)

    tris = sum(s["index_count"] for s in surfaces) // 3
    from_pak = sum(s["index_count"] for s in surfaces if s["texture"]) // 3
    print("%s -> %s" % (os.path.basename(a.bsp), d))
    print("  %d surfaces, %d tris (%d%% textured from the pakfile, %d%% prototype)"
          % (len(surfaces), tris, from_pak * 100 // max(1, tris),
             (tris - from_pak) * 100 // max(1, tris)))
    by_role = collections.Counter()
    for s in surfaces:
        by_role[s["role"]] += s["index_count"] // 3
    print("  roles at %g degrees: %s" % (a.max_slope, ", ".join(
        "%s %d%%" % (r, by_role[r] * 100 // max(1, tris))
        for r in ("PLATFORM", "RAMP", "FLOOR"))))
    print("  collision: %d convex hulls (%d of them playerclip, %d from static props), "
          "%d displacement tris"
          % (collision["hull_count"], collision["playerclip_hulls"], collision["prop_hulls"],
             collision["displacement_index_count"] // 3))
    if skipped_entities:
        print("  %d brush entities left non-solid: %s"
              % (sum(skipped_entities.values()),
                 ", ".join("%s x%d" % kv for kv in skipped_entities.most_common(6))))
    print("  lightmap %dx%d, %d lit faces, %.1f%% of luxels clipped to white"
          % (lm_w, lm_h, len(place) - 1, lm_clipped))
    if sky is not None:
        print("  3D skybox: %d faces and %d props %s %gx about the sky camera at %s"
              % (sky_faces, sum(1 for pr, _m in props_drawn if pr.get("skybox")),
                 "NOT drawn (the zones file says so), would be" if sky_off else "drawn",
                 sky_scale, [round(v) for v in sky[0]]))
    print("  static props: %d placed, %d drawn (%d light probes), %d of stock models "
          "the map did not carry" % (len(all_props), len(props_drawn), len(blocks),
                                     sum(props_stock.values())))
    if props_drawn:
        print("  props: %d untextured surfaces tinted from the map's own textures (%d by name, "
              "%d by a material word), %d props lit by the open-sky floor light" % (
                  len(prop_tint), sum(1 for _c, how in prop_tint.values() if how == "name"),
                  sum(1 for _c, how in prop_tint.values() if how == "word"), props_open_sky))
    inflated = sum(1 for v in respawn if v.get("inflated"))
    hung = sum(1 for v in respawn if v.get("hung"))
    cleared = sum(1 for v in respawn if v.get("cleared"))
    print("  %d spawns, %d respawn volumes (%d thickened to %g units, %d of them hung "
          "below a floor, %d trimmed off an arrival), %d push, %d other"
          % (len(spawns), len(respawn), inflated, a.min_zone_thickness, hung, cleared,
             len(push), len(other)))
    for track in sorted({x["track"] for x in zones}):
        kinds = [x["kind"] for x in zones if x["track"] == track]
        stages = max([int(x.get("number", 0)) for x in zones
                      if x["track"] == track and x["kind"] == "STAGE"] or [0])
        print("  track %d (%-6s) %s%s%s, %d stages%s"
              % (track, z.track_names.get(str(track), "?"),
                 "start " if "START" in kinds else "NO START ",
                 "end" if "END" in kinds else "NO END",
                 "" if "SPAWN" in kinds else ", NO SPAWN", stages,
                 ", %d teleports" % kinds.count("TELEPORT") if "TELEPORT" in kinds else ""))
    for track, name in dropped:
        print("  track %d (%s) was dropped: a track needs both a start and an end"
              % (track, name))
    # Said out loud rather than kept: a note nothing prints is this family's own
    # "produced correctly and consumed by nothing", and two volumes quietly becoming
    # one is exactly the kind of thing somebody wants to be told about.
    for note in z.notes + notes:
        print("  note: %s" % note)
    print("  mechanics: %s" % ", ".join("%d %s" % (len(v), k) for k, v in mech.items()))
    print("  start spawn at %s units" % [round(v) for v in manifest["spawn"]["origin"]])

    print("  drop that directory anywhere the game looks and it is a map:")
    print("    res://maps/imported/, user://maps/, or g2g_maps_directory")
    return 0


if __name__ == "__main__":
    sys.exit(main())
