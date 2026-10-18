# Testing: the suites, the tools, and what they cannot see

`./game.sh test` parses every script and runs every suite in `SUITES` with a timeout and the stderr check; `./game.sh test NAME...` runs some; `./game.sh suites` lists them. Logs go to `.godot/test-logs/`. **Read a suite's stderr even when it exits 0**: a script error aborts that test, not the run (family [testing.md](../../../docs/testing.md)). Every suite counts its sections and its checks and exits 1 when either is off.

## The suites

| Suite | What it is the proof of |
| --- | --- |
| `headless_run` | The simulation on the three hand-built maps: movement, the timer, styles, tracks, zone files matching `export_zones`, zones over something, every bonus route driven end to end by a bot, the reach sweep, R. `-- --only=<method>[,<method>...]` runs some sections in order. **It is order-sensitive** (the crease hang in [movement.md](movement.md#ramps-and-the-motor)): a section that passes alone can fail after another, so a new section goes where it does not change what runs after it, and `--only` with a comma list is how to find the pair. |
| `headless_net` | A server game and a client game in one process over a lossy loopback: admission, prediction converging, the timer and a finish to the sub-tick fraction, a cvar under a live client, styles, tracks, avatars, map changes through dot-map's protocol (a client that has the map, one downloading it, one that refuses; a delivered map; a republished one), hunters, spectating, the vote's clock, blind and beacon, RULES. **The client runs at 60 Hz against the server's 128 on purpose**: one process has one engine rate, so a suite at one rate passes with the tick-rate chain disconnected. |
| `dedicated` | A real `DotServer` with `G2GModule`: console commands, chat triggers, moderation's live tools, the browser over a real UDP socket, bots, unloading, two map changes with combat up, and **exiting clean** (no message script preloads itself). `server.cfg` sets **100** ticks, not 128, so a chain that ignored it would fail. |
| `headless_bots` | A real `DotServer` with `G2GModule` at 128 ticks and `bot_quota`: a bot on a hand-built map is the route bot, has no timer and moves; on surf_beginner (skipped cleanly without `maps/imported/`) it rides stage 1 with the surf pilot and is put back three times; it prints the driving cost per bot. |
| `headless_maps` | The catalogue has no list (remove one on disk, add one not on disk, rescan), `scan()` lists maps by id as text (armed with fresh StringNames whose intern order is not text order), and the survey of every hand-built map. |
| `headless_workshop` | subscribed map packs against a fixture `DotContentIndex`: listed in solo as `Name [Pack]` (catalogue, M rows, ballot), absent online, an unaccepted `map_kind` filtered, a pack cannot take a built-in id, and a chosen pack map loads (scene as the world, its zones file in the timer, the player on its spawn zone). |
| `headless_imported` | Every imported map, whatever is in `maps/imported/` (skips cleanly when empty): collision, zones, spawns and destinations standable and not shut in, runnable (a time with every split), pits on every track, textures drawn, sky, props, winding, the route, the recording, and the surf bot riding a stage from its cache (`maps/routes/<id>.surf.json`). `-- <id> <id>` checks just those. Run with `--fixed-fps 128` to go as fast as the CPU allows with one tick per frame. |
| `headless_mechanics` | What imported brush entities do: pit destinations, pits keeping the run, sinking blocks, pushes, boosters, water, ladders. Samples at most twelve per map per kind. |
| `headless_presentation` | dot-menu with this game's pages against a fake client, settings migrations, the scoreboard columns, the layer mask, the blind overlay, the beacon's rate, gate effects. |
| `headless_client` | The real offline `G2GClient`: typing does not move the runner (it holds W with the chat box open), the double-tap R, the spectator's drawn camera. |
| `headless_feel` | The real client over a real lossy socket at several display rates (see [netcode.md](netcode.md#what-a-connected-player-sees)); `-- --ws` for a browser's link. Prints measurements; asserts the view, the correction and the clock-slip fixes (the slip against a control). |
| `headless_stack` | The player stack's joins. |
| `jitter_probe` | **Not in `SUITES`**; run it by hand after touching rendering or the tick rate. The only check that samples a rendered frame: four configurations, fails unless exactly the shipped one is smooth. |

## Lists asserted both ways

A list that exempts maps from a check is a mute button unless it is asserted in both directions. In `headless_imported`:

- `NOT_COURSES`: maps with no runnable finish on purpose (a vehicle map, section-chain maps whose END nothing distinguishes, maps game-arena owns are not imported here at all). A listed map that grows a finish fails, which is how the list is found stale. **A suite that is red for a reason nobody intends to fix is a suite people stop reading.**
- `NO_PIT`, separate from `NOT_COURSES`, so maps that have pits keep being asked.
- `ARRIVES_IN_PIT` and `BONUSES_WITHOUT_PITS`: both empty, both still asserted.
- `OWN_TEXTURES`, `STOCK_DRAWN`, `BLENDED`: floors for maps someone has looked at.
- `DARK_SPAWNS`: maps whose view from the spawn is under `SPAWN_VIEW_FLOOR` on purpose, each with why. The view is estimated, not rendered (headless has no renderer): rays from the eye through the drawn meshes, each hit the material's averaged albedo times the atlas texel under it, each miss the sky.
- `headless_mechanics`' `TRAP_BLOCK_FLOORS`.

## Checks that could not fail

Each of these passed while the thing it named was broken; write new checks against them.

- **A check about zones is not a check about a run.** Zone sets can be well formed, thick enough and match their sidecar, and still be unfinishable. `_test_runnable` drives a `DotTimer` over the map's own zones; `_test_stands_where_it_sends_you` waits a second after every teleport destination.
- **A bot that is put back still "finishes".** Route checks assert no reset, using an `Array` (a lambda captures a local by value), and a finish **without being put back**.
- **"Mostly airborne" counted a bot falling out of the world.** Assert the pit fired, or drive until the run starts, rather than for a fixed tick count.
- **A guard pointed at one map** (bonus pits, zone-file matching, a hardcoded list of map ids) passes for the others. Discover what to check.
- **"Still standing three seconds later" passed for a player held in a loop**: a pit that sends back to the spawn puts the player where the check expects them. The collision section now also watches for a main-track pit on every one of those ticks.
- **Both halves in one process share engine state** (tick rate, `Input`), which hides what a real client sees. `headless_client` and `headless_feel` exist for that.
- **Arm a new check**: break the code it guards and see it fire, then put it back.

## Tools

Render after touching the client, a menu or an imported map: no assertion sees the screen, and every tool that draws runs under `xvfb-run` (`--headless` gives a null renderer and empty frames). The bots' route bot moved from `tools/` to `game/g2g_route_bot.gd`, because the server's bots fall back on it and a pack leaves `tools/` out.

| Tool | For |
| --- | --- |
| `tools/export_zones.gd` | Write `maps/<id>.zones.json` after changing a hand-built map. |
| `tools/screenshot_hud.sh`, `tools/screenshot_menus.sh [map] [yaw] [pitch]` | Render the HUD states and every menu page from the real client. |
| `tools/route_preview.sh <map> <track>` | One track of a map from its own spawn, looking down it; `<id> 0 <out> 14 9 0 walk` frames every waypoint of an imported map. |
| `tools/bsp_preview.sh` | Imported maps from their spawns; see [map-rendering.md](map-rendering.md#the-preview-tool-must-show-what-it-says-it-shows). |
| `tools/surf_plan.tscn` | Plans a surf stage on the real motor, writes `maps/routes/<id>.surf.json`, and measures the surf bot riding it (simulated and live, perturbed starts, compute). See [routes.md](routes.md#a-surf-bot-planned-on-the-motor). |
| `tools/collision_probe`, `surf_probe`, `surf_run`, `ramp_bump_probe`, `bhop_probe` | Collision and ride quality of imported maps with the real motor. They sample: seed them, and compare like with like. A percentage of one map is a tool's answer, not an assertion. |
| `tools/spawn_check.gd` | Every spawn and destination, and how far up it takes to get clear. |
| `tools/stage_ride.tscn`, `tools/follow_replay.tscn`, `tools/route_plan.py` | Drive a route or a recording on an imported map; plan a route (see [routes.md](routes.md#imported-maps-a-route-written-as-data)). |
| `tools/load_probe.tscn` | What N players cost a server tick. |
| `tools/audio_probe.sh` | Whether the game makes a sound (headless has no audio device). |
| `tools/avatar_preview.tscn` | Parts inside the hull they must fit. |
| `tools/stock_survey.py` | Textured share per imported map. |

**Rendering is a check.** Many bugs in this game (the layer mask, the backwards winding, the ALPHA pass, gate effects at the world origin, a filed time drawn through the clock, a dark map that was a mis-sampled lightmap) were found by a picture and nothing else.
