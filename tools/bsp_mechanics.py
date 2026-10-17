"""What a map's brush entities DO, as data the game can run.

`bsp_import.py` reads a map's geometry, its collision and its timer zones. This file
reads the rest of what the entity lump says about movement: where the water is, which
volumes push, which change gravity, which hurt, which floors carry you, and which blocks
sink under a player who stays on them. Each one is a list of boxes with a few numbers,
in genre units and Godot axes like everything else in the manifest, and
`game/g2g_map_mechanics.gd` is the one place that runs them.

Every brush entity Source's level editor offers is accounted for in
`docs/brush-entities.md`, with what this importer does with it and why. The short form:
the map's own logic (outputs, inputs, filters that rename the player, moving parts
driven by buttons) is not run, because this game is not a scripting engine; what a
player FEELS standing in a volume is, because a map plays wrong without it.
"""

import math
import re

from bsp_read import to_godot

CONTENTS_SLIME, CONTENTS_WATER = 0x10, 0x20
CONTENTS_LADDER = 0x20000000

# A material whose name says liquid. A brush entity has no contents of its own that
# say "water" (evolve's river is a func_illusionary whose brushes carry WINDOW), so the
# material is what is left, and a name is what the importer has for a stock material
# whose VMT never shipped in the map. Waterfalls are scenery: a curtain, not a volume.
WATER_NAME = re.compile(r"(^|[/_\\])(water|river|liquid|ocean|sea|lake|pond|swamp|sewer_?water)",
                        re.IGNORECASE)
NOT_WATER = re.compile(r"waterfall|_beneath|waterbottle|watertower", re.IGNORECASE)

# A trigger_push is a player push only with the Clients flag. Source's own flag numbers.
SF_TRIGGER_CLIENTS = 1
SF_PUSH_ONCE = 128
SF_DOOR_TOUCH_OPENS = 1024
SF_BUTTON_TOUCH_ACTIVATES = 256
SF_CONVEYOR_NO_PUSH = 1

# How far below a block's top a trigger_teleport may sit and still be the one the block
# sinks into. A block is a slab over a thin plate; a pit forty metres down is not a block.
BLOCK_REACH = 160.0
# The longest a player may stand on a block. A door moving at 1 unit/s would otherwise be
# a block nobody is ever taken off.
BLOCK_DELAY_MAX = 1.0
# And the shortest: one 128-tick step. A trigger already at the block's top is a pit.
BLOCK_DELAY_MIN = 1.0 / 128.0


def angle_vector(angles):
    """Source's AngleVectors forward for "pitch yaw roll", in Hammer axes."""
    try:
        p, y = (math.radians(float(v)) for v in angles.split()[:2])
    except (ValueError, AttributeError):
        return (1.0, 0.0, 0.0)
    return (math.cos(p) * math.cos(y), math.cos(p) * math.sin(y), -math.sin(p))


def godot_dir(v):
    g = to_godot(v)
    return [round(g[0], 5), round(g[1], 5), round(g[2], 5)]


def _int(e, key, default=0):
    try:
        return int(float(e.get(key, default)))
    except ValueError:
        return default


def _float(e, key, default=0.0):
    try:
        return float(e.get(key, default))
    except ValueError:
        return default


def godot_box(lo, hi):
    a, b = to_godot(lo), to_godot(hi)
    return ([min(a[i], b[i]) for i in range(3)], [max(a[i], b[i]) for i in range(3)])


def entity_brushes(bsp, e, origin_of):
    """(brush index, box in Hammer coordinates) per brush of a brush entity."""
    model = e.get("model", "")
    if not model.startswith("*"):
        return []
    index = int(model[1:])
    if not 0 < index < len(bsp.models):
        return []
    o = origin_of(e)
    out = []
    for i in sorted(bsp.model_brushes(index)):
        pts = bsp.brush_hull(i)
        if len(pts) < 4:
            continue
        out.append((i, ([min(p[a] for p in pts) + o[a] for a in range(3)],
                        [max(p[a] for p in pts) + o[a] for a in range(3)])))
    return out


