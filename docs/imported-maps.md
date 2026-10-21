# Imported maps: the importer

`tools/bsp_import.py` turns a compiled `.bsp` from the genre's maps into a map this game loads: geometry, the textures the file carried, the lighting its compiler baked, its start line, finish, stages, bonus tracks, pits, static props and what its brush entities do. An imported map is **content**: it is read, not rebuilt. How it is drawn is in [map-rendering.md](map-rendering.md), how it reaches a server and a client in [map-delivery.md](map-delivery.md), and every brush entity class and its handling in [brush-entities.md](brush-entities.md). The zones-file format is `maps/zones/README.md`.

```bash
cp somewhere/surf_whatever.bsp ../inspirations/g2gfast/
tools/import_maps.sh            # imports what is new or whose zones file is newer, skips what is current
tools/import_maps.sh --prune    # and deletes imports whose .bsp is gone
tools/bsp_preview.sh            # renders every one of them from its spawn (xvfb-run)
```

If the import prints `NO START` or `NO END` for the main track, the map labels neither and needs a `maps/zones/<id>.json`. It is still offered, but nothing will time a run on it.

`tools/bsp_read.py` reads the file through dot-map's shared reader (`dot-map/tools/bsp`, cloned beside this repository or at `$DOTBSP_PATH`; a reader fix there reaches every converting game), including **LZMA-compressed lumps**, which map hosts' repack step produces while leaving the version at 20 and nothing in the header saying so; `tools/vtf.py` decodes textures (VTF mips are stored **smallest-first**: mip 0 is at the end), `tools/bsp_props.py` reads static props and `tools/bsp_mechanics.py` brush-entity behaviour.

## Scale and axes

**The scale is not converted, because there is nothing to convert.** These maps store coordinates at 0.75 inch per unit and `G2GUnits` declares exactly that ratio, so a `.bsp` coordinate *is* a genre unit. The whole transform is the axis swap, Z-up to Y-up:

    godot = (src.x, src.z, -src.y)

**A yaw crosses the boundary too: it is `yaw - 90`.** The file measures yaw about +Z from +X and `DotFpsMotor` builds forward as `(-sin y, 0, -cos y)`. No number is wrong when this is wrong: the player stands in exactly the right place facing the wrong way.

**A brush model's bounds are relative to the entity's `origin` key.** The compiler moves a brush entity's geometry so its origin sits at (0,0,0) and records where that was; only worldspawn is the same either way. Ignoring it piled every pit volume round the middle of the map, where nobody goes.

## Zones are read, not guessed

Many maps built for a timer carry `zone_start`, `map_end_zone`, `startzone_s4`, `tm_bonus2_endzone`, `tm_checkpoint1`, `stage_startzone_NN` and `mod_`-prefixed labels in the entity lump in plain text. **Reading a label the mapper wrote is not guessing, and throwing it away costs a map its timer.** `zone_role()` is the whole rule; `assign_tracks()` turns `bonus2`, `koga` and `b_` into track numbers. **Two brushes sharing a targetname are one entity**, and mappers use that (a checkpoint in each of two mirrored lanes); they are unioned back into one volume.

For maps that label nothing, and the halves labelled maps are missing, there is **`maps/zones/<id>.json`**: one file per map, checked in, saying which volume is the finish and *why*, in terms of what is in the `.bsp` (a named entity, the teleport aimed somewhere, a box grown round a destination, the nearest trigger to a point) rather than in typed coordinates. **Anything that fails to resolve stops the import**, because a finish that quietly resolved to nothing is a map nobody can finish. The directory sits beside the repository rather than the import because `tools/import_maps.sh --force` rewrites every manifest. A zones file also carries a required `attribution` (author, source, archive, date): these maps are other people's work, and the import refuses a map without one.

What a zones file can say, each opt-in and each with its reason in the file (format in `maps/zones/README.md`):

