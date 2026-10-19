# game-g2gfast

A bunny-hop and surf timer server in the competitive-shooter shape: the genre's movement, units and cvars, a timer with zones, stages, bonuses, styles, records and a replay ghost, and the genre's `.bsp` maps imported as content (game-playground is a sandbox with a surf ramp; this is the *timer server* a records community would migrate to). It ships as a signed dot-cloud pack (`game.yml`) into dot-server-deploy's client shell; imported maps are their own packs from `../g2gfast-maps`.

**Movement and the timer are the core**: read [movement](docs/movement.md) and [timer](docs/timer.md) before touching either. Read the family [CLAUDE.md](../../CLAUDE.md) and each addon's `CLAUDE.md` first. **The detail is in [docs/](docs/README.md)**.

## Read before

| Read | Before |
| --- | --- |
| [docs/movement.md](docs/movement.md) | units, cvars, auto-bhop, styles, spawns, third person, ladders, water, ramps |
| [docs/timer.md](docs/timer.md) | taint, the ghost, stages and R, records, statistics |
| [docs/maps.md](docs/maps.md) | a hand-built map, its zones, `export_zones`, the survey |
| [docs/routes.md](docs/routes.md) | a bonus route, reach, the bots, the replay follower |
| [docs/imported-maps.md](docs/imported-maps.md) | the importer, zones files, pits, spawns, collision, props |
| [docs/stock-props.md](docs/stock-props.md) | stock-model props: counted, not drawn; the ranked list and decisions |
| [docs/brush-entities.md](docs/brush-entities.md) | handling a brush entity class |
| [docs/map-rendering.md](docs/map-rendering.md) | lighting, shaders, textures, skies, `bsp_preview` |
| [docs/map-delivery.md](docs/map-delivery.md) | the catalogue, owners, pack versions, map changes, rotation |
| [docs/netcode.md](docs/netcode.md) | `game/net/`, the tick rate, interpolation, wire rules |
| [docs/client.md](docs/client.md) | camera, avatars, keys, menus, HUD, sound, chat |
| [docs/services.md](docs/services.md) | admin tools, chat, voice, the vote, the browser |
| [docs/modes.md](docs/modes.md) | deathmatch, the fire bit, hunters, practice blocks, effects, spectating |
| [docs/testing.md](docs/testing.md) | adding a check, or believing a green run |
| [docs/history.md](docs/history.md) | a bug that "cannot be happening" |
| [docs/gamebanana-ranking.md](docs/gamebanana-ranking.md) | the next maps to import |

## Layout