def brush_materials(bsp, i):
    first, count, _ = bsp.brushes[i]
    out = set()
    for side in bsp.brushsides[first:first + count]:
        ti = side[1]
        if 0 <= ti < len(bsp.texinfo):
            out.add(bsp.texnames[bsp.texdata[bsp.texinfo[ti][17]][3]])
    return out


def is_water_material(name):
    return bool(WATER_NAME.search(name)) and not NOT_WATER.search(name)


# ------------------------------------------------------------------ solidity ---

def solid_for_players(e):
    """Whether a brush entity of a SOLID class is solid to a player, from its own keys.

    The class list in `bsp_read` says which classes CAN be solid; a mapper turns that off
    per entity, and each of these was an invisible wall before:

    - `func_brush` `Solidity` 1 is "never solid" (0 toggles, 2 always);
    - `func_door`/`func_door_rotating` spawnflag 8 and `func_movelinear` 8 are "passable";
    - `func_rotating` spawnflag 64 is "not solid";
    - `func_conveyor` spawnflag 2 is "not solid";
    - `func_clip_vphysics` blocks physics objects and never a player;
    - `func_water_analog` and `func_water` are water, which is swum in, not stood on.
    """
    cls = e.get("classname", "")
    flags = _int(e, "spawnflags")
    if cls in ("func_clip_vphysics", "func_water_analog", "func_water"):
        return False
    # A func_brush that STARTS disabled, or a func_wall_toggle that starts off, stays
    # solid: maps switch those on with logic at round start, often as the floor a player
    # spawns on, and this game does not run that logic (bhop_lego2, surf_fruits and three
    # more fell through their spawns when they were made non-solid). Only `Solidity 1`,
    # "never solid", is a fact about the brush.
    if cls == "func_brush" and _int(e, "Solidity") == 1:
        return False
    if cls in ("func_door", "func_door_rotating", "func_movelinear") and flags & 8:
        return False
    if cls == "func_rotating" and flags & 64:
        return False
    if cls == "func_conveyor" and flags & 2:
        return False
    return True


# ---------------------------------------------------------------------- water ---

def water_volumes(bsp, origin_of):
    """Every volume a player swims in, as boxes.

    Three sources, because a map can say "water" three ways: a world brush whose contents
    are WATER or SLIME (what vbsp gives a brush painted in a water material), a
    `func_water_analog` or `func_water` (moving water, its own entity), and any other
    brush entity painted in a water material -- evolve's section-one river is a
    `func_illusionary` in `watersource/river/river_clear`, which Source swims in and this
    game used to fall straight through.
    """
    out = []
    for i in bsp.model_brushes(0):
        if bsp.brushes[i][2] & (CONTENTS_WATER | CONTENTS_SLIME):
            pts = bsp.brush_hull(i)
            if len(pts) >= 4:
                lo = [min(p[a] for p in pts) for a in range(3)]
                hi = [max(p[a] for p in pts) for a in range(3)]
                out.append(("world", lo, hi))
    for e in bsp.entities:
        cls = e.get("classname", "")
        if not e.get("model", "").startswith("*") or cls == "worldspawn":
            continue
        if cls.startswith("trigger_"):
            continue
        whole = cls in ("func_water_analog", "func_water")
        for i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            if whole or bsp.brushes[i][2] & (CONTENTS_WATER | CONTENTS_SLIME) \
                    or any(is_water_material(m) for m in brush_materials(bsp, i)):
                out.append((cls, lo, hi))
    vols = []
    for src, lo, hi in out:
        if min(hi[a] - lo[a] for a in range(3)) < 2.0:
            continue        # a surface, not a volume: nobody swims in a sheet
        g = godot_box(lo, hi)
        vols.append({"min": g[0], "max": g[1], "from": src})
    return vols


# ---------------------------------------------------------------------- pushes ---

