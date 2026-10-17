#!/usr/bin/env python3
"""Count the stock models imported maps place but cannot draw (step 5 of the stock-texture work).

    tools/stock_props_survey.py [bsp-dir]        # default ../../inspirations/g2gfast

A stock model is one the map's pakfile did not carry. The importer counts it and draws
nothing (docs/imported-maps.md, Static props). This ranks them by placements, says how many
maps use each and how many placements are solid (a solid one that is not drawn or collided
is a gap a route can fall through; a decorative one is only a missing look), and prints the
class each belongs to by name rule. Reads only the maps; nothing from the private reference.
"""
import collections, fnmatch, os, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsp_import, bsp_props, stock_standins  # noqa: E402

# name rule -> (class, decision). First match wins; the decision is what to do, with why.
RULES = [
    ("*light*", "light fixture", "none: a lamp is not a surface anyone stands on or reads a route from"),
    ("*lamp*", "light fixture", "none: as for lights"),
    ("*fluorescent*", "light fixture", "none: as for lights"),
    ("*florescent*", "light fixture", "none: as for lights"),
    ("*bramble*", "foliage", "none: as trees"),
    ("*cattail*", "foliage", "none: as trees"),
    ("*fern*", "foliage", "none: as trees"),
    ("*ivy*", "foliage", "none: as trees"),
    ("*shrub*", "foliage", "none: as trees"),
    ("*grass*", "foliage", "none: as trees"),
    ("*tree*", "foliage", "none: Kenney Nature Kit has trees; place only where the map's look depends on it"),
    ("*bush*", "foliage", "none: as trees"),
    ("*plant*", "foliage", "none: as trees"),
    ("*crate*", "box", "Kenney box stand-in only if solid and on a route"),
    ("*barrel*", "box", "Kenney barrel stand-in only if solid and on a route"),
    ("*weapon*", "decor", "none: no stand-in wanted"),
    ("*fence*", "wall", "Kenney fence if solid and on a route"),
    ("*wall*", "wall", "check solid share first"),
]

def classify(name):
    """(class, decision). Lights and foliage are `none` first; then a model with a written
    stand-in (tools/stock_standins.py) says so; then the name rules above."""
    base = name.rsplit("/", 1)[-1]
    for pat, cls, decision in RULES:
        if cls in ("light fixture", "foliage") and fnmatch.fnmatch(base, pat):
            return cls, decision
    mat = stock_standins.material_for(name)
    if mat:
        return "solid mass", "box stand-in %s, sized from the archive's hull (none where the archive lacks the model)" % mat
    for pat, cls, decision in RULES:
        if fnmatch.fnmatch(base, pat):
            return cls, "none: " + stock_standins_why(base)
    return "other", "none: not a faithful box (hollow, thin, small or climbed); see stock_standins.RULES"


def stock_standins_why(base):
    name = base[:-4] if base.endswith(".mdl") else base
    for pat, mat, why in stock_standins.RULES:
        if mat is None and fnmatch.fnmatch(name, pat):
            return why
    return "decor"


def main():
    here = os.path.dirname(os.path.abspath(__file__))
    src = sys.argv[1] if len(sys.argv) > 1 else os.path.join(here, "..", "..", "inspirations", "g2gfast")
    count, solid = collections.Counter(), collections.Counter()
    maps = collections.defaultdict(set)
    for f in sorted(os.listdir(src)):
        if not f.endswith(".bsp"):
            continue
        try:
            bsp = bsp_import.Bsp(os.path.join(src, f)).load()
            pak = bsp_import.read_pak(bsp, [])
            props = bsp_props.static_props(bsp)
        except Exception as e:  # a map that will not read is reported, not fatal
            print("skip %s: %s" % (f, e), file=sys.stderr)
            continue
        for pr in props:
            m = pr["model"]
            if m and ("%s" % m) not in pak:
                count[m] += 1
                maps[m].add(f[:-4])
                if pr["solid"]:
                    solid[m] += 1
    print("%d stock models, %d placements, %d solid" % (len(count), sum(count.values()), sum(solid.values())))
    print("%6s %6s %5s  %-52s %s" % ("placed", "solid", "maps", "model", "class: decision"))
    for m, n in count.most_common():
        cls, dec = classify(m)
        print("%6d %6d %5d  %-52s %s: %s" % (n, solid[m], len(maps[m]), m, cls, dec))

if __name__ == "__main__":
    main()