| Key | Why it is opt-in |
| --- | --- |
| `doorways` | Separates door-sized teleports (sections joined by doors become `Kind.TELEPORT`, which keeps the run) from room-sized pits by measurement. Only true of a map whose sections are joined by doors. |
| `conditional_teleports` | Drops teleports behind a **named** filter. The bhop anti-standing trap renames the toucher after a delay and teleports only that name, which is a trap (run as a sinking block instead, see below); the same mechanism with a name that **stays** set is a checkpoint pit and must stay. Which one a map has is in its entity lump, so the file says which it saw. |
| `round_teleports` | Drops start-disabled teleports by name. A round this game does not run (a race end, a jail) enables them; without the outputs each was a pit over every section. Opt-in because older maps were zoned against the old behaviour. |
| `ignore_labels` | Leaves a labelled trigger unread, with a required `why`. |
| `remove` | Cuts world brushes inside a box out of geometry and collision (a sealed void where the hand-placed spawn was). |
| `"restart": false` | A stage with nowhere to stand is a split only (see [timer.md](timer.md#stages-restarts-and-r)). |
| `"skybox": false`, `sky_walls` | Leaves out a 3D skybox, or draws sky faces as walls (see [map-rendering.md](map-rendering.md#skies)). |
| `"kind": "arena"` | A combat map, not a course; out of rotation unless named. The importer writes it to `../arena-surf-dm-maps/maps`, not `maps/imported`. |

A teleport behind a class filter naming a class no player is never fires in the original engine either, and is dropped automatically. Teleports without the Clients flag are dropped for the same reason.

**A track with a start and no end is dropped, and said so.** Left in, it is a track a player can begin and never complete, and `DotTimerZoneSet.problems()` refuses the whole map over it.

**The entity parser keeps every repeat of an `On*` key**, joined with newlines. A trigger that does two things on touch has two `OnTrigger` keys; keeping only the first lost the delay a trap needs.

## Pits

Every `trigger_teleport` left after the zones have claimed theirs is a pit (`DotTimerZone.Kind.RESPAWN`), and **a pit sends the player to its own destination with the run kept** (`G2GBspMap.SENDS_TO` in the payload), as the original engine does. Before, every pit restarted the run, which on a staged map is "fell in section five, back to section one".

- **A destination resolves to any entity with that name**: `info_teleport_destination`, `info_target`, `info_landmark`, and finally a brush entity's origin.
- **A destination inside another pit is followed, not dropped**: it is usually a speed-stopping hub, so the pit sends to where the chain ends, and only a real cycle falls back to the spawn.
- **A leftover teleport goes to the track whose START its destination is in** (`pit_tracks`), since a fail teleport sends a player back to the start of the route they fell off. Without it every bonus had no pit.
- **A thin pit is thickened.** The original engine *sweeps* its trigger tests; `DotTimerZoneIndex` asks `contains(point)` once a tick, and at 3500 u/s and 128 Hz a player moves 27 units between samples, so a 16-unit trigger plane is stepped over. A thin volume becomes a slab centred on the plane (`MIN_ZONE_THICKNESS`), except that **`inflate_pit` hangs it from the plane when the upper half has a solid top in it**, because a bhop map draws its pit a block's height under the blocks and a centred slab reached up through them.
- **`clear_arrivals` trims a grown slab back off any spawn, stage or door arrival** it would contain, and leaves it at least `TICK_DEPTH` (32) deep on the far side, never over another arrival.
- **A pit is one zone per brush**, and **`hull_boxes` cuts any brush that is not its own box into slabs** whose vertical extent is solved from the brush's planes at their corners (a convex brush holds a box exactly when it holds its corners). A zone is a box; the box round an L covers the elbow, and the box round a sloped sheet reached over a whole ramp and sent riders back mid-ride. Slabs are no wider than `HULL_SLAB_MIN`, so a fast player cannot cross one between ticks. Zone counts grow a lot; `DotTimerZoneIndex` is a grid and does not notice.
- **`headless_imported`'s `pits` section fires them** (fgr-g2g-teleports-1): up to 12 destination-carrying main-track pits per map are entered by a running player and must land exactly on their destination with the run kept, and `GATED_COURSES` (bhop_eazy, bhop_eazy_v2) are walked gate by gate from the start and must finish. Both eazy maps' pits already carried their `info_teleport_destination`; a pit in section one returns to t11, which IS the spawn room, so "back at spawn" there is the map's own aim.
- **A door keeps the run.** `G2GPlayer.teleport(..., keep_run)`; `G2GGame._on_effect_requested` is its only caller passing true. A teleport also resets the push memory, so a booster into a gate does not add its speed at the far end.

## Spawns

- **A spawn is lifted 24 units**, not 8. A capsule starting within a few units of a triangle seam is a coin toss whichever way the collision backend rounds; 24 clears the seam and still leaves headroom under the genre's 128-unit minimum ceiling.
- `floor_of` once returned the bottom of the trigger *volume*, which a mapper sinks into the ground on purpose. `lift_out_of_solid` lifts every route's arrival out of brushes; it cannot see displacements (welded triangles with no inside), so a spawn buried in terrain is reported clear. The real answer is a physics shape query per spawn at map load; not done.
- **An overlap test alone proves nothing**: collision margins mean a capsule resting a millimetre above a floor overlaps it. What separates a bad spawn from a margin is how far up it takes to get clear. `tools/spawn_check.gd` asks that of every spawn and destination.
- **A spawn that stands in, or drops straight into, a teleport spawns where that teleport sends** (`spawn_through_pits`, followed through a chain, the spawn's own track's pits only, SPAWN zones only: a map with none keeps its picked team spawn, which on the combat maps leads into the round's own logic). Several maps spawn players in a sealed holding room whose floor is the teleport to the course: bhop_lego2, bhop_badges, bhop_badges2, bhop_lego3, kz_bhop_badg3s, kz_bhop_yonkoma's `map0stato`. "Drops into" means no floor between, and the floor test counts props and displacement triangles as well as brushes (`floor_boxes`): surf_lt_unicorn's bonus starts stand on cloud props over open sky. The pit itself keeps its destination. **A start zone belongs round where the player lands, never round the holding room**: from 2026-10-08 such a pit sent back to the spawn so a start drawn round the room kept its player, and every player was held in the room for ever (on three maps a black one; see [history](history.md)).
- `headless_imported` also asks whether the player is shut in where it rests (16 rays at waist height, one must run 5 m), that it touches no main-track pit in its first three seconds, and that **the main spawn settles inside the main track's START**: the timer asks the zone about the player's own position, so a start box built round a point 240 units over the pad never starts. **Ask the physics, not a bounding box.**

## The solid is the brushes

The face lump holds only faces that ended up visible: the compiler deletes faces nobody can see, mappers paint the rest `nodraw`, and a surf ramp is routinely wrapped in invisible player clip, which is why it is smooth to ride. Between 31% and 77% of a solid brush's sides are not drawn. So the importer reads `LUMP_BRUSHES`, `LUMP_BRUSHSIDES` and the leaf tree, and solves each brush's half-spaces into the convex hull the mapper drew.

- **Convex per brush, never one trimesh**: a concave shape is loose triangles and a sliding hull catches on every interior edge between them, which on a 45° ramp at 3000 u/s is a run ended by a bump that is not there. `tools/collision_probe.gd` (with `--trimesh` for the old collider) is how this is measured.
- **Coplanar world brushes are merged** (`merge_convex_brushes`, the classic compilers' exact merge test: each one's corners behind every other side of the other; bevel sides left out, contents must match), so the seam between two ramp segments is not a lip the next tick hits.
- **Displacements stay triangles**, welded across the map, because terrain is not convex in any useful way. They are the open half of the surf feel problem (see [movement.md](movement.md#ramps-and-the-motor)): making a displacement grid convex is tens of thousands of quads, which cannot be that many shapes.
- **What is solid is decided by classname**, not only contents flags: `trigger_teleport` brushes carry `CONTENTS_SOLID`. `SOLID_BRUSH_ENTITIES` in `bsp_read.py` decides, and `solid_for_players` leaves `func_clip_vphysics`, passable doors and `Solidity 1` brushes non-solid. **A classname in neither list is left non-solid and printed**, because the alternative to a note is an invisible wall nobody can explain.
- **Brush faces wind the same way in both engines**: the axis swap is a rotation and flips nothing. Emitting the ring reversed drew every brush face from behind, which most surfaces hid and a surf ramp (whose underside is nodraw) could not: the ridden face was clear. `headless_imported` checks the winding of every PLATFORM surface.

## What a surface is for comes from its slope

A list of regexes over material names scored almost nothing. In this genre what a surface is for is exactly what its angle lets a player do, which is a number in the plane lump: face area by normal Z falls into three clean bands on every map, and the thin middle band is the ride. **The line between PLATFORM and RAMP is `G2GConfig.max_slope`**, because a texture that says "you can stand here" where the movement says otherwise is a texture that lies.

## What a map's brush entities do

The rule (detail per class in [brush-entities.md](brush-entities.md)): **what a player feels standing in a volume is run, and the map's own logic is not.** `tools/bsp_mechanics.py` writes the manifest's `mechanics`; `G2GMapMechanics` runs it, ticked from `G2GPlayer._on_simulated`.

- **Brush entities are drawn**, not only model 0: a jump map's blocks are `func_door`s and its decoration `func_brush`/`func_illusionary`, offset by their `origin`. `DRAWN_BRUSH_ENTITIES` is the solid list minus `func_clip_vphysics` plus the illusionary ones; `rendermode 10` and an alpha render mode at `renderamt 0` (a brush faded in by a button) are hidden, as is a `func_brush` that starts disabled. A brush entity's `angles` are not applied (no held map has any), and doors are drawn where they rest.
- **A push** is the engine's base velocity: displaced through the motor's own sweep while inside, added to the velocity on leaving. Its "last tick" is kept per TICK so a client's replay reads what the server did. A "once" push re-fires on every entry: the original removes the trigger after first use for everybody, which is shared state this game avoids.
- **A booster is a push given on leaving.** The genre's jump pad is a thin `trigger_multiple` whose `OnEndTouch` sets `basevelocity`, an impulse on the tick the hull leaves: jumping off launches, standing does nothing. `booster_volumes` reads `OnEndTouch` as `leave` and `OnStartTouch`/`OnTrigger` as `once`. A booster filter naming an entity that does not exist means no filter. A game built before `leave` was read gives the impulse on landing, so re-imported maps want the matching game pack.
- **A sinking block is timed per player**: a touch-opened `func_door`/`func_button` moving down over a teleport plate sends you where the plate sends people once you have stood on it longer than the door would take. The anti-standing rename trap (`trap_blocks`) becomes the same per-player block, with the map's own delay (0.09 s on the held maps); a name given with no delay is a gate, not a trap. Nobody can sink a block for somebody else, because nothing is shared.
- **A push or block behind a filter nobody can pass is left out** (`inert_filters`); teleports keep the class-only rule, because renamed classes on some maps are checkpoint logic this game does not run. **A name only a button gives counts as nobody's** (`assignable_names(buttons=False)`): nothing here presses or shoots a map's button, and bhop_badges' shoot-a-button side boosts, read as live, pushed every arrival at section 8's start into the pit that sends there, for ever.
- **Gravity, conveyors and lethal hurt** are run too.
- **Water** comes from world WATER/SLIME brushes, `func_water_analog`/`func_water` (once imported solid), and any brush entity in a water material.
- **Ladders** are `CONTENTS_LADDER` brushes (see [movement.md](movement.md#ladders-and-water)).

## Static props

`tools/bsp_props.py` reads `sprp` (stride from the lump, not a version table), the MDL, the VVD (LOD 0 with its fixups) and the VTX (strip-group headers differ between generations; both sizes are tried and the one whose indices land inside their arrays wins). **Only models the map's pakfile carried are drawn**; a prop naming a stock model is counted in `static_props.stock_models` and not drawn, except a solid one with a written stand-in, which is drawn and collided as a box (`static_props.stock_standins`; [stock-props.md](stock-props.md)). Solid props collide as their `.phy` ledges, which are convex already; a ledge without four points off a plane is skipped (**Godot's convex hull builder kills the process on a flat piece**), and one past 1.5 times the drawn extent is a misread and dropped. Props are drawn in `Props` instances, not `World`, so the probes never ask a tree whether it is a floor, and they are not in the pit rules' solids. `prop_dynamic`s standing in the 3D sky room are imported as static (never solid). How props are lit is in [map-rendering.md](map-rendering.md#static-props).

## What is not imported, and why

- **Anything from the original game's own archives**: stock textures, stock models, skies not packed into the map. A `.bsp` embeds only what the mapper added. Stand-ins are drawn instead (see [map-rendering.md](map-rendering.md)), and **nothing from `/extra` (private reference copies) may enter a repository or a pack**: `tools/publish_maps.gd` refuses a map containing a file whose hash matches one there, or a link into it.
- **The map's logic**: outputs, relays, counters, moving doors, rounds. A puzzle map whose route runs through keys and a quest counter, and a map whose only difference is a look-direction trigger, were not imported; three held maps have no runnable finish and are listed in `headless_imported`'s `NOT_COURSES` (see [testing.md](testing.md#lists-asserted-both-ways)).
- **Animated and scrolling materials.**

**These maps are third-party work.** `godot/inspirations/` is read-only reference. Shipping extracted geometry in a released game is a different act from reading it, and needs the author's permission; the attribution in each zones file is what stops a map arriving uncredited. `docs/gamebanana-ranking.md` records where each candidate came from and why it was or was not taken.

## The mesh is a binary, not a glTF

The baked lighting needs `ARRAY_TEX_UV2` to reach the shader, and every importer route decides what a second UV set means: glTF's occlusion channel is greyscale (the neon goes grey) and its emissive channel is additive (it washes out). Building the `ArrayMesh` from a `PackedByteArray` costs one pass and keeps this repository's convention that maps are made in code. The vertex is ten floats; anything added since (a displacement blend's alpha) goes in its **own block after the indices**, so a pack imported now still loads in a game built before.

**`Image.load_from_file` on a `res://` path works from source and ships nothing**: an export packs the imported `.ctex`, not the `.png`. `load()` is correct in both. The browser client is the target that cannot be debugged by looking at it.

## Source 2 maps (`tools/vrf_import.py`)

A CS2 map is a `.vpk` of compiled resources, not a `.bsp`. `tools/vrf_import.py` runs ValveResourceFormat's `Source2Viewer-CLI` (MIT, version 20.1) to export the map to glTF, then writes the same manifest and `.bin` the BSP importer does, so the loader, the zones file and every suite treat it as any other imported map. `surf_hologram` (Chent) is the first; `surf_intro` (Chent, seven stages) the second. **A map with no `map_start`/`map_end` triggers is read from its teleport graph** (`build_staged_zones`): `Spawn`, `S1`..`Sn`, `Win` start entities; a slab aimed at its own section is a pit, a thin teleport aimed at another section is a gate (a RESPAWN that keeps the run, plus a STAGE zone round the arrival; `Win` is the END). The RAR on GameBanana holds a 0-byte `surf_intro.vpk` beside a folder with the real one: use the file in the folder.

```bash
python3 -I tools/vrf_import.py <map.vpk> maps/imported --id <id> --cli <Source2Viewer-CLI> --work <scratch dir>
```

Needs numpy, scipy and trimesh, and refuses a map whose zones file has no attribution. What it does, and why:

- **Axes and scale**: glTF is metres, Y up. `src = (g.z, g.x, g.y) / 0.0254` gives Source 2 units (the same movement numbers as the genre's units, so only the 0.0254 is undone), then the usual `to_godot`.
- **Collision comes from the physics export, not the render mesh.** `world_physics_physics.glb` is a welded triangle soup; closed 12-triangle boxes become convex hulls, open sheets (the player-clip quads) stay triangles written in both windings, because the loader's concave shape has no backface collision.
- **Zones and spawns come from the entity lump** (`maps/<name>/entities/default_ents.vents_c`, decoded with `-f ... -b DATA`): `[PR#]map_start` and `[PR#]map_end` triggers, one pit per `trigger_teleport`, `info_player_start` as the spawn.
- **No author textures and no baked light.** Surfaces are `prototype` and tinted by a palette keyed on material name (`PALETTE`); the lightmap is a white patch. CS2's `irradiance.exr` is not decoded: a known gap. The stand-in materials are listed `none` in `textures/stock/substitutes.json`.
- **glTF de-duplicates material names with a counter** (`side_rail_ramp_mat_66`); `material_of` strips it.