def push_volumes(bsp, origin_of, inert_filters):
    """Every `trigger_push` that pushes a player: a box per brush, a velocity, a flag.

    `push` is Source's own `pushdir` x `speed` in units/s, Godot axes. `once` is the
    "Once Only" flag: the push is given on entering rather than for as long as the player
    is inside. A push behind a filter no player passes, or without the Clients flag, is
    left out, because in Source it pushes nobody.
    """
    out = []
    for e in bsp.entities:
        if e.get("classname") != "trigger_push":
            continue
        flags = _int(e, "spawnflags", SF_TRIGGER_CLIENTS)
        if not flags & SF_TRIGGER_CLIENTS or _int(e, "StartDisabled") == 1:
            continue
        if e.get("filtername", "").strip().lower() in inert_filters:
            continue
        speed = _float(e, "speed", 40.0)
        d = angle_vector(e.get("pushdir", "0 0 0"))
        push = godot_dir((d[0] * speed, d[1] * speed, d[2] * speed))
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "push": push,
                        "once": bool(flags & SF_PUSH_ONCE),
                        "filtered": bool(e.get("filtername", "").strip())})
    return out


# `!activator,AddOutput,basevelocity x y z,delay,times` on a trigger: a booster.
BOOST_OUTPUT = re.compile(r"^\s*!activator\s*,\s*AddOutput\s*,\s*basevelocity\s+([-\d.eE]+)\s+([-\d.eE]+)\s+([-\d.eE]+)\s*,\s*([\d.]*)",
                          re.IGNORECASE)


def booster_volumes(bsp, origin_of, inert_filters):
    """Every trigger that boosts a player by setting their `basevelocity`, as a once push.

    The genre's booster is not a `trigger_push`: it is a thin `trigger_multiple` on a
    block's top whose OnEndTouch sets `basevelocity 0 0 550` on the player leaving it,
    which the engine turns into an impulse once (the player's PostThink adds a base
    velocity nothing is still pushing with into the velocity and clears it). So jumping off
    the pad launches; standing on it does nothing. Ten imported maps carry them (2026-10-10:
    bhop_overthinker 34, bhop_frotinity2 32, bhop_lego3 22, bhop_pandora2_fix 18,
    bhop_supernova 10, ...), and until then none was read: a launch pad was a floor.

    OnEndTouch becomes `leave` (the impulse is given on the tick the hull leaves the
    volume); OnStartTouch and OnTrigger are given on entering, as a `once` push. A filter
    name that names no filter entity passes everybody in Source (nothing to ask), so only
    the inert ones are left out; a booster behind a delay is read without it, because a
    delayed impulse would need a timer per player this mechanic does not keep, and none of
    the ten has one."""
    filters = {e.get("targetname", "").strip().lower() for e in bsp.entities
               if e.get("classname", "").startswith("filter_")}
    out = []
    for e in bsp.entities:
        if e.get("classname") not in ("trigger_multiple", "trigger_once"):
            continue
        if _int(e, "StartDisabled") == 1:
            continue
        flags = _int(e, "spawnflags", SF_TRIGGER_CLIENTS)
        if not flags & SF_TRIGGER_CLIENTS:
            continue
        name = e.get("filtername", "").strip().lower()
        if name in inert_filters:
            continue
        boost = None
        leave = False
        for key in ("OnEndTouch", "OnStartTouch", "OnTrigger"):
            for line in e.get(key, "").split("\n"):
                m = BOOST_OUTPUT.match(line)
                if m:
                    boost = (float(m.group(1)), float(m.group(2)), float(m.group(3)))
                    leave = key == "OnEndTouch"
                    break
            if boost is not None:
                break
        if boost is None or boost == (0.0, 0.0, 0.0):
            continue
        push = godot_dir(boost)
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "push": push, "once": True, "leave": leave,
                        "filtered": bool(name) and name in filters})
    return out


def gravity_volumes(bsp, origin_of):
    """`trigger_gravity`: inside it a player falls at `gravity` times the server's."""
    out = []
    for e in bsp.entities:
        if e.get("classname") != "trigger_gravity" or _int(e, "StartDisabled") == 1:
            continue
        scale = _float(e, "gravity", 1.0)
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "scale": scale})
    return out


