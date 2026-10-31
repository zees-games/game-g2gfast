#!/usr/bin/env python3
"""Deterministic check of bsp_import.cap_pits_under_blocks on synthetic data (no .bsp)."""
import copy
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import bsp_import as bi  # noqa: E402

failed = 0
checks = 0


def check(cond, what):
    global failed, checks
    checks += 1
    if not cond:
        failed += 1
        print("FAIL", what)


def zone(kind, lo, hi):
    return {"kind": kind, "min": list(lo), "max": list(hi)}


# Godot axes (y up). The block spans x 0..10, z -20..0 and its Hammer solid tops out at y 100.
block = {"min": [0.0, 0.0, -20.0], "max": [10.0, 100.0, 0.0]}
solids = [((0.0, 0.0, 90.0), (10.0, 20.0, 100.0))]

over = zone("RESPAWN", (0, 50, -20), (10, 102, 0))
apart = zone("RESPAWN", (50, 50, -20), (60, 102, 0))
sheet = zone("RESPAWN", (0, 50, -20), (10, 100 + bi.PLAYER_HEIGHT, 0))
other = zone("START", (0, 50, -20), (10, 102, 0))
zones = [over, apart, sheet, other]
before = copy.deepcopy(zones)

n = bi.cap_pits_under_blocks(zones, [block], solids)
check(n == 1, "exactly one slab capped, got %d" % n)
check(over["max"][1] == 97.0, "overlapping slab capped 3 below the top, got %s" % over["max"][1])
check(over["min"] == before[0]["min"], "capped slab keeps its floor")
check(zones[1] == before[1], "non-overlapping slab untouched")
check(zones[2] == before[2], "a sheet a player's height above the top is left alone")
check(zones[3] == before[3], "a zone that is not RESPAWN is untouched")

# A slab thinner than one tick keeps TICK_DEPTH by moving its floor down.
thin = zone("RESPAWN", (0, 67, -20), (10, 98, 0))
bi.cap_pits_under_blocks([thin], [block], solids)
check(thin["max"][1] == 97.0 and thin["max"][1] - thin["min"][1] >= bi.TICK_DEPTH, "thin slab keeps one tick of depth")

again = copy.deepcopy(zones)
n2 = bi.cap_pits_under_blocks(zones, [block], solids)
check(n2 == 0 and zones == again, "second run changes nothing")

print("%d checks, %d failed" % (checks, failed))
sys.exit(1 if failed else 0)
