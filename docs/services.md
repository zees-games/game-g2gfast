# Services: moderation, chat, voice, the vote, the browser, identity

`G2GServices` builds dot-chat, dot-voice and dot-moderation on a dedicated server; `G2GIdentity` joins dot-cloud, dot-auth, dot-user and dot-platform; `G2GVote` is dot-vote over the map catalogue; `G2GBrowser` is dot-browser's client half; `G2GQuery` is what a browser is told. The rule each was added under: **a player who came to run must not be stopped by anything added for a player who came to do something else.**

## An admin's live tools

dot-moderation's live tools are here (`G2GModTools`, built in `G2GServices`, commands on the module). **No admin tool can help a run**: the taint rules are in [timer.md](timer.md#what-taints-a-run).

- **Health, weapons and god mode exist only while `sv_deathmatch` is on**, so god, buddha, hp, slay, give and strip answer "not running its deathmatch" rather than being absent: whether they mean anything is a cvar, not a build.
- **Blind and beacon are two replicated flags** (`G2GPlayer.blinded`, `G2GPlayer.beacon`, in `G2GPlayerNet` after the movement specs). **`net_blind` is owner-only**: nobody else's screen changes, and an opponent on the deathmatch layer who could read it would know when to go and find somebody. `net_beacon` goes to everybody. State rather than an event, so a joiner, a lost snapshot and a map change are corrected by the next snapshot. `DotFxBeacon` (dot-fx, ping off: the game plays its own through dot-audio) is a ring and a once-a-second ripple sized to this game's 32-unit hull, and a column through walls the beaconed player's own camera does not draw.
- Three differences from game-arena's version, on purpose: **neither taints a run**; **nothing re-applies them on a respawn**, because a respawn here is `G2GGame.spawn_player`, a teleport of the same node, so the flags stay (this game never calls `DotModTools.respawned`, so adding them to `persist_on_respawn` would be a setting nothing reads); and **a beacon changes no relevance**. Every player entity is already `always_relevant` (`G2GNetBridge._build_entity`); arena's `always_relevant = beacon` here would CUT every runner the moment their beacon went off.

## Chat is the policy; dot-server stays the transport

`G2GServices` hooks `player_chat` and **cancels** it, routes the text through `DotChatRouter`, and hands each recipient's line back to dot-server's manager for the wire. Exactly one of the two delivers a line. On the client a line arrives on `DotClientLink.chat_received` and `G2GClientExtras.receive_line` feeds `DotChatClient`.

- **It hooks `player_command` as well.** dot-server's chat manager checks for a command prefix before it fires `player_chat`, and its prefixes are `["!", "/"]`, the same as `DotChatRules`', so without the hook no `!` line reaches the router: `!spec` once did nothing at all. A new `!` command must be handled by the router path or be a console command registered `.with_chat()`.
- **The `running` channel** is everybody mid-run: a `MEMBERS` channel whose rule ("their timer is going") only this game knows, which is why dot-chat asks rather than deciding. The team key falls back to it, because a timer server has no teams.
- **dot-moderation is built first, and the order is load-bearing.** It publishes `dot_mute_source` on `_ready` and both routers look that name up when they start; a router that started first enforces no gag for the life of the server.
- **`g2g_map` carries `CHANGEMAP` and is reachable from chat.** The permission flag is what answers, not chat being disabled for the command: a chat block runs before the permission check and never asks who is typing, so it only ever stopped the operator who holds the flag. `sv_chat_commands 0` turns chat commands off server-wide, and `allow_chat_change = false` on the dot-map block turns off the map change alone.

## Voice

