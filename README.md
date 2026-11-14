# Zee's Airdrift

A 3D surf and bunny-hop timer game for [Godot 4](https://godotengine.org/), built on the [Dot collection](https://moddingcommunity.com/co/4-dot-assets) and [TMC's gaming platform](https://moddingcommunity.com/play). It is inspired by Source Engine movement and includes classic Surf and Bunny Hop maps from Counter-Strike: Source.

![Preview](https://github.com/zees-games/game-airdrift/blob/main/images/preview.gif?raw=true)

*Play on the test server [here](https://moddingcommunity.com/g2gfast/s/g2gfast01/play).*

The project and its assets are open source under the MIT license. Only the back-end web infrastructure is not; if you use your own authentication back end instead of TMC, you build that part yourself.

**Please treat this as partially tested.** It was built with Claude Code and has a headless test suite that passes, but little of it has been in front of real players. Please report anything you run into.

## How it plays

Each map has a start zone and an end zone. Leaving the start zone starts your timer; reaching the end stops it. Your best time on each map, track and style is a record, and the fastest on the server is the world record. Some maps have stages and bonus tracks.

Movement uses the classic units and cvars (`sv_airaccelerate`, `sv_autobunnyhopping` and so on), so surfing and strafing feel familiar.

Styles make a run harder: normal, sideways, half-sideways, backwards, low gravity and prebhop. A run made with an admin's help (noclip, a speed change and so on) is never saved.

The game ships with three maps: `bhop_g2g_intro`, `bhop_g2g_stages` and `surf_g2g_intro`. The classic maps live in [airdrift-maps](https://github.com/zees-games/airdrift-maps), and a server downloads them on demand.

## Controls

Every key can be rebound under **Esc, Controls**; bindings are saved on your device.

| Key | Action |
| --- | --- |
| **WASD** | Move |
| **Space** | Jump (hold it if the server allows auto-hop) |
| **Ctrl** | Duck |
| **F5** | First or third person |
| **F** | Flashlight (only you see it) |
| **O** | Hide every other player and the record ghost |
| **Tab** (hold) | Scoreboard: style, best time and rank on this map, time on the server, ping |
| **N** | Change style |
| **R** | Back to the start of your stage (or track). Press twice quickly for the main start zone |
| **C** / **V** | Save a practice checkpoint / go back to it |
| **Y** / **U** | Chat / team chat |
| **M** | Map list: pick a map with 1-7 or a click, 8 and 9 turn the page. See "Map changes" below |
| **Z** | Zone editor (offline, or an admin); see [Zones](#zones) |
| **H** | Help: every key and chat command |
| **P** | Next HUD theme |
| **Left / right click** | While spectating: previous / next player |
| **G** | While spectating: free camera (WASD, Space / Ctrl up and down, Shift fast, Alt slow), and back onto a player |
| **Esc** | Menu: settings, key bindings, help |
| **`** | Console; `settings` lists every setting |

**Map changes (M).** Offline, and on a server you started yourself, the choice changes the map. On a public server staff change it (`sv_map_menu_flag` picks the admin flag), the only player on the server changes it too (`sv_map_menu_alone`, on by default), and anybody else's choice is a vote of the players there (at least `sv_map_menu_vote_min`, default 2; bots never count).

**Menu options.** Under **Esc, HUD & theme** you pick one of six themes, switch each timer line on or off, set its size and corner, and drag the timer, keys, status line and spectator list wherever you want them (saved to your account). The menu also has your style, field of view, a frame-rate cap (unlimited by default), V-Sync, render scale and volumes. `show_own_body 1` draws your own character in first person (off by default, also in the menu). In a browser, **H** also lists the keys the browser keeps for itself, such as Ctrl+W.

### Chat commands

| Commands | What they do |
| --- | --- |
| `!r`, `!rs`, `!s <n>`, `!track bonus 1` | Restart, restart this stage, go to stage n, pick a track |
| `!wr` / `!top`, `!pb [name]`, `!rank`, `!rr`, `!wrcp`, `!prinfo` | Records: fastest times, personal best, rank, latest records, stage records, your attempts here |
| `!profile` / `!p`, `!players`, `!stats`, `!mapsdone`, `!mapsleft`, `!tier` | Profiles, who is online, stats, map progress, map tier |
| `!style`, `!rtv`, `!end`, `!pause`, `!unpause`, `!autorestart` | Style, map vote, end the run, pause, auto restart |
| `!restore` | Take back a run you dropped by disconnecting |
| `!spec`, `!spec <name>`, `!spec free`, `!spec off` | Watch whoever is furthest into a run, a named player, a free camera, or stop |

While you watch somebody, the list of others watching them is on the right. A server turns that off with `sv_spec_list 0`; you can hide it under **Esc, HUD & theme**.

## Getting started

You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository. The easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap), which clones every project and links the addons in:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/game-g2gfast
./game.sh
```

On Windows, run `bootstrap.ps1` and open the project in Godot.

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline, in a window |
| `./game.sh online` | Start a local server and the browser client, and print the link |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh help` | All options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this project. Run its `./setup.sh` once first.

## Running a server

Settings are cvars. Set them in the server config, on the command line, or live from the console. `cvarlist sv_` lists them all. The values below are the defaults.

| Cvar | Default | What it does |
| --- | --- | --- |
| `sv_autobunnyhopping` | 1 | Hold jump to keep hopping |
| `sv_airaccelerate` | 1000 | Air acceleration for every map |
| `sv_gravity` | 800 | Gravity |
| `sv_maxvelocity` | 3500 | Speed limit |
| `sv_crestlaunch` | 1.25 | Speed needed (times run speed) for a ramp top to launch you; 0 is never |
| `sv_allow_thirdperson` | 1 | Players may use third person |
| `sv_flashlight` | 1 | Players may use their own flashlight |
| `sv_spec_list` | 1 | Players see who is spectating them; 0 makes spectating anonymous |
| `mp_freeroam` | 1 | Spectators may fly a free camera; 0 keeps them on players |
| `mp_freeroam_speed` | 12 | Free camera speed, metres a second |
| `mp_forcecamera` | 0 | 1 or 2 restricts the camera and switches free roam off |
| `sv_stagger_snapshots` | 0 | 1 spreads snapshot work over the ticks between snapshots (lower worst tick on a full server) |
| `sv_replay_bot` | 1 | The server record runs as a visible ghost |
| `sv_map_sync_timeout` | 30 | Seconds a map change waits for slow clients |
| `sv_deathmatch` | 0 | Players can shoot each other |
| `mp_killcam_time` | 7 | Seconds of final killcam when a deathmatch ends (0 is off) |
| `sv_hunters` | 0 | Monsters walk the course |
| `sv_props` | 0 | Players can place practice blocks |
| `sv_ragdoll` | 1 | A dead player falls as a ragdoll; 0 is a quick fall |
| `sv_map_rotation_file` | `cfg/maps.yml` | Which installed maps rotate |
| `mp_teamblock` / `mp_enemyblock` | 0 / 1 | dot-team block rules, with `!block` and `!noblock`. Runners are not solid to each other, so these matter only once players are made solid |

A player killed in deathmatch or by a hunter falls as a ragdoll ([dot-player-char](https://github.com/modcommunity/dot-player-char)) until they are back at the start. `sv_ragdoll_style` picks ragdoll, stiff, topple or hide; `sv_ragdoll_time` and `sv_ragdoll_max` say how long and how many; `sv_ragdoll_reactions` weights the falls.

### Every setting as a file, a cvar and a panel

Each field of the server configuration (`game/g2g_config.gd`, with its description and range) is also a `g2g_<field>` cvar, unless it already has an `sv_` one. Layers, weakest first:

1. the code default
2. `cfg/game/game-g2gfast/config/game.yml`
3. `cfg/server/game/game-g2gfast/config/game.yml`
4. `G2G_*` environment
5. `--g2g-*` arguments
6. live cvars and the workbench

A dedicated server refuses to start on an unknown key or a bad value. Per-map movement lives in `cfg/game/game-g2gfast/dot_map/map/<map>.yml`. `g2g_config_dump` lists every field with the layer it came from; `g2g_config_diff save` writes what you changed as a file to copy into the defaults. The dot-workbench tuning panel (F9 in debug builds; `workbench http` for a loopback page when `workbench.enabled` is set in `cfg/server.yml`) edits the same fields. An exported build needs `*.html` in the preset's `include_filter`.

### Which maps rotate

List the maps you want in `cfg/maps.yml` (named rotations, wildcards and `sv_map_rotation <name>`; see dot-map `docs/rotation.md`). A map you leave out stays installed: `g2g_map <id>` still loads it and **M** lists it as "not in rotation", but it never comes round on its own and is not offered in votes.

```yaml
mode: random          # or sequential
cooldown: 2           # maps that must pass before one comes back
maps:
  - bhop_eazy
  - bhop_evolve
  - surf_mesa
```

`.yaml`, `.json` (`{"maps": [...]}` or a plain list) and one-map-per-line `.txt`, `.cfg` or `.ini` files also work. With no file every map rotates, except combat surf maps. `g2g_maps_reload` re-reads it. Played offline alone, a map has no time limit; `--g2g-offline-map-seconds 1800` sets one.

When the map changes, every client is told first, downloads the map if it needs to, and the server switches once everybody is ready (or after `sv_map_sync_timeout`).

### Console commands

| Command | What it does |
| --- | --- |
| `g2g_status` | What the server is doing |
| `g2g_map <id>` | Change the map, or list them with no id |
| `g2g_maps_reload` | Pick up maps added to `maps/` without a restart |
| `g2g_top` | Fastest times on this map |
| `g2g_ghost` | What the record ghost is running |
| `g2g_vote` | Open a map vote now |
| `g2g_hunt [clear\|spawn <id>]` | Show, clear or place hunters |
| `g2g_place_clear` | Clear every placed block |
| `g2g_settier`, `g2g_rescore`, `g2g_deleterecord <name> [track] [style]`, `g2g_wipeplayer <id>` | Admin: record management |

### Records

Records are kept in files under `user://g2gfast/records` unless you give the server a database. SQLite needs the [godot-sqlite](https://github.com/2shady4u/godot-sqlite) extension. PostgreSQL and MySQL go through [dot-sql](https://github.com/modcommunity/dot-sql)'s HTTP gateway, which lets several servers share one leaderboard. In the server config:

```json
{
  "records_database": "mysql",
  "records_database_url": "http://10.0.0.5:8780",
  "records_database_token": "keep this in the file, not on the command line",
  "records_table_prefix": "dot_timer_",
  "records_cache_seconds": 10,
  "points_formula": "curve",
  "points_weighting": 0.975,
  "enforce_stages": true,
  "resume_seconds": 600,
  "report_to_backbone": false
}
```

`points_formula` is `curve`, `tiered` or `placement`. If the database will not open, the server logs an error and uses files for that session. With `report_to_backbone` on, times and ranking points are published to the server's page on TMC.

### Admin commands

These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `!noclip`, `!freeze`, `!slay`, `!blind`, `!beacon` and the rest. Any run that noclip, speed or gravity touches is not saved. `burn` is turned off because there is nothing to burn on a course.

### The map vote

The next-map vote is [dot-vote](https://github.com/modcommunity/dot-vote). The defaults (shown below) are in `game/g2g_vote.gd`. To change them, create `user://cfg/g2gfast_vote.json`, or use `DOT_VOTE_*` environment variables or `--vote-*` arguments:

```json
{ "end_vote": true, "vote_lead_sec": 120, "include_extend": true, "extend_seconds": 600, "max_extends": 3 }
```

`end_vote: false` turns the end-of-map vote off and `include_extend: false` removes "extend" from the ballot. dot-vote's README lists every setting.

## Maps

### Importing a map

The importer reads BSP version 20 maps. Put the `.bsp` files in `../inspirations/g2gfast/` and run:

```bash
tools/import_maps.sh      # imports anything new, skips what is current
tools/bsp_preview.sh      # renders each map from its spawn
```

Imported maps land in `maps/imported/`, a link to the airdrift-maps checkout. A running server picks up new ones with `g2g_maps_reload`.

Collision comes from the map's brushes, so invisible player clips and surf ramp clips work as the mapper meant. Surfaces are coloured by angle: standable, slidey and wall each look different.

The map's own volumes work too: teleports keep your run going, boosters push, water is swum in (hold jump to come up), ladders are climbed, conveyors carry you, and a bunny-hop block sends you back if you stand on it. Blocks are timed per player. [`docs/brush-entities.md`](docs/brush-entities.md) covers every brush entity.

**Combat maps.** Some surf maps are for fighting, not timing. Their zones file says `"kind": "arena"` and they live in [fc-surf-dm-maps](https://github.com/zees-games/fc-surf-dm-maps) for Fatal Contact's deathmatch, not in airdrift-maps. `tools/bsp_import.py` writes such a map there. If one is installed here anyway it stays loadable, **M** marks it "combat", and it is left out of the rotation and the vote unless `cfg/maps.yml` lists it.

### Zones

Most surf and bunny-hop maps name their own start, end, stages and bonuses, and the importer reads those. For a map that does not, write zones in `maps/zones/<id>.json` (see [`maps/zones/README.md`](maps/zones/README.md)) or draw them in the game.

Zones are glowing boxes: green start, red finish, amber stages, cyan and magenta for a bonus. **Esc, General, Zones** turns them off.

**Z** opens the zone editor. Aim at the floor; a marker snaps to a 16-unit grid.

| Key | What it does |
| --- | --- |
| **1**-**6** | Start, end, stage, checkpoint, stop, pit |
| **T** | Main track, bonus 1, bonus 2, ... |
| **[** / **]** | Stage or checkpoint number |
| **PgUp** / **PgDn**, or the wheel | Height, 16 units at a time (128 by default) |
| **E** or click | Put a corner; the box follows your aim until the second |
| **Backspace** | Take the last zone back |
| **Enter** | Save |
| **Z** or **Esc** | Close |

Offline it saves to `user://zones/<map>.json`, which the game loads in place of the map's own zones. On a server it sends the server's zone commands for you (these need the changemap flag). The console works too:

```
g2g_zone start          // start drawing a start zone
g2g_zone_mark           // stand on one corner
g2g_zone_mark           // then the other
g2g_zone stage main 1   // the next zone: stage 1 of the main track
g2g_zone_save           // write them to disk
```

`g2g_zone_undo` removes the last one and `g2g_zone_list` lists them.

## Testing

```bash
./game.sh test                  # every script parses, then every suite runs
./game.sh test headless_run     # one suite
```

| Suite | What it covers |
| --- | --- |
| `headless_run` | Movement, the timer, zones, and bots running every built-in map |
| `headless_net` | A server and a client in one process |
| `headless_maps` | The map catalogue, map changes and the vote |
| `headless_presentation` | What a client draws and plays |
| `headless_stack` | The whole addon stack together |
| `headless_imported` | Every imported map loads and has its zones |
| `headless_mechanics` | Teleports, sinking blocks, pushes and water on every imported map |
| `headless_config` | Every config field as a cvar and a profile |
| `headless_workbench` | dot-workbench over the config: an edit, and the export as defaults |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Credits

| Asset | Author / source | License | Where |
| --- | --- | --- | --- |
| Prototype textures | Kenney, Prototype Textures | CC0 | `textures/prototype/` (its README says which file came from where) |
| Players | Quaternius, [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html), coloured from Kenney's character kit skins | CC0 1.0 | dot-player-char |
| Avatar parts and hats | Kenney | CC0 | dot-player-char |
| Stand-in scenery | Kenney Food Kit, Holiday Kit, Nature Kit | CC0 | `props/kenney/` |
| Stand-in textures | Kenney, Retro Textures Fantasy | CC0 | `textures/stock/` |
| Concrete, metal and snow textures | [Concrete034](https://ambientcg.com/view?id=Concrete034), [Metal032](https://ambientcg.com/view?id=Metal032), [MetalPlates006](https://ambientcg.com/view?id=MetalPlates006), [Snow010A](https://ambientcg.com/view?id=Snow010A) from ambientCG, Lennart Demes | CC0 | `textures/stock/` (`LICENSE.txt` lists every file) |
| Footsteps | Kenney, Impact Sounds | CC0 | dot-audio, `addons/dot_audio/stock/CREDITS.md` |
| Ambience beds | Generated by dot-audio | none (synthesized) | dot-audio |
| Imported maps | Their authors, credited in [airdrift-maps](https://github.com/zees-games/airdrift-maps) | as stated there | airdrift-maps |

## License

MIT. See [LICENSE](LICENSE). The Kenney textures are CC0, which is public domain.
