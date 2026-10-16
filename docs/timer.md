# The timer, records and runs

dot-timer decides; this game acts, files and shows. The rules here are about what counts as a time.

## What taints a run

Taint is dot-timer's own "assisted" mark (`DotTimerRun.tainted`): the run still finishes and shows, and `can_record` refuses to file it. Taint rather than refusal, and at the start rather than at the end, because a run you cannot compare is still worth doing, and a run tainted on *finishing* is one a player made believing it counted.

| What | Effect on the run |
| --- | --- |
| An admin's noclip | Abandons the run it interrupts. `G2GPlayer._on_simulated` taints any run while noclip is on, **every tick**, because a noclipped player can fly into a start zone and out again and begin a new one. |
| An admin's speed or gravity step | Taints, every tick, the same way. |
| An admin's teleport | Ends the run, like every teleport here. |
| Freeze, blind | **Not** a taint: they can only cost a runner time. |
| Beacon | Not a taint: nothing the movement can feel. |
| A movement effect under `allow_movement_during_runs` | Taints (see [movement.md](movement.md#a-movement-effect-is-a-style-and-a-style-you-did-not-choose-is-a-record-you-did-not-set)). |
| A practice block placed while `only_practice` is on | The run cannot be ranked (see [modes.md](modes.md#practice-blocks-are-frozen-and-they-cost-you-the-record)). |
| A peer-to-peer session (`G2GParty`) | **Tainted the moment it starts.** A peer-to-peer host is a player's own machine and holds the tick rate, the zone crossings, the sub-tick fractions and the map, which between them *are* a time; a host could file a world record by editing a number. Migration is off: a time made of two machines' clocks is worse than none. |

**No admin tool can help a run.** That is the product's first rule about dot-moderation's live tools; `dedicated`'s live-tools section asserts it.

## The record's ghost is a player

The server record's replay runs the map as a `G2GPlayer` with `replay` set and no timer. It draws through the same rig, replicates through the same bridge (a client, browser included, sees the run without decoding a replay), and counts as a bot in the server query.

- `sv_replay_bot` turns it on and off live; off takes the ghost away now. `g2g_ghost` says whose record is running.
- `G2GReplays` keeps the fastest replay per map, track and style, in memory and on disk beside the records, in `DotTimerReplay`'s own format, so a replay set at 64 Hz plays on a 128 Hz server. **A replay is kept only with an accepted record**, never with a merely faster run: an assisted or tainted run must not become the ghost everybody chases.
- The bridge adopts any player the game made itself (`player_added`) as an entity with no peer, and `ensure_game_ticked` applies received commands **only to players that have a peer**: an empty command applied on top of a replay stands the ghost still.
- The ghost is not armed, not a voter (`G2GVote._player_count` excludes it, or a one-player server passes a quorum of two), not a session, and not on the online board.
- Drawing ghosts of *other* runs (replay playback) is a game's own decision and is not here.

## Stages, restarts and R

- `!r`, `!wr`, `!top`, `!style`, `!track`, `!rtv`, `!s <n>` / `!stage <n>` and `!rs` are chat triggers as well as console commands, because twenty years of bhop servers taught everybody's fingers those. Stage commands go through `DotTimerManager.request_stage`, which stops the run, and `G2GGame._on_stage_requested` moves the player to the stage zone's destination and yaw.
- **Every stage zone carries a `destination`** (`G2GMap.zone_stage`). One drawn without it resolves to `Vector3.ZERO`: a point in the sky over the start, reached with no error.
- **A stage with nowhere to stand is a split, not a restart.** A zones file can mark a stage `"restart": false` with a required `"restart_why"`; `G2GGame.request_stage` refuses it (`CODE_UNSUPPORTED`, the reason in the message) **before** the timer stops the run, and `!rs` from inside it goes back to the nearest earlier stage that has a start.
- **R once is the stage, R twice is the start.** `G2GGame.restart(id, mode)` is one place for the offline client and the server: `RESTART_STAGE` is `restart_stage` when a run is past its first stage line on a staged track, else the track's start (so a bonus's R is the bonus start); `RESTART_MAIN` goes to the main track's start from anywhere. Both stop spectating. The client acts on the first press at once and widens it if a second lands within `DOUBLE_TAP_MSEC` (350), because waiting to see would put a third of a second in front of the most-pressed key. `Ask.RESTART` carries the mode; an empty body (an older client) reads as `RESTART_TRACK`.

## Records, standings and the site

- **Records are keyed by the account, not the connection.** The in-match id stays `u<userid>`, but dot-server's userid is a sequential counter that restarts with the server, so keying records by it split one player into several runners and handed a new player an old record. `G2GModule._record_key_for` gives `session.uid()` (a guest has a per-device guest uid), `G2GGame.record_key(id)` and `match_id(key)` translate at the boundary, and the timer store, boards, stats, replays, ranks, points and backbone reports all use the account uid. A display name is never a key. A seat with no identity, or a second concurrent connection of one account, keeps `u<N>` and is unranked. **Legacy `u<N>` rows are retired, not deleted**: they never reach a board or rank, and `retire_legacy_records()` (run at start when authoritative) appends them to `legacy_records.jsonl` beside the records store (or in `user://`) and then wipes them from the store. Nothing can say which account owned a `u<N>` row, so they cannot be migrated.
- **A database is optional and reached by path.** `G2GConfig.records_database` (`sqlite`, `postgres`, `mysql`) makes `_build_timers` hand the timer manager a `DotTimerStoreSql` before it enters the tree, opened in `_ready` before the first map. dot-sql is loaded as `res://addons/dot_sql/core/dot_sql.gd` and never named: this game ships as a pack and parses against whatever addons the host build carries. A database that will not open is an ERROR and a session on files, not a server that will not start. `records_database_token` is in `sensitive_keys`.
- **Points come from the timer store's own total** (re-scored when a record moves) and are submitted to the `points` board in `_on_timer_filed`. Adding each accepted record's points to a running stat counted a map once per improvement.
- **The leaderboard boards' `publish` follows `report_to_backbone`**; an unpublished board is skipped by the reporter, which is how nothing once reached the site.
- **`G2GGame.standing_changed`** (`{pb, wr, rank, total}`, on every spawn, style change and filing) drives the HUD's standing line and `DotTimerHud.set_comparisons`. On a client it arrives as the `STANDING` event, because a client has no store.
- **What a finish says** is `G2GGame.announced`: a new record to everybody (`RECORD`), a personal best or a miss to the finisher, a refused run with the place it would have taken.
- **The commands are phrasing only.** `!pb`, `!rank`, `!players`, `!rr`, `!profile`, `!mapsdone`, `!mapsleft`, `!wrcp`, `!prinfo`, `!tier`, `!end`, `!pause`, `!unpause`, `!autorestart`, `!restore` and the admin `g2g_settier`, `g2g_rescore`, `g2g_deleterecord`, `g2g_wipeplayer` call dot-timer's manager and store, so two games' `!rank` cannot disagree about what a rank is.

## Statistics are read, not counted a second time

`DotFpsStats` counts jumps, perfect jumps, strafes and top speed on every controller, and dot-timer counts runs and records. `G2GProgress` reads those and files the **difference**; it measures exactly one thing itself, distance.

- **The difference is not optional.** `G2GGame._on_player_finished` calls `controller.stats.reset()` on every finish, so filing totals would file the whole history on every sample. A total that went *down* is a reset, and the whole new value is filed (the rule `DotAchievementStatsLink` applies one layer up).
- **A best time is `LOWEST`**, or every personal best is zero: dot-stats' `merge` distinguishes "held zero" from "never seen". The `Under Thirty` achievement also requires a finished run, because a missing stat reads as zero and "at most 30" is satisfied by never having played.

## Replicating a run

Timers replicate as run identities, not per tick: `DotTimerNet.RunState` carries the start tick and the sub-tick fractions, and the client's clock counts between packets. A finish carries ticks and fractions and the client reproduces the server's arithmetic to the digit (`headless_net` compares at 1e-4 s). The client counts at the **server's** tick rate (see [netcode.md](netcode.md#the-client-counts-at-the-servers-tick-rate)). dot-timer's rate/engine mismatch warning is guarded on `authoritative`: a mirroring timer counts at the rate it was told precisely so a run set at 128 is comparable on a client rendering at 60.