**Voice rides its own channel on the link.** A talk spurt is fifty frames a second per speaker relayed to every listener; on the state channel it would queue with the snapshots, and on a server where a run is counted in ticks, latency must not depend on whether anybody is talking. **The speaker id is stamped from the transport's sender, never read from the payload.** The two voice calls are declared `unreliable`: a lost frame is 20 ms a jitter buffer conceals, and a resent one arrives after its neighbours played. What that becomes on the wire is the transport's decision (UDP on ENet, reliable TCP on a browser's WebSocket); the game names no transport.

The default voice channel is **ALL**, the opposite of game-arena's, and both are right: an arena is a room, and a course is long and thin with half the server two hundred metres away.

## The vote

`G2GVote` is the ballot a records community runs: nominations with caps and seconding, an instant runoff (so a six-option vote is not won by a fifth of the server), a cooldown, and an **extend** option, because a player two stages into a run they have been learning for an hour should not lose the map to a clock.

- **One rock-the-vote.** `G2GVote.install_commands` puts `DotVoteCommands` on the module (`vote` keeps its name so `!vote 2` works); `g2g_rtv` and a client's `Ask.RTV` (`G2GNetBridge.rtv_fn`) go to the ballot. The chat handler claims `!rtv` and `!vote` only when the vote failed to load. Without a vote, `rtv` is the map session's tally, which is then the only one.
- **`begin_on_apply` is off.** The map session's own `changed` is the one signal that says what is running (it fires for an admin's `g2g_map` too); both firing means two play-history entries for one play.
- **The map session's clock does not end a map when there is a vote** (`G2GGame.rotation_ends_maps` off once the module has a ballot); otherwise a map voted to extend was ended on the old clock.
- **Every screen's time left is the vote's clock.** `G2GVote.advance` keeps a `DotVoteClockView` of what clients believe and emits `clock_due` only when it is stale (an extend, a new map, a clock stopped for a ballot), so a quiet map sends nothing; the module sends it as `CLOCK`, and a joiner is told in `_admit` (`G2GNetBridge.clock_fn`). `g2g_status` reads it through `G2GGame.clock_fn = vote.clock_state` (`time_left_text()`: `m:ss`, `(stopped)`, or `no limit` in words, because a status line is read when somebody asks and a missing row reads as a diagnostic that forgot). A server with no vote keeps the session's.
- **The vote's cues reach the client** (`cue_due`, sent as `VOTE`), on voices the run does not use and below the timer's sounds. No countdown before a ballot: a runner is not in a fight.
- **The ballot is drawn by the client shell**: the module points the ballot feed's `ballot_fn` at `server.send_notice`, one copy per playing session with that voter as `you`, topic `map_ballot`; a click comes back as the same command a player could type. Standalone, chat carries the ballot.
- A timer server has no rounds and no leading score: `time_up` changes on time either way, and nothing calls `note_score`.

## The server browser, from the other end

`G2GQuery` contributes the map, tick rate, styles and world record; `G2GBrowser` is dot-browser's client half (list model, three protocols, filters, favourites, history), and `dedicated` has a real browser ask a real `DotServer` over a real UDP socket.

- **The map is not `entry.map`**: that is dot-server's `info.map`, the content id of the loaded game. A game's own section is under `rules["game"]` precisely so a field called `map` there cannot overwrite it.
- **JSON has one number type**: `tick_rate` comes back as a float; `game_number` is the accessor, and `wr` (a dictionary) has a third.
- **The list is a chat command** (`!servers`, or F3), because that is what this genre's fingers do and this client has a HUD rather than a screen stack. game-arena has the screen.

## Identity and platform

dot-platform's module holds each authenticated player in dot-server's PROFILE signon stage while the hub admits them, so a player is normally seated already resolved. Admission can still finish after the spawn (an optional player let in after `admission_timeout_sec`, or a session the module first hears of past the stage), so `G2GModule._avatar_for` falls through to `G2GIdentity.avatar_for`, which falls through to the stock document. dot-platform `docs/design.md` has the stage.

## Statistics and achievements

`G2GStats` declares every per-player number once; `G2GAwards` are achievements as rules over those ids; `G2GProgress` joins them to the runs. How they are counted is in [timer.md](timer.md#statistics-are-read-not-counted-a-second-time). `!stats` is the door to the derived figures.