def hurt_volumes(bsp, origin_of):
    """`trigger_hurt`: damage per second. A timer run has no health, so the game reads a
    lethal one (100 or more) as a death -- back to the spawn -- and the rest as nothing."""
    out = []
    for e in bsp.entities:
        if e.get("classname") != "trigger_hurt" or _int(e, "StartDisabled") == 1:
            continue
        if not _int(e, "spawnflags", 1) & SF_TRIGGER_CLIENTS:
            continue
        damage = _float(e, "damage", 10.0)
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "damage": damage})
    return out


def conveyors(bsp, origin_of):
    """`func_conveyor`: a floor that carries whoever stands on it, `speed` along `movedir`.

    The box is the conveyor's own brush; the game moves a grounded player whose feet are
    on its top. A conveyor flagged "no push" is a scrolling texture and nothing more.
    """
    out = []
    for e in bsp.entities:
        if e.get("classname") != "func_conveyor":
            continue
        if _int(e, "spawnflags") & SF_CONVEYOR_NO_PUSH:
            continue
        speed = _float(e, "speed", 100.0)
        d = angle_vector(e.get("movedir", e.get("angles", "0 0 0")))
        flat = (d[0] * speed, d[1] * speed, 0.0)
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "push": godot_dir(flat)})
    return out


def ladders(bsp, origin_of):
    """Ladder volumes: world brushes with CONTENTS_LADDER and `func_ladder`, climbed by
    the game's ladder mode (`game/g2g_ladder_mode.gd`)."""
    out = []
    for i in bsp.model_brushes(0):
        if bsp.brushes[i][2] & CONTENTS_LADDER:
            pts = bsp.brush_hull(i)
            if len(pts) >= 4:
                g = godot_box([min(p[a] for p in pts) for a in range(3)],
                              [max(p[a] for p in pts) for a in range(3)])
                out.append({"min": g[0], "max": g[1]})
    for e in bsp.entities:
        if e.get("classname") == "func_ladder":
            for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
                g = godot_box(lo, hi)
                out.append({"min": g[0], "max": g[1]})
    return out


# ---------------------------------------------------------------------- blocks ---

def bhop_blocks(bsp, origin_of, destinations, inert_filters):
    """The blocks that sink under a player who stays on them, and where that sends them.

    [b]A jump map's block is a door over a teleport.[/b] A `func_door` that opens on touch
    and moves DOWN, with a thin `trigger_teleport` just under its top: land and jump and
    nothing happens; stand on it and it carries you down into the plate, which sends you
    back to the start of the section. In Source the door really moves, for everybody --
    a player who lands on it a moment after somebody else lands on a block that is
    already half sunk, which servers have patched with a plugin for fifteen years.

    Here the door never moves. Each block becomes a box, a delay and a destination, and
    the game times each player on it SEPARATELY: stand on it longer than `delay` and you
    are sent where the plate under it sends you. Nobody can ruin a block for anybody
    else, because there is nothing shared to ruin.

    `delay` is the time the door would take to carry a player's feet from its top down to
    the plate's top at its own `speed`. Clamped, because a door at 1 unit/s is a block
    nobody is ever taken off and a plate at the top is a pit, not a block.
    """
    plates = []
    for e in bsp.entities:
        if e.get("classname") != "trigger_teleport" or _int(e, "StartDisabled") == 1:
            continue
        if not _int(e, "spawnflags", 1) & SF_TRIGGER_CLIENTS:
            continue
        if e.get("filtername", "").strip().lower() in inert_filters:
            continue
        hits = destinations(e.get("target", ""))
        if not hits:
            continue
        for _i, box in entity_brushes(bsp, e, origin_of):
            plates.append((box, hits[0]))

    out = []
    for e in bsp.entities:
        cls = e.get("classname", "")
        flags = _int(e, "spawnflags")
        if cls == "func_door" and flags & SF_DOOR_TOUCH_OPENS:
            pass
        elif cls == "func_button" and flags & SF_BUTTON_TOUCH_ACTIVATES:
            pass
        else:
            continue
        d = angle_vector(e.get("movedir", "0 0 0"))
        if d[2] > -0.7:
            continue        # a block sinks; one that slides or rises is something else
        speed = max(_float(e, "speed", 100.0), 1.0)
        boxes = entity_brushes(bsp, e, origin_of)
        if not boxes:
            continue
        lo = [min(b[0][a] for _i, b in boxes) for a in range(3)]
        hi = [max(b[1][a] for _i, b in boxes) for a in range(3)]
        top = hi[2]
        best = None
        for (plo, phi), dest in plates:
            if plo[0] >= hi[0] or phi[0] <= lo[0] or plo[1] >= hi[1] or phi[1] <= lo[1]:
                continue
            if phi[2] > top + 1.0 or phi[2] < top - BLOCK_REACH:
                continue
            if best is None or phi[2] > best[0]:
                best = (phi[2], dest)
        if best is None:
            continue
        delay = (top - best[0]) / speed
        if delay < BLOCK_DELAY_MIN:
            delay = BLOCK_DELAY_MIN
        delay = min(delay, BLOCK_DELAY_MAX)
        g = godot_box(lo, hi)
        at, yaw = best[1]
        out.append({"min": g[0], "max": g[1], "delay": round(delay, 4),
                    "destination_src": list(at), "yaw_src": yaw,
                    "class": cls})
    return out


