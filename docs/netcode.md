# Netcode: the bridge, the tick rate and what a client draws

`game/net/` joins a `G2GGame` to a `DotNetManager`. `G2GNetBridge`'s ordering is the file; `G2GNetLink` is the `@rpc` surface and is identical on both ends (never edit one end); `G2GEvents` holds every event and request body.

## The movement configuration travels, not the tunables

`G2GNetBridge` sends a joining client the server's `G2GConfig.MOVEMENT_FIELDS` and both ends derive `DotFpsTunables` through the same `G2GMovement.tunables_for`. Sending the tunables would be one more representation that can drift, and prediction only converges when both ends simulate with identical numbers. The server fingerprints what it derived and the client compares; a mismatch is one log line rather than "the netcode feels bad".

**`G2GConfig.snap_movement()` runs before anything is derived**: the wire carries float32, and a server simulating with the doubles it read from a file while its clients use what they received differs in the last bit, silently. The values are rounded once, on the server.

## How a tick runs on both ends

- **The tick is a whole-game property.** dot-net simulates per entity; here everybody moves and then every timer is fed the position its move produced. The first behaviour through on a tick runs the whole game (`ensure_game_ticked`); the rest find it done. The client's `client_tick` does the same for what it predicts and then feeds every timer (`G2GGame.tick_timers_only`), so a remote player's clock on your HUD advances with theirs.
- **Received commands apply only to players that have a peer.** A bot or the ghost is driven by something else.
- **Bots are session ids without a peer.** Peer 0 is dot-net's broadcast address; `remove_player` handles both and `remove_peer` delegates.
- **A peer receives nothing until it says READY.** dot-server's signon finishes and *then* the client builds its scene; a HELLO sent in between lands on nothing.
- **A player's avatar** comes from dot-platform's admission (`G2GModule._avatar_for`, duck-typed through the `platform` module, falling through to `G2GIdentity`'s hub), else from what the client publishes, else the stock one; every one goes through `G2GRig.dress`, which conforms it to the server's schema.

## The client counts at the server's tick rate

`G2GGame._resolve_tick_rate` takes `Engine.physics_ticks_per_second`: on a server that is `sv_tickrate`, on a client whatever the host project exported (128 here, **60 in a client shell that never sets one**). Three things are derived from it: the step prediction replays with, the divisor every replicated run time is reconstituted through, and `DotNetClock`'s rate. A client at 60 against a 128 server never converged and read every finish 128/60 too long.

`G2GNetBridge._adopt_tick_rate` applies HELLO's `tick_rate` before `sync_from_server`, and **moves every copy together**: `G2GGame.set_tick_rate` (which takes the timer manager with it and reads the rate back), `net.config.tick_rate`, `net.clock.tick_rate` (a copy taken at `setup()` that writing the config does not touch), **and `Engine.physics_ticks_per_second`** (see below). `headless_net` puts its client on 60 deliberately: both halves share one process and one engine rate, so a suite at one rate passes with the chain disconnected.

## The client draws between ticks, and the engine runs at the server's rate

A 60 Hz engine against a 128-tick server runs the right ticks in bursts of two and three, and drawing `controller.state` directly moved the camera 74 mm on six frames out of seven and 112 mm on the seventh: a 47% change in apparent speed, eight times a second. Two halves fix it, and **either one alone measures as no better than nothing**:

- `G2GPlayer.present` draws `DotFpsController.render_state`, which interpolates between the last two ticks (dot-player-controller once guarded it to `Drive.LOCAL`, the one drive no networked game uses).
- The engine's physics rate is the server's tick rate, because the fraction a renderer interpolates at is a fraction through a *physics frame*, which is only a fraction through a tick while the two agree.

| | drawn at the last tick | drawn between ticks |
| --- | --- | --- |
| **engine 60** | 47% spread | 47% spread |
| **engine 128** | 47% spread | **0%** |

`examples/jitter_probe.tscn` runs all four and fails unless exactly the shipped one is smooth. The cost is a browser client stepping Godot's physics 128 times a second; the work inside the tick was already happening, and the engine's own step over static geometry is close to free. **Every other suite asserts simulated values**, which were all correct throughout; see the family's render-jitter notes.

## What a connected player sees

`examples/headless_feel.tscn` connects the real `G2GClient` to a real dual-stack `DotServer` running `G2GModule`, over ENet through dot-net's lossy UDP relay (or `-- --ws`, WebSocket through a TCP proxy that holds the stream on a lost segment), holds W, turns the mouse, and measures the frames at `Engine.max_fps` 60, 144 and 240. To measure honestly the harness polls the server's `MultiplayerAPI` once a physics frame (as a dedicated server at `max_fps = tickrate` hears its clients), and builds the client scene once the link is playing (a WebSocket peer has no unique id before its handshake, and a client built earlier registers its own player as somebody else's).

- **The view is drawn from the sampler once a frame.** At 144 Hz against 128 ticks some frames have no tick, so drawing the state's yaw stood the view still on one frame and turned it double on the next. `G2GClient._fold_look` calls `DotFpsSampler.look_now()` and hands it to `G2GPlayer.view_now`; commands are unchanged, because the sampler's angles are cumulative and the next tick carries exactly what was drawn. Called by name with the state's angles as fallback, so an older shell draws as before. **View angles are still not interpolated**: blending toward the last tick would add a tick of latency to aiming.
- **A prediction correction is eased, not jumped.** `G2GClient._fold_correction` hands `DotNetPredictor.visual_offset` (the part of a correction still to be eased) to `G2GPlayer.drawn_offset`, which present adds to the eye and the rig.
- **Remote runners** are drawn from dot-net's interpolation buffer, which is sized from how late snapshots actually arrive (dot-net's `docs/timelines.md`).
- **Not this game's to fix:** over WebSocket, TCP holds every command behind a lost segment, so under segment loss many commands arrive after their tick and corrections grow; the copies in each input packet are in the same stalled stream. Correction easing is what a browser player sees of it; the cure is the desktop client's UDP.

## The local player is adopted, not looked up

HELLO says who you are; JOIN (which calls `game.add_player`) creates you, afterwards. Resolving `game.players.get(id)` from `hello_received` got null one message too early and never tried again, which left mouse look and every key below the `player == null` guard dead while movement, the HUD and the camera all worked. `G2GClient` connects `G2GGame.player_added` before anything can create a player, keeps the id in `_watch_id`, and `_adopt`s it when it appears (also where the sampler is put on the player's tunables). `headless_net` asserts the ordering: the local player does **not** exist when HELLO names it, and `player_added` fires for it.

## Wire rules

- **An event or request kind is its index on the wire: append, never insert.** `G2GEvents.Kind` runs HELLO, JOIN, LEAVE, MOVEMENT, MAP, TIMER, FINISH, RECORD, NOTICE, VOTE, CLOCK, NPC, NPC_GONE, STANDING, RULES, MAPS, SPECTATE, SPECTATORS; a new one goes after the last.
- **No message script preloads itself.** A script that `extends DotNetMessage` and preloads itself, first loaded by a module inside a running `DotServer`, can leak the whole script graph at exit on Godot 4.7.2. `G2GEvent` and `G2GRequest` are built with `new(kind, body)`, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`. `dedicated`'s last section reads every `DotNetMessage` script under `game/` as text and fails on a self-preload: the leak is printed after `quit()`, where no assertion can reach.
- **The exit leak is still open and is not a self-preload.** `dedicated` still exits with leaked ObjectDB instances; every loaded script is in the graph that leaks, so any check that names a new type adds to the count, and untyping it would lower the number and fix nothing. The static caches (`G2GTextures._materials`, `_grid`, `_installed`, `G2GCombat._shared_catalogue`) are process-lifetime by design and left.
- **A JSON body is refused whole when too large, never cut** (RULES, MAP): `write_string` truncates, and half a JSON document loses whatever came last. RULES' command list is shortened from the end instead.
- **A fire command is a bit on `G2GNetCommand`, not a request** (see [modes.md](modes.md#the-trigger-is-one-ticks-input)).
- **Voice rides its own channel on the link** (see [services.md](services.md#voice)).

## Hunters reach a connected client

`G2GNetBridge._watch_hunters` gives each server hunter a `G2GNpcNet` (dot-npc's `DotNpcNetSync` fields: position, yaw, health, state), **interpolated, never predicted**, because a hunter comes out of a brain and a course line no client could reproduce; clients are told with `NPC` / `NPC_GONE`, and a joiner every live hunter in `_admit`. **Every hunter and every player entity is `always_relevant`**: a timer map is long and thin, and on the interest grid a hunter forty metres ahead is out of range at exactly the moment it matters. On a client the mirror is a drawn body with no brain, senses or collision.

## What a full server costs

`tools/load_probe.tscn -- <map> <counts...>` runs the real server half (`G2GGame`, `DotNetManager`, `G2GNetBridge`, the socket replaced by a counter) with N admitted players running and turning, timing every tick against the 7.8 ms budget at 128 (`LOAD_PHASES=1` breaks a snapshot into its steps). **`max_players: 32` at 128 ticks is not holdable**: the game alone is about 0.24 ms per player per tick, so 32 runners fill the budget before a byte is sent, and snapshots grow with the square of the player count (every peer is sent every player, with GDScript bookkeeping per property per peer). What would move it, in order: encode each entity's state once per snapshot and share the bytes between peers whose dirty set is the same; `sv_tickrate 64` on a big server; and the motor's per-player cost in dot-player-controller.