`game/` is the simulation (`g2g_game.gd`; units, config and movement are the only boundary into metres), the player, the layers over the timer (combat, hunters, blocks, spectating, bots), hand-built and imported maps, and the client (`g2g_client.gd`, `g2g_hud.gd`, `ui/`; never loaded by a server); `game/net/` the bridge and wire. `maps/` holds the three hand-built maps, `imported/` (linked from g2gfast-maps), `zones/` and `routes/`; `examples/` the suites, `tools/` the tools. **The file-by-file table is in [docs/README.md](docs/README.md#layout).**

## Running and testing

- `./game.sh` plays offline (`godot --path .` works too); `./game.sh online`, `server`, `shot`; `./game.sh test` parses everything and runs every suite; `./game.sh help` lists the rest.
- **Run `godot --headless --path . --script tools/export_zones.gd` after changing a hand-built map**, or the zone-file check fails. [maps](docs/maps.md#geometry-and-zones-come-from-one-description)
- `jitter_probe` is not in `./game.sh test`; run it after touching rendering or the tick rate. [testing](docs/testing.md#the-suites)
- `headless_run` is order-sensitive (`-- --only=a,b`). [testing](docs/testing.md#the-suites)
- Footsteps and map beds are dot-audio's stock; the landing is ours; levels by `loudness.sh`. [client](docs/client.md#presentation-settings-sound-and-effects)
- **Render after touching the client, a menu or an imported map** (`tools/screenshot_*.sh`, `tools/bsp_preview.sh`, xvfb). [testing](docs/testing.md#tools)

## Rules that bite

Short forms; the reasoning is in the linked file.

**Units and movement**

- Genre units everywhere an operator or player looks; metres only past `G2GMovement.tunables_for`; the ratio only in `G2GUnits` (0.01905 m); the jump is a launch velocity. [movement](docs/movement.md#everything-the-operator-touches-is-in-genre-units)
- A movement change abandons every run; styles' `auto_hop`/`easy_bhop` are `INHERIT` (except `prebhop`); validate a cvar on a copy before writing it. [movement](docs/movement.md#auto-bhop-is-the-servers-and-the-styles-defer-to-it)
- A bot walks before it hops: a held jump from standstill creeps at 30 u/s, faithfully. [movement](docs/movement.md#a-held-jump-from-a-standstill-creeps-at-30-us-and-that-is-faithful)
- A movement effect is refused during a ranked run, classified by what the definition changes, never by id. [movement](docs/movement.md#a-movement-effect-is-a-style-and-a-style-you-did-not-choose-is-a-record-you-did-not-set)
- Third person is `G2GCamera` over one motor, never `DotTpsController`; arm `DotCameraBoom`, decided by `mp_forceview`; `tools/camera_check.gd` after touching either. [movement](docs/movement.md#third-person-is-cosmetic-and-stays-g2gcameras)
- A ladder wins over water; the ladder mode never calls `categorise_ground`. [movement](docs/movement.md#ladders-and-water)

**Timer**

- No admin tool can help a run: noclip and speed/gravity steps taint every tick; freeze, blind and beacon do not. [timer](docs/timer.md#what-taints-a-run)
- Taint, never refuse, and at the start: practice blocks, unranked effects, every peer-to-peer run. [timer](docs/timer.md#what-taints-a-run)
- A replay is kept only with an accepted record. Commands apply only to players with a peer. [timer](docs/timer.md#the-records-ghost-is-a-player)
- Every stage zone carries a `destination`; a stage with nowhere to stand is `"restart": false`, refused before the run stops. [timer](docs/timer.md#stages-restarts-and-r)
- Statistics file the difference (finishing resets the controller's); a best time is `LOWEST`. [timer](docs/timer.md#statistics-are-read-not-counted-a-second-time)
- dot-sql is loaded by path and never named; a database that will not open is an ERROR and a session on files. [timer](docs/timer.md#records-standings-and-the-site)

**Maps**

- Geometry, zones and the bot read one list per route; `_pad_centre()` answers "where is the finish". [maps](docs/maps.md#geometry-and-zones-come-from-one-description)
- Every route needs a start, a finish, a spawn and a pit of its own; every zone must hang over something. [maps](docs/maps.md#every-route-has-a-start-a-finish-a-spawn-and-a-pit-of-its-own)
- The surf bot plans on a second motor (`DotFpsSimulator`), never a model of one; regenerate `maps/routes/<id>.surf.json` (`tools/surf_plan.tscn`) after a movement or collision change. [routes](docs/routes.md#a-surf-bot-planned-on-the-motor)
- Server bots: `bot_quota` 0 by default, no timer (never filed), put back by the course; the surf pilot with no forecast (`veto_horizon` 0) where a cache exists, else the route bot, planned through dot-npc-ai's link annotations (`bot_nav`, `g2g_bot_nav.gd`) when the map has no route file. [routes](docs/routes.md#bots-on-a-server)
- A new bonus is a RUN route sized inside `G2GReach`, declared with `add_course`, driven pad to finish with no reset and a pace check. [routes](docs/routes.md#how-the-bots-drive)
- There is no list of maps anywhere; discover. [map-delivery](docs/map-delivery.md#maps-are-dropped-in-not-listed)

**Imported maps**

- A `.bsp` unit is a genre unit; the transform is the axis swap; a yaw is `yaw - 90`; brush bounds are relative to `origin`. [imported-maps](docs/imported-maps.md#scale-and-axes)
- Read the mapper's labels; write a zones file for the rest, with a reason; an unresolved zone stops the import. [imported-maps](docs/imported-maps.md#zones-are-read-not-guessed)
- A pit keeps the run and sends to its own destination; thin pits are thickened, hung under blocks, trimmed off arrivals, cut per brush. [imported-maps](docs/imported-maps.md#pits)
- Spawns lift 24 units; ask the physics, never a bounding box. [imported-maps](docs/imported-maps.md#spawns)
- A spawn in or over a teleport spawns where it sends; a start zone goes round where the player lands, never round a holding room. [imported-maps](docs/imported-maps.md#spawns)
- Collision is convex per brush, coplanar brushes merged; a classname in neither solid list is non-solid and printed. [imported-maps](docs/imported-maps.md#the-solid-is-the-brushes)
- Role from slope, cut at `max_slope`; never from texture names. [imported-maps](docs/imported-maps.md#what-a-surface-is-for-comes-from-its-slope)
- Run what a player feels in a volume, never the map's logic; boosters are given on leaving; blocks sink per player. [imported-maps](docs/imported-maps.md#what-a-maps-brush-entities-do)
- Nothing from the original game's archives or `/extra` enters a repo or pack; every zones file carries an attribution. [imported-maps](docs/imported-maps.md#what-is-not-imported-and-why)

**Rendering**

- Hand-built maps: pastel `G2GTextures.ROLE_COLOURS` and `G2GLighting.DAYLIGHT` via `builtin()`, turned down under Compatibility; imported maps keep their own. [map-rendering](docs/map-rendering.md#the-hand-built-maps-pastel-grid-daylight-document)
- A new drawing rule goes in `G2GBspMap._material_for` / `G2GLighting`, so published packs get it without a republish. [map-rendering](docs/map-rendering.md#a-rule-that-applies-at-build-time-reaches-published-packs)
- Never write `ALPHA` unconditionally. The water shader is copied in game-arena; keep the two in step. [map-rendering](docs/map-rendering.md#opaque-unless-the-material-says-translucent)
- `$additive` surfaces draw with `blend_add` (manifest `additive`); a dark spawn view is in `DARK_SPAWNS` with why, or it is a bug. [map-rendering](docs/map-rendering.md#opaque-unless-the-material-says-translucent)
- The atlas is expose-clip-gamma from the median luxel; never /255, never a tone map; displacements sample over the flat quad. [map-rendering](docs/map-rendering.md#the-lightmap-atlas-keeps-the-maps-contrast)
- Own texture, else Kenney stand-in, else the tinted prototype grid; flat black is missing; black is trusted only when named. [map-rendering](docs/map-rendering.md#textures-the-bsp-did-not-carry)
- A new mesh every 256 surfaces; the first is `World`; materials by manifest index. [map-rendering](docs/map-rendering.md#meshes-over-256-surfaces)

**Delivery**

- No `class_name` anywhere in this game: scripts are preloaded by path, because it is a delivered pack. [map-delivery](docs/map-delivery.md#maps-are-dropped-in-not-listed)
- An imported map is data under the one `imported_map.tscn`; never generate a scene or script per map. [map-delivery](docs/map-delivery.md#maps-are-dropped-in-not-listed)
- A map pack's version is a hash of its files; a mount can never be undone. [map-delivery](docs/map-delivery.md#a-map-packs-version-is-its-files)
- Map changes go through `change_map` and dot-map's protocol; an oversized message is refused whole; a refusing client leaves. [map-delivery](docs/map-delivery.md#a-map-change-is-announced-and-then-made)
- Which courses a server offers is its deployment's config; `game.yml`'s `maps:` is empty on purpose. [map-delivery](docs/map-delivery.md#g2gfast-maps-and-owners)

**Netcode**

- The movement config travels, snapped to float32 first; both ends derive the tunables. [netcode](docs/netcode.md#the-movement-configuration-travels-not-the-tunables)
- HELLO's tick rate moves every copy, the engine's and its step cap included; draw `render_state` between ticks. [netcode](docs/netcode.md#the-client-counts-at-the-servers-tick-rate)
- Draw the view from the sampler once a frame and add the predictor's `visual_offset`; draw the eye at the clock's `render_alpha` (`_fold_clock`); never interpolate view angles. [netcode](docs/netcode.md#what-a-connected-player-sees)
- Wait for `player_added`; the local player does not exist when HELLO names it. [netcode](docs/netcode.md#the-local-player-is-adopted-not-looked-up)
- Event and request kinds are appended; no message script preloads itself. [netcode](docs/netcode.md#wire-rules)
- A READY before the player is seated is kept (`_ready_unseated`) and answered by `add_player`. [netcode](docs/netcode.md#wire-rules)
- Player and hunter entities are `always_relevant`. [netcode](docs/netcode.md#hunters-reach-a-connected-client)

**Client**

- No `[input]` block; `G2GBindings.ROWS` is the one key list. A settings migration drops exactly the old default value. [client](docs/client.md#input-one-table-of-keys-and-no-input-block)
- Pointer lock only on a click; Escape releases, never toggles. [client](docs/client.md#the-pointer-asked-for-never-told)
- The rig's layers: set only the one `visible_to_owner` asks for. [client](docs/client.md#the-camera-the-rig-and-the-players-own-body)
- The menu is dot-menu's and a view of the settings; the shell must be built with dot-menu. [client](docs/client.md#menus-are-dot-menus-the-pages-are-this-games)
- The HUD follows the menu's theme (`apply_theme`, and `follow_hud(hud, null, false)` for dot-ui's pieces), never `hud_scale`. [client](docs/client.md#the-hud)
- The flashlight is a shader default texture, never a `global uniform`. [client](docs/client.md#the-flashlight-lights-unshaded-surfaces-too)
- Shake 0, flashes off, effect budget 24; emitters `local_coords`. [client](docs/client.md#presentation-settings-sound-and-effects)
- **The loading cover is dot-game's `DotGameClient`** (`G2GClient.platform`, `gate` is `platform.gate`), with settings, console and pointer left to this client (`use_settings`, `use_console`, `capture_pointer` off; a partial migration like arena and playground, because the menu pages, console, click-to-play pointer and roster board are the presentation's). `platform.busy_fn` (`_input_busy`) and `input_blocked_changed` suspend the samplers, so the cover stills them too, and the platform flushes the browser's filesystem: the menu and console are `G2GPresentation`'s and `G2GMenuPages`'s, the click-to-play notice is `_grab_mouse`'s. `tools/gate_shot.gd` renders the cover and the lift. `headless_maps` runs dot-core's `DotCollisionAudit` over each hand-built map and fails on a finding; `headless_imported` prints the count per imported map and fails on none (the Sky mesh is opted out with `dot_no_collision`).
- Typing suspends the sampler as well as swallowing input; the console is a menu overlay, built after the menu (`build_console(menu)`). [client](docs/client.md#the-chat-box-and-a-run-nobody-may-lose-to-a-keystroke)

**Services and layers**

- One chat path: `player_chat` and `player_command` are hooked and cancelled; dot-moderation is built first. [services](docs/services.md#chat-is-the-policy-dot-server-stays-the-transport)
- One rock-the-vote; the vote's clock is the one every screen shows; the session's clock ends no map while there is a vote. [services](docs/services.md#the-vote)
- The fire command is a bit on the command, consumed on read, never retained over a lost packet; never `get_meta(key, null)`. [modes](docs/modes.md#the-trigger-is-one-ticks-input)
- Weapon rows set `authored_tick_rate` (128). The held weapon reaches its owner only (`net_weapon`, `G2GArsenal.WIRE_IDS` appended). [modes](docs/modes.md#deathmatch-is-a-layer)
- Entity ids from `DotEntityTable`, never derived; the userid is a separate thing. [modes](docs/modes.md#deathmatch-is-a-layer)
- Hunters have no navigation graph (`require_navigable_spawn` off). Practice blocks spawn frozen, `only_practice` on. [modes](docs/modes.md#a-timer-map-is-a-critical-path-so-the-hunters-have-no-navigation-graph)
- A hunter brain seeds from `npc.seed`, never `npc.instance_id`. dot-npc `docs/runtime.md`
- Spectating: `force_camera` 0 unless deathmatch; `sv_spec_list` gated on the server. [modes](docs/modes.md#spectating)
- A death's fall is the server's (`G2GCombat.decide_death`), sent as DEATH, undone by ALIVE; every `DotDamage` carries `tick`. [modes](docs/modes.md#a-dead-player-falls)

## Not here yet

The open gaps, each with its reason, are in [docs/README.md](docs/README.md#not-here-yet).
