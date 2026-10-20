#!/usr/bin/env python3
"""List teleport destinations that sit beside a door only a map's own logic opens.

    tools/teleport_traps.py [--near 400] [--all] <map.bsp>...
    tools/teleport_traps.py ../inspirations/g2gfast/*.bsp      # the survey of every source map

[b]This importer runs no outputs[/b], so a `func_door` that only a button (or any other entity's
output) opens stays shut for good. Behind one of those is a trap if a `trigger_teleport` sends
players there: surf_ski_2's catch-all floor teleport aimed at a roofed jail whose only exit was
`jdoor`, and every faller was stuck. A zones file's `"open_doors"` takes such a door out of the
import; this tool says which maps need to be looked at before that is known from play.

A destination is listed when a `func_door*` is within `--near` units of it (the door's box grown
by that much; default 400) AND the door is driven by an output (some entity's `On...` output
names it) or is use-only (spawnflag 256) or starts locked. That is a candidate, not a verdict: a
door nearby is not proof the destination is walled in. The proof is `headless_imported`'s fall-out
check in game-arena, which walks a faller out. A door a zones file already lists under
`open_doors` is marked, not hidden, so a re-run shows what was handled.

Exit status 1 when any unhandled candidate is listed, so a script can gate on it.
"""

import argparse
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from bsp_import import brush_box, entity_origin  # noqa: E402
from bsp_read import Bsp  # noqa: E402

USE_ONLY = 256


def output_targets(entities):
    """{lowercase targetname: [(source classname, source targetname, output)]} for every output."""
    out = {}
    for e in entities:
        for key, val in e.items():
            if not key.startswith("On") and not key.lower().startswith("on"):
                continue
            parts = str(val).replace("\x1b", ",").split(",")
            if len(parts) >= 2 and parts[0].strip():
                out.setdefault(parts[0].strip().lower(), []).append(
                    (e.get("classname", ""), e.get("targetname", ""), key + " " + parts[1]))
    return out


def far(box, p, near):
    """Distance from point p to a box (0 inside), the box already in world coordinates."""
    d = 0.0
    for i in range(3):
        lo, hi = box[0][i], box[1][i]
        d += max(lo - p[i], 0.0, p[i] - hi) ** 2
    return d ** 0.5


def survey(path, near, handled):
    bsp = Bsp(path).load()
    ents = bsp.entities
    by_name = {}
    for e in ents:
        n = e.get("targetname", "").strip().lower()
        if n and not e.get("classname", "").startswith("trigger_"):
            by_name.setdefault(n, []).append(e)
    outs = output_targets(ents)
    doors = []
    for e in ents:
        if not e.get("classname", "").startswith(("func_door",)):
            continue
        box = brush_box(bsp, e)
        if not box:
            continue
        name = e.get("targetname", "").strip().lower()
        flags = int(e.get("spawnflags", "0") or 0)
        why = []
        drivers = outs.get(name, [])
        if name and drivers:
            why.append("driven by " + ", ".join(sorted({"%s %s" % (c, t or "?") for c, t, _ in drivers})[:3]))
        if flags & USE_ONLY:
            why.append("use-only")
        if e.get("loopmovetype") == "1" or e.get("locked_sound") and flags & 2048:
            why.append("locked")
        if why:
            doors.append((e, box, name, why))
    seen = set()
    rows = []
    for t in ents:
        if t.get("classname") != "trigger_teleport" or not t.get("target"):
            continue
        key = t["target"].strip().lower()
        if key in seen:
            continue
        seen.add(key)
        for d in by_name.get(key, []):
            p = entity_origin(d)
            for door, box, name, why in doors:
                dist = far(box, p, near)
                if dist <= near and (t["target"], name) not in {(r[0], r[2]) for r in rows}:
                    rows.append((t["target"], p, name or "(unnamed)", dist, why, name in handled))
    return rows


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("bsp", nargs="+")
    ap.add_argument("--near", type=float, default=400.0)
    ap.add_argument("--zones-dir", default=os.path.join(HERE, "..", "maps", "zones"))
    a = ap.parse_args(argv)
    bad = 0
    for path in a.bsp:
        mid = os.path.splitext(os.path.basename(path))[0]
        handled = set()
        zf = os.path.join(a.zones_dir, mid + ".json")
        if os.path.isfile(zf):
            handled = {str(s["name"]).strip().lower() for s in json.load(open(zf)).get("open_doors", [])}
        try:
            rows = survey(path, a.near, handled)
        except Exception as ex:  # one unreadable map must not hide the rest
            print("%s: unreadable (%s)" % (mid, ex))
            continue
        for target, p, door, dist, why, done in rows:
            bad += 0 if done else 1
            print("%s: destination %s at (%.0f %.0f %.0f), door %s %.0f u away: %s%s" % (
                mid, target, p[0], p[1], p[2], door, dist, "; ".join(why), "  [open_doors]" if done else ""))
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
