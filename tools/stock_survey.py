#!/usr/bin/env python3
"""Which stock materials are still drawn in the prototype grid, per imported map.

Reads every manifest in the maps checkout (default ../g2gfast-maps/maps) and the
stand-in table (textures/stock/substitutes.json), matched the way
G2GStockSubstitutes.for_material matches it: lowercase name, first glob wins, a
'none' entry or a missing texture keeps the grid. Prints each map's share of
triangles drawn textured (own + stand-in), worst first, and the materials that
would move it most. Reads only this repository and the maps checkout; nothing
under /extra. [g2g-maps-stock-1]

    tools/stock_survey.py [--maps DIR] [--top N] [--map ID ...]
"""
import argparse
import collections
import fnmatch
import json
import pathlib

HERE = pathlib.Path(__file__).resolve().parent.parent


def godot_match(name, pattern):
    # String.match knows only * and ?; fnmatch would also read [ ] as a class.
    return fnmatch.fnmatchcase(name, pattern.replace("[", "[[]"))


def classify(entries, material):
    name = material.lower()
    for entry in entries:
        if godot_match(name, str(entry.get("match", ""))):
            if entry.get("none"):
                return "none", entry["match"]
            if entry.get("treatment") == "glass":
                # G2GStockSubstitutes.is_glass: drawn see-through, no texture needed.
                return "stand-in", entry["match"]
            if "texture" not in entry:
                return "none", entry["match"]
            return "stand-in", entry["match"]
    return "unmatched", None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--maps", default=str(HERE.parent / "g2gfast-maps" / "maps"))
    ap.add_argument("--top", type=int, default=6)
    ap.add_argument("--map", nargs="*")
    ap.add_argument("--unmatched", action="store_true",
                    help="rank unmatched materials across every map instead")
    args = ap.parse_args()
    entries = json.loads((HERE / "textures/stock/substitutes.json").read_text())["entries"]
    rows = []
    for manifest in sorted(pathlib.Path(args.maps).glob("*/*.json")):
        if manifest.stem != manifest.parent.name:
            continue
        if args.map and manifest.stem not in args.map:
            continue
        doc = json.loads(manifest.read_text())
        total = drawn = 0
        grid = collections.Counter()
        why = {}
        for s in doc.get("surfaces", []):
            tris = int(s.get("index_count", 0)) // 3
            total += tris
            if s.get("texture"):
                drawn += tris
                continue
            material = str(s.get("material", ""))
            last = material.lower().rsplit("/", 1)[-1]
            if ("water" in last or "vatten" in last or last.startswith("oceansurface")) and "waterfall" not in last:
                # G2GBspMap.is_water_material: drawn by the water shader, not the grid.
                drawn += tris
                continue
            kind, rule = classify(entries, material)
            if kind == "stand-in":
                drawn += tris
            else:
                grid[s.get("material", "")] += tris
                why[s.get("material", "")] = kind if kind == "unmatched" else "none: " + rule
        if total:
            rows.append((drawn / total, manifest.stem, total, grid, why))
    if args.unmatched:
        overall = collections.Counter()
        where = collections.defaultdict(list)
        for share, map_id, total, grid, why in rows:
            for material, tris in grid.items():
                if why[material] == "unmatched":
                    overall[material] += tris
                    where[material].append("%s %.0f%%" % (map_id, tris * 100 / total))
        for material, tris in overall.most_common(args.top):
            print("%7d  %-50s %s" % (tris, material, ", ".join(where[material])))
        return
    for share, map_id, total, grid, why in sorted(rows):
        print("%5.1f%%  %s  (%d tris)" % (share * 100, map_id, total))
        for material, tris in grid.most_common(args.top):
            print("          %5.1f%%  %-48s %s" % (tris * 100 / total, material, why[material]))


if __name__ == "__main__":
    main()
