This is a game to demonstrate the capabilities of the [**Dot collection**](https://moddingcommunity.com/co/4-dot-assets) built on-top of [Godot 4](https://godotengine.org/) and [TMC's gaming platform](https://moddingcommunity.com/play). In this 3D game, players *surf* and *bunny hop* on *maps* to compete for world records through a timer. This is highly inspired off of Source Engine movement and includes some classic Surf Timer and Bunny Hop maps (WIP) from the game Counter-Strike: Source!

![Preview](https://github.com/zees-games/game-g2gfast/blob/main/images/preview.gif?raw=true)

*Play on my test server [here](https://moddingcommunity.com/g2gfast/s/g2gfast01/play)!*

**This project and the assets under it are COMPLETELY OPEN SOURCE**. You are free to use, modify, and distribute them under the terms of the MIT license. The only thing not open source is the back-end web infrastructure. So if you opt into using your own authentication backend instead of integrating with TMC, you will need to build and integrate your own back-end infrastructure.

## From Maintainer & WARNING
This project, along with every asset it is built on, was built initially with **Claude Code** and will continue to be maintained and extended using it. This is because I (`gamemann`) cannot build the entire TMC platform alone (I wish I could lol).

**Please treat this as partially tested.** It has its own headless test suite and that suite passes, but very little of this has been in front of real players yet. Expect rough edges, and please report anything you run into.

I intend on reviewing code, testing, and editing documentation regularly. If you're interested in helping out, please let me know!

## How it plays
Each map has a start zone and an end zone. Leaving the start zone starts your timer and reaching the end stops it. Your best time on each map, track and style is a record, and the fastest one on the server is the world record. Some maps are split into stages, and some have bonus tracks.

The movement uses the classic units and cvars (`sv_airaccelerate`, `sv_autobunnyhopping` and the rest), so surfing and strafing feel the way they always have.

There are styles for a harder run: normal, sideways, half-sideways, backwards, low gravity and prebhop. A run made with an admin's help (noclip, a speed change and so on) is never saved.

The game comes with three maps of its own: `bhop_g2g_intro`, `bhop_g2g_stages` and `surf_g2g_intro`. The classic maps it imports live in a separate repository, [g2gfast-maps](https://github.com/zees-games/g2gfast-maps), and a server downloads them on demand.

## Controls

| Key | Action |
| --- | --- |
| **WASD** | Move |
| **Space** | Jump (hold it, if the server allows auto-hop) |
| **Ctrl** | Duck |
| **F5** | First or third person |
| **F** | Flashlight. Only you see it |
| **O** | Hide every other player and the record's ghost |
| **Tab** (hold) | The scoreboard: everybody on the server with their style, best time and rank on this map, how long they have been on, and their ping |
| **N** | Change style |
| **R** | Back to the start of the stage you are in (or of the track, outside a stage). **R R** quickly: back to the main start zone, from a bonus too |
| **C** / **V** | Save a practice checkpoint / go back to it |
| **Y** / **U** | Chat / team chat |
| **M** | The map list: every map, 1–7 or a click to change to it, 8 and 9 to turn the page. Offline, and on a server you started yourself (`./game.sh online`), it changes the map. On a public server staff change it (the owner picks the flag with `sv_map_menu_flag`), the only player on the server changes it too (`sv_map_menu_alone`, on by default), and anybody else's choice is a vote of the players there (at least `sv_map_menu_vote_min`, 2 by default; bots never count) |
| **Z** | The zone editor (offline, or an admin): see [Zones](#zones) |
| **H** | Help: every key and every chat command on the server |
| **P** | Next HUD theme |
| **Left / right click** | While spectating: the previous / next player |
| **G** | While spectating: a free camera (WASD, Space / Ctrl up and down, Shift fast, Alt slow, mouse to look), and back onto a player. `!spec free` does the same from chat |
| **Esc** | The menu: settings, key bindings, help. Click the game or **Resume** to take the mouse back |
| **`** | The console. `settings` lists every setting |

Every key can be rebound under **Esc → Controls**, and the bindings are saved on your device. **Esc → HUD & theme** picks one of six themes for the menus and the HUD, switches each line of the timer on or off, sets its size and corner, and has **Move HUD elements**, where you drag the timer, the keys, the status line and the spectator list wherever you want them; the layout is saved to your account. The menu also has the HUD switches, your style, the field of view, a frame-rate cap (unlimited by default), V-Sync, render scale and the volumes. In a browser, **H** also lists the keys the browser keeps for itself — **Ctrl+W** closes the tab, and Ctrl is Duck.

In chat: `!r` (restart), `!wr` or `!top` (fastest times), `!style`, `!track bonus 1`, `!s <n>` (go to stage n), `!rs` (restart this stage), `!stats`, `!rtv`, and `!spec` (or `/spec`) to watch whoever is furthest into a run, `!spec <part of a name>` to watch somebody in particular, `!spec off` to stop. While you watch somebody, the list of everybody else watching them is on the right, and when people watch you, you see theirs; a server turns that off with `sv_spec_list 0`, and you can hide it under **Esc → HUD & theme**.

Records in chat: `!pb [name]`, `!rank`, `!players`, `!rr` (latest records), `!profile` or `!p`, `!mapsdone`, `!mapsleft`, `!wrcp` (stage records), `!prinfo` (your attempts here), `!tier`, `!end`, `!pause` and `!unpause`, `!autorestart`, and `!restore` to take back a run you dropped by disconnecting.

`show_own_body 1` in the console draws your own character in first person. It is off by default, and it is in the menu too.

## Getting started
You need [Godot 4.7](https://godotengine.org/download). The game is built from many Dot addons, each in its own repository, so the easiest way to get everything is [dot-bootstrap](https://github.com/modcommunity/dot-bootstrap). It clones every project and links the addons into each one:

```bash
git clone https://github.com/modcommunity/dot-bootstrap.git
cd dot-bootstrap
./bootstrap.sh
cd projects/game-g2gfast
./game.sh
```

On Windows, run `bootstrap.ps1` instead and open the project in Godot.

`game.sh` does everything else:

| Command | What it does |
| --- | --- |
| `./game.sh` | Play offline, in a window |
| `./game.sh online` | Start a local server and the browser client, and print the link to open |
| `./game.sh online down` | Stop them |
| `./game.sh server` | Start a local dedicated server only |
| `./game.sh test` | Check every script and run every test suite |
| `./game.sh help` | All of the options |

`online` and `server` use [dot-server-deploy](https://github.com/modcommunity/dot-server-deploy), which bootstrap clones next to this one. Run its `./setup.sh` once first.

## Running a server
Settings are cvars, in the units you already know. Set them in the server's config, on the command line, or live from the console. `cvarlist sv_` lists them all.

```
sv_autobunnyhopping 1        // hold jump to keep hopping
sv_airaccelerate 1000        // 150 for surf
sv_gravity 800
sv_maxvelocity 3500
sv_crestlaunch 1.25          // how fast you must be going for a ramp's top to launch you (x run speed, 0 = never)
sv_allow_thirdperson 1
sv_flashlight 1              // players may use their own flashlight (F); nobody else sees it
sv_spec_list 1               // players see who is spectating them; 0 makes spectating anonymous
mp_freeroam 1                // spectators may fly a free camera; 0 keeps them on players
mp_freeroam_speed 12         // free camera speed, metres a second
mp_forcecamera 0             // 1 or 2 restricts the camera and switches free roam off
sv_stagger_snapshots 0       // 1 spreads snapshot work over the ticks between snapshots: a lower worst tick on a full server
sv_replay_bot 1              // the server record runs as a visible ghost
sv_map_sync_timeout 30       // how long a map change waits for slow clients
sv_deathmatch 0              // players can shoot each other
mp_killcam_time 7          // seconds of final killcam when a deathmatch ends (0 off)
sv_hunters 0                 // monsters walk the course
sv_props 0                   // players can place practice blocks
sv_ragdoll 1                 // a dead player falls as a ragdoll; 0 is a quick fall with no physics
sv_map_rotation_file cfg/maps.yml   // which installed maps rotate; see below
```

A player killed in deathmatch or by a hunter falls as a ragdoll ([dot-player-char](https://github.com/modcommunity/dot-player-char)) until they are back at the start; the server picks how each one goes down and everybody sees the same fall. `sv_ragdoll_style` picks ragdoll, stiff, topple or hide, `sv_ragdoll_time` and `sv_ragdoll_max` say how long and how many, and `sv_ragdoll_reactions` weights the falls (`limp`, `face_plant`, `crumple`, `headshot_launch`, `power_launch`; 0 turns one off).

### Which maps rotate
Put the maps you want played in `cfg/maps.yml` (named rotations, wildcards and `sv_map_rotation <name>`: see dot-map docs/rotation.md). A map you leave out stays installed: `g2g_map <id>` still loads it and **M** lists it, marked "not in rotation". It just never comes round on its own, and the vote and nominations don't offer it.

```yaml
mode: random          # or sequential
cooldown: 2           # maps that must pass before one comes back
maps:
  - bhop_eazy
  - bhop_evolve
  - surf_mesa
```

`.yaml`, `.json` (`{"maps": [...]}` or a plain list), and the old one-map-per-line `.txt`, `.cfg` or `.ini` work too. With no file every map rotates, except the combat surf maps (below). `g2g_maps_reload` re-reads it.

Played offline, by yourself, a map has no time limit. `--g2g-offline-map-seconds 1800` gives it one.

Console commands:

| Command | |
| --- | --- |
| `g2g_status` | What the server is doing |
| `g2g_map <id>` | Change the map, or list them with no id |
| `g2g_maps_reload` | Pick up maps added to `maps/` without a restart |
| `g2g_top` | Fastest times on this map |
| `g2g_ghost` | What the record ghost is running |
| `g2g_vote` | Open a map vote now |
| `g2g_hunt [clear\|spawn <id>]` | Show, clear or place hunters |
| `g2g_place_clear` | Clear every placed block |

### Records
Records are kept in files under `user://g2gfast/records` unless you give the server a database. SQLite needs the [godot-sqlite](https://github.com/2shady4u/godot-sqlite) extension; PostgreSQL and MySQL go through [dot-sql](https://github.com/modcommunity/dot-sql)'s HTTP gateway, which is what lets several servers share one leaderboard. In the server's config file:

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

`points_formula` is `curve`, `tiered` or `placement`. If the database will not open, the server logs an error and keeps files for that session. With `report_to_backbone` on, times and ranking points are published to the server's page on TMC.

Admin commands for records: `g2g_settier <1-10>`, `g2g_rescore`, `g2g_deleterecord <name> [track] [style]` and `g2g_wipeplayer <id>`.

When the map changes, every client is told first, downloads the map if it needs to, and the server switches once everybody is ready (or after `sv_map_sync_timeout`).

### Admin commands
These come from [dot-moderation](https://github.com/modcommunity/dot-moderation): `!noclip`, `!freeze`, `!slay`, `!blind`, `!beacon` and the rest. Any run that noclip, speed or gravity touches is not saved. `burn` is turned off, because there is nothing to burn on a course.

### The map vote
The vote for the next map is [dot-vote](https://github.com/modcommunity/dot-vote). The defaults are in `game/g2g_vote.gd`. To change them, put a file at `user://cfg/g2gfast_vote.json` (or use `DOT_VOTE_*` environment variables, or `--vote-*` arguments):

```json
{ "end_vote": true, "vote_lead_sec": 120, "include_extend": true, "extend_seconds": 600, "max_extends": 3 }
```

`end_vote: false` turns the end-of-map vote off, and `include_extend: false` takes "extend" off the ballot. dot-vote's README lists every setting.

## Maps
### Importing a map
The importer reads BSP version 20 maps. Put the `.bsp` files in `../inspirations/g2gfast/` and run:

```bash
tools/import_maps.sh      # imports anything new, skips what is already current
tools/bsp_preview.sh      # renders each map from its spawn, so you can look at it
```

The imported maps land in `maps/imported/`, which is a link to the g2gfast-maps checkout. A running server picks up new ones with `g2g_maps_reload`.

Collision comes from the map's brushes, not from what you can see, so invisible player clips and surf ramp clips work the way the mapper meant. Surfaces are coloured by their angle: one you can stand on, one you slide on, and a wall each look different.

What the map's own volumes do comes across too: a teleport sends you where the map aims it and your run goes on, boosters push, water is swum in (hold jump to come up), ladders are climbed, conveyors carry you, and a bunny-hop block sends you back if you stand on it. Blocks are timed for each player on their own, so nobody can sink a block under the player behind them. [`docs/brush-entities.md`](docs/brush-entities.md) goes through every brush entity and what happens to it.

**Combat maps.** Some surf maps are built to fight on, not to time. Their zones file says `"kind": "arena"` and they are not part of g2gfast-maps: they live in `arena-surf-dm-maps`, for game-arena's deathmatch. `tools/bsp_import.py` writes such a map there, not into `maps/imported/`. If one is installed anyway it stays loadable, **M** marks it "combat", and it is left out of the rotation and the vote unless `cfg/maps.yml` (named rotations, wildcards and `sv_map_rotation <name>`: see dot-map docs/rotation.md) lists it.

### Zones
Most surf and bunny-hop maps name their own start and end zones, stages and bonuses, and the importer reads those. For a map that doesn't, write the zones in `maps/zones/<id>.json` (see `maps/zones/README.md`), or draw them in the game.

Every start, stage and finish is drawn as a glowing box: green start, red finish, amber stages, cyan and magenta for a bonus. **Esc → General → Zones** turns them off.

**Z** opens the zone editor. Aim at the floor: a marker follows your crosshair, snapped to the 16-unit grid.

| Key | |
| --- | --- |
| **1**–**6** | Start, end, stage, checkpoint, stop, pit |
| **T** | Main track, bonus 1, bonus 2, ... |
| **[** / **]** | The stage or checkpoint number |
| **PgUp** / **PgDn**, or the wheel | The height, 16 units at a time (128 by default) |
| **E** or click | Put a corner. The box follows your aim until the second one |
| **Backspace** | Take the last zone back |
| **Enter** | Save |
| **Z** or **Esc** | Close |

Offline it saves to `user://zones/<map>.json`, which the game loads in place of the map's own zones next time. On a server it sends the server's own zone commands for you, which need the changemap flag, and the server saves them the same way. The console still works:

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
| `headless_run` | The movement, the timer, the zones, and bots running every built-in map |
| `headless_net` | A server and a client in one process, over the network code |
| `headless_maps` | The map catalogue, map changes and the vote |
| `headless_presentation` | What a client draws and plays |
| `headless_stack` | The whole stack of addons together |
| `headless_imported` | Every imported map loads and has its zones |
| `headless_mechanics` | Every imported map's teleports, sinking blocks, pushes and water do what they should, with a player on them |
| `dedicated` | A real server: boots, loads the game, runs its commands |

[`CLAUDE.md`](CLAUDE.md) has the design decisions and the reasoning behind them.

## Credits
`textures/prototype/` is Kenney's Prototype Textures (CC0). `textures/prototype/README.md` says which file came from where. The players are the family's animated people from Quaternius' [Zombie Apocalypse Kit](https://quaternius.com/packs/zombieapocalypsekit.html) (CC0 1.0, credited in dot-player-char), coloured from Kenney's character kit skins (CC0); the avatar parts and hats are Kenney's. `props/kenney/` holds the Kenney Food Kit, Holiday Kit and Nature Kit models (CC0) a map's dressing file places as stand-ins for scenery its pack could not carry. `textures/stock/` stands in for textures an imported map did not carry: Kenney's Retro Textures Fantasy (CC0), and for concrete, metal and snow, which Kenney has none of, [Concrete034](https://ambientcg.com/view?id=Concrete034), [Metal032](https://ambientcg.com/view?id=Metal032), [MetalPlates006](https://ambientcg.com/view?id=MetalPlates006) and [Snow010A](https://ambientcg.com/view?id=Snow010A) from ambientCG by Lennart Demes (CC0); `textures/stock/LICENSE.txt` lists every file. The imported maps are credited to their authors in [g2gfast-maps](https://github.com/zees-games/g2gfast-maps). Footsteps are Kenney's Impact Sounds and the ambience beds are generated by dot-audio, both CC0 and shipped in dot-audio (`addons/dot_audio/stock/CREDITS.md`).

## License
MIT. See [LICENSE](LICENSE). The Kenney textures are CC0, which is public domain.