# Entities a player has to press or shoot to fire. Nothing in this game presses or shoots
# a map's button (it runs none of a map's outputs), so a name only a button gives is a
# name no player here ever has.
BUTTON_CLASSES = ("func_button", "func_rot_button", "momentary_rot_button")


def assignable_names(bsp, key="targetname", buttons=True):
    """Every name (or with [param key] `classname`, every class) the map's own logic can
    give a player: `AddOutput <key> X` in any output, lower-cased. A player has no name of
    its own and is class `player`, so with that this is everything a filter can ever see
    on one.

    With [param buttons] false, a button's outputs are not read (see `BUTTON_CLASSES`):
    bhop_badges gives the name `sideboost` for 0.3 s to whoever SHOOTS one of 23 buttons,
    and a `trigger_push` behind that name at each section's start shoves the shooter
    sideways over a gap. Read as live, the push shoved everybody, and section 8's start
    (`8.8`) pushed every arrival into the pit that sends to it, for ever (headless_mechanics:
    "pit destination loops", 2026-10-11)."""
    names = set()
    rx = re.compile(key + r"[\s:]+([^,\s\x1b]+)", re.IGNORECASE)
    for e in bsp.entities:
        if not buttons and e.get("classname", "") in BUTTON_CLASSES:
            continue
        for k, v in e.items():
            if k in ("targetname", "classname", "model", "origin", "filtername", "filterclass"):
                continue
            for m in rx.finditer(str(v)):
                names.add(m.group(1).strip().lower())
    return names


def inert_filters(bsp, names_too=True):
    """Filter names that no player ever passes, as facts read off the entity lump:

    - a non-negated `filter_activator_class` naming a class that is not `player` and that
      no output ever gives anybody (bhop_lego2 renames players' CLASSES with
      `AddOutput classname`, so its class filters are live);
    - with [param names_too], a non-negated `filter_activator_name` whose name nothing in
      the map ever assigns (bhop_badges_mini's `upboost_filter`: three boosters behind a
      name no output sets, which in Source push nobody, and imported unfiltered launched a
      player who landed beside one up a shaft for ever), or only a button does (bhop_badges'
      `sideboost_filter`, see `assignable_names`). An empty name passes everybody (a player
      has none), so it is never inert.

    `bsp_import.dead_teleports` asks the class half only: a teleport behind a dead name is
    the map's own mistake as often as its intent (surf_summit's sixteen `filter_fail` pits),
    and dropping a pit somebody needs is a player falling for ever, so those stay pits."""
    dead = set()
    names = None
    classes = None
    for e in bsp.entities:
        cls = e.get("classname", "")
        if cls not in ("filter_activator_class", "filter_activator_name"):
            continue
        negated = e.get("Negated", "0").strip().lower() in ("1", "filter out entities that match criteria")
        if negated:
            continue
        if cls == "filter_activator_class":
            want = e.get("filterclass", "").strip().lower()
            if classes is None:
                classes = assignable_names(bsp, "classname")
            if want != "player" and want not in classes:
                dead.add(e.get("targetname", "").strip().lower())
        elif names_too:
            want = e.get("filtername", "").strip().lower()
            if want == "":
                continue
            if names is None:
                names = assignable_names(bsp, buttons=False)
            if want not in names:
                dead.add(e.get("targetname", "").strip().lower())
    dead.discard("")
    return dead


