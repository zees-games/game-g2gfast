# The hand-built maps

Three maps are scenes and scripts in this repository: `bhop_g2g_intro`, `bhop_g2g_stages` and `surf_g2g_intro`. Everything else is imported (see [imported-maps.md](imported-maps.md)) and delivered (see [map-delivery.md](map-delivery.md)). The routes on these three, and what a jump reaches, are in [routes.md](routes.md).

## The default map is an imported one

`G2GConfig.initial_map` is `surf_mesa`. A straight line of blocks over a flat plane is what a *suite* should run, and every example still names one explicitly, but it is not what a player arriving at a server should be met by. It also makes the imported half the default path rather than the one nothing reaches unless somebody types a map name: a built-in map is a scene and a script and can never fail to be there, and an imported map is data at a path that has to be found, parsed and built.

## Geometry and zones come from one description

Each map builds its geometry and its zones from the same list, so a start line cannot drift from the block it sits on. On a map that *turns* that is not a nicety: a hand-placed stage line on a course whose gaps somebody later changes is a leaderboard nobody can compare, and nothing reports it; the run still finishes, the splits are just taken somewhere else.

- `bhop_g2g_stages._course()` walks a position and a heading and returns every block. `_pad_centre()` answers "where is the finish" for the geometry and the zone alike. Before it, the pad was drawn along world -Z and the zone placed along the course heading (which the stage-2 turn leaves at 90°), 543 units apart, and nobody could finish the map; nothing errored, because a run that has not finished is a legitimate thing for a run to be.
- Each bonus route has its own one list (`RIDGE_SECTIONS`, `WEAVE_SECTIONS`, `bend_blocks()`, `HAIRPIN_LEGS`, `STUTTER_BLOCKS`), read by the geometry, the zones and the suite's bot.
- **Run `godot --headless --path . --script tools/export_zones.gd` after changing a map.** It writes `maps/<id>.zones.json`, the copy a delivered map would ship, and `headless_run._test_zone_files_match` checks every hand-written map against it. Both discover the maps rather than carrying a list, and the export fails on `DotTimerZoneSet.route_problems()`.

## Every route has a start, a finish, a spawn and a pit of its own

A `DotTimerZone` carries a track, and a RESPAWN zone on track 0 catches nobody running track 1. A bonus without its own pit lets a player who misses a platform fall out of the world for ever, with nothing in the log. dot-timer's `DotTimerZoneSet.route_problems()` asks every route for all four; `_test_zone_files_match` asks it of every hand-written map and `headless_imported` of every imported one. The same gap was found three times by guards pointed at one map and not the others; the rule is that the question is asked of every map the catalogue finds.

**A zone must hang over something.** `headless_run` drops a ray down the middle of every START, END and STAGE volume and requires it to land inside that volume. A zone over nothing is a zone the run never reaches, indistinguishable in-game from a map with no end zone.

## The stages map is a map rather than a fixture

The intro maps prove the movement: a straight line of blocks and a pair of ramps. `bhop_g2g_stages` is the timer community's staged shape, one idea per section so a player who fails knows which idea they failed:

```
1  straight    blocks in a line, gaps growing.      Keep the speed.
2  the turn    the course bends 90 degrees.         Strafe through it.
3  the climb   blocks rising 24 units each.         Height costs speed.
4  the drop    a descent onto narrow blocks.        Do not overshoot.
5  the zigzag  blocks alternating left and right.   Both directions.
```

Its first bonus is a **surf** descent on a bhop map, deliberately: a bonus track is a whole second route with its own records, and making it the same thing as the main route wastes it; it is also the cheapest proof that a track is a route and not a game mode.

## Surfaces are roles, not colours

`G2GGeometry.box` takes a role, and `G2GTextures` supplies a triplanar pattern in **world** space, one square per 64 units (the grid this genre's maps are built on), on every surface whatever its size. A flat tone is not cosmetic here: a surf ramp is ridden at 30 m/s and a bhop block cleared in eight ticks, and the only cue for how fast a surface is going past is a repeating pattern of known size. The old `COLOUR_*` constants are role ids now and kept their names, so no map file changed.

The hand-built maps draw the generated grid, not the installed Kenney prototype set. That kit's *Light* set is too low-contrast at this tiling (a near-flat saturated panel whose lines are gone by mid-distance, under six brand colours rather than a palette), and on a sunlit `StandardMaterial3D` over a large plane that is a floor with no readable scale. The imported maps are a different pipeline and do use the kit (see [map-rendering.md](map-rendering.md#textures-the-bsp-did-not-carry)). What would be better for the hand-built half is a light, high-contrast set whose line weight survives the tiling; the generated grid is the specification for it.

## Every hand-built map is surveyed

`G2GMapSurvey` (game-playground's survey reimplemented in genre units) runs over every hand-built map in `headless_maps`' last section, after a built-in bad map that has one of everything it looks for. Per map it asserts: every spawn and `!s<n>` destination lands on standable ground; no two solids leave a slot narrower than the hull; nothing standable is out of reach of every start unless declared, and no declaration covers ground that is reached; nothing a start reaches is a trap (no finish, pit or spawn out); every declared CHAIN course is a way forward; and the tilted slabs a player can stand on are exactly `STANDABLE_RAMPS`.

- The numbers are the tunables' own (see [movement.md](movement.md#numbers-that-explain-the-hull)); the grid is 16 u, half the hull, so a cell's eight neighbours are the hull.
- **A CHAIN course is linked body to body when `G2GReach.chain` says a perfect strafe runs it**, because the main routes' gaps (up to 288 u) are past any RUN jump by design.
- **On a surf map the survey stops short, on purpose.** A ramp is slid on, not stood on, and where a rider gets to is decided by speed that is theirs to make; any bound on it is "everywhere" or a guess at skill. The survey floods only what needs none (walking, a step, a drop, a RUN jump, a slide straight down a face's fall line) and a surface reached by a carried flight is declared, naming the check that rides it.
- The declarations live in `headless_maps._survey_declared`, not on the maps as game-playground has them. Moving them is not yet done.

## Stage destinations are on the route

A stage destination is checked by dropping a player from it, not by reading it. `surf_g2g_intro`'s fall line `!s1` and `!s2` were once placed 128 u uphill of the stage line, under the chute's surface, and dropped players into the pit. Destinations are `fall_point(t - 128 / FALL_RUN)` plus 64 now, and a stage restart's yaw faces the way the route **leaves** the stage (`yaw_facing`), never back up the course (`[stage-yaw-1]`).
