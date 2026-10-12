# Brush entities, and what an imported map does with each

Every brush entity the genre's level editor offers, and what `tools/bsp_import.py` and `tools/bsp_mechanics.py` make of it. The rule behind every row: **what a player feels standing in a volume is run, and the map's own logic is not.** This game is not a scripting engine, so an output that renames a player, a button that opens a door, a relay that enables a trigger are not executed. A teleport, a push, water, a ladder and a block that sinks under you are what a jump or surf map *is*, and a map plays wrong without them.

"Counted" below means the class is read and left out on purpose, and the manifest's numbers or the import log say how many there were. A class that is in no list is left non-solid and printed at import, because an invisible wall nobody can explain is worse than a note.

Counts are over the 42 maps in `../inspirations/g2gfast/` on 2026-10-08.

## Triggers

| Class | Maps | What happens here |
| --- | --- | --- |
| `trigger_teleport` | 41 | A zone. Named ones (`zone_start`, `end`, `stage3`...) are the timer's lines (`zone_role`); the rest are pits or gates. **A pit sends the player to the teleport's own `info_teleport_destination` and the run goes on**, as in the original engine (since 2026-10-08; before, every pit was a restart from the spawn). A teleport without the Clients flag, or behind a class filter no player passes, is dropped. One behind a name filter is kept unless the map's zones file lists the filter under `conditional_teleports`. A pit whose destination is inside a pit falls back to the spawn. |
| `trigger_multiple`, `trigger_once` | 32 | Read for their names (the timer's start, finish and stages are often these). Their outputs are not run, with one exception: a map's **anti-standing trap** (a trigger that renames whoever touches a block after a delay, and a teleport on the block that fires only for that name) becomes a per-player block with that delay, on six bhop maps. |
| `trigger_push` | 27 | **Run**: base velocity while inside, added to the player's own on leaving, so a booster sends you on at its speed. "Once only" pushes once on entering; an upward push lifts a player off the floor. A push without the Clients flag, or behind a filter no player can pass (a class filter naming no player class, or a name filter whose name nothing in the map assigns but a button), is left out. `G2GMapMechanics`. |
| `trigger_gravity` | 3 | **Run**: the fall inside is scaled by its `gravity`. |
| `trigger_hurt` | 7 | **Run** when lethal (100 damage or more): a death, which is a respawn at the start and the end of the run. Less is ignored, because a timer run has no health. |
| `trigger_wind`, `trigger_playermovement`, `trigger_look`, `trigger_proximity`, `trigger_impact`, `trigger_vphysics_motion` | 1 | Counted. `trigger_look` is logic (a map that punishes facing forward is a different map). |
| `trigger_soundscape` | 4 | Counted. No ambience. |
| `trigger_changelevel`, `trigger_transition`, `trigger_autosave`, `trigger_togglesave`, `trigger_remove`, `trigger_serverragdoll`, `trigger_waterydeath`, `trigger_rpgfire`, `trigger_physics_trap`, `trigger_teleport_relative`, `trigger_apply_impulse` | 0 | Not in any map here; left non-solid and printed if one arrives. |

## Solid brush entities

| Class | Maps | What happens here |
| --- | --- | --- |
| `func_detail` | all | Compiled into the world by the map compiler; solid like any world brush. |
| `func_wall` | 4 | Solid, drawn. |
| `func_brush` | 19 | Solid and drawn, unless `Solidity` is 1 (never solid) or it starts disabled. |
| `func_wall_toggle` | 1 | Solid and drawn unless it starts off (spawnflag 1). |
| `func_door`, `func_door_rotating` | 13, 7 | Solid and drawn where they rest; they do not move. **A door that opens on touch and moves down, with a teleport plate under it, is a block**: a player who stays on it longer than the door would take to carry them into the plate (its `speed` against the gap, 1/128 s to 1 s) is sent where the plate sends people, the run kept. **Per player**: the door never moves, so nobody can sink a block for the player landing behind them. "Passable" (spawnflag 8) is not solid. |
| `func_button`, `func_rot_button` | 23, 2 | Solid and drawn; a touch-activated one that moves down over a plate is a block, as above. Pressing does nothing (logic). |
| `func_movelinear`, `func_tracktrain`, `func_train`, `func_tanktrain`, `func_plat`, `func_platrot` | 5, 7, 0, 1, 0, 0 | Solid and drawn where they are compiled; they do not move. "Not solid" flags are honoured. |
| `func_rotating` | 12 | Solid and drawn, still; spawnflag 64 (not solid) is honoured. |
| `func_conveyor` | 5 | Solid and drawn; **run**: a player standing on its top is carried along `movedir` at `speed`. "No push" ones are scenery; spawnflag 2 is not solid. |
| `func_breakable`, `func_breakable_surf` | 11, 1 | Solid and drawn; they do not break. |
| `func_physbox`, `func_physbox_multiplayer`, `func_pushable` | 3, 3, 0 | Solid and drawn where they rest; not simulated. |
| `func_monitor`, `func_reflective_glass`, `func_lod` | 3, 1, 0 | Solid and drawn, as plain surfaces. |
| `func_clip_vphysics` | 0 | **Not solid**: it blocks physics objects and never a player. It used to be imported solid. |

## Non-solid brush entities

| Class | Maps | What happens here |
| --- | --- | --- |
| `func_illusionary` | 31 | Drawn, never solid. **One painted in a water material is water** (bhop_evolve's section-one river): swum in. |
| `func_water_analog`, `func_water` | 8, 2 | **Water**, swum in; not solid (they were imported solid). They do not move. |
| world brushes with WATER or SLIME contents | 27 | **Water**. |
| `func_ladder` and world brushes with LADDER contents | 22 | **Climbed** (`game/g2g_ladder_mode.gd`): touch it while off the ground or walking into it, forward climbs toward the view, strafe slides across, jump pushes off. 200 units/s. |
| `func_areaportal`, `func_areaportalwindow`, `func_occluder`, `func_viscluster` | 16, 4, 1, 0 | Visibility hints. Ignored. |
| `func_dustmotes`, `func_dustcloud`, `func_smokevolume`, `func_precipitation`, `func_fish_pool` | 13, 4, 2, 3, 1 | Particle volumes. Ignored. |
| `func_buyzone`, `func_bomb_target`, `func_hostage_rescue` | 6, 3, 0 | Objective volumes of the round-based shooters. Ignored; their presence is one of the signs a surf map is a combat map (`"kind": "arena"`). |
| `func_nav_blocker`, `func_vehicleclip` | 0 | Ignored. |

## What is still not run

- **Moving brushes**: doors, trains, rotators and platforms stay where they were compiled. A block sinks per player (above); nothing else moves.
- **Logic**: outputs, inputs, relays, counters, filters that rename a player. A teleport or push that depends on a name the map gives a player at run time is either dropped (`conditional_teleports`, a filter nobody can pass) or applied to everybody.
- **The engine's per-tick trigger edge cases**: a trigger thinner than 2 units under a landing, and a teleport passed through in the same tick a wall is hit. Pits are thickened at import for the first (`MIN_ZONE_THICKNESS`); the second is open.

Checked by `examples/headless_mechanics.tscn`, over every imported map: pits land a player without a loop, a pit keeps the run, a block takes off a player who stays and not one who hops, a push pushes, and holding jump in water rises.