def trap_blocks(bsp, traps, origin_of, destinations):
    """The anti-standing traps `conditional_teleports` dropped, as per-player blocks.

    [b]The bhop maps that do not build blocks from doors build them from logic.[/b] A
    `trigger_multiple` on each block fires every hundredth of a second while somebody
    touches it and renames them -- `!activator,AddOutput,targetname activator,0.09,-1` --
    and a teleport on the block fires only for that name (bhop_badges, bhop_badges_mini,
    bhop_platformer_fxd: 0.09 s; bhop_ananas 0.6 s). Stand there that long and you are sent
    back. This game does not run the logic, so the teleport was dropped and standing cost
    nothing. It is a block now: the teleport's own brushes, the delay the map's output
    waits, and where the teleport sends you. `touch` because the box is the teleport's
    volume over the block, not the block, and it is asked of a grounded player's hull.
    A trap whose name the map never assigns with a delay is left dropped.
    """
    delay_of = {}
    # Comma or ESC between an output's fields: newer compilers write the second.
    rx = re.compile(r"targetname[\s:]+([^,\s\x1b]+)\s*[,\x1b]\s*([0-9.]+)", re.IGNORECASE)
    for e in bsp.entities:
        for k, v in e.items():
            if not k.startswith("On"):
                continue
            for m in rx.finditer(str(v)):
                name = m.group(1).strip().lower()
                try:
                    d = float(m.group(2))
                except ValueError:
                    continue
                delay_of[name] = min(delay_of.get(name, d), d)
    names = {}
    for e in bsp.entities:
        if e.get("classname", "") == "filter_activator_name":
            negated = e.get("Negated", "0").strip().lower() in ("1", "filter out entities that match criteria")
            if not negated:
                names[e.get("targetname", "").strip().lower()] = e.get("filtername", "").strip().lower()
    out = []
    for e in traps:
        name = names.get(e.get("filtername", "").strip().lower())
        # A name given at once (surf_kitsune's `TealF`, delay 0) is a gate, not a trap
        # for standing still: there is no "too long" to time.
        if not name or name not in delay_of or delay_of[name] < 0.02:
            continue
        hits = destinations(e.get("target", ""))
        if not hits:
            continue
        delay = min(max(delay_of[name], BLOCK_DELAY_MIN), BLOCK_DELAY_MAX)
        for _i, (lo, hi) in entity_brushes(bsp, e, origin_of):
            g = godot_box(lo, hi)
            out.append({"min": g[0], "max": g[1], "delay": round(delay, 4),
                        "destination_src": list(hits[0][0]), "yaw_src": hits[0][1],
                        "class": "trap", "touch": True})
    return out


def mechanics(bsp, origin_of, destinations, lift, yaw_to_godot, traps=()):
    """Everything above, as the manifest's `mechanics` block."""
    inert = inert_filters(bsp)
    blocks = []
    for b in bhop_blocks(bsp, origin_of, destinations, inert) + trap_blocks(bsp, traps, origin_of, destinations):
        at = to_godot(b.pop("destination_src"))
        b["destination"] = [at[0], at[1] + lift, at[2]]
        b["destination_yaw"] = yaw_to_godot(b.pop("yaw_src"))
        blocks.append(b)
    return {
        "water": water_volumes(bsp, origin_of),
        "push": push_volumes(bsp, origin_of, inert) + booster_volumes(bsp, origin_of, inert),
        "gravity": gravity_volumes(bsp, origin_of),
        "hurt": hurt_volumes(bsp, origin_of),
        "conveyors": conveyors(bsp, origin_of),
        "ladders": ladders(bsp, origin_of),
        "blocks": blocks,
    }
