# Layers over the timer: deathmatch, hunters, blocks, effects, spectating

None of these is a mode. Each is a layer that **takes nothing away**: the timer still runs, and a player who ignores the layer plays exactly the game they played before.

## Deathmatch is a layer

`sv_deathmatch` adds hitboxes, health, an arsenal and a scoreboard (`G2GCombat`: dot-combat + dot-loadout + dot-match; `G2GArsenal`: the weapons, items and match rules). Surf and bhop communities have run deathmatch on their own maps for twenty years because a map whose movement everybody has learned is a map where a fight is about movement.

- **The genre's weapons, not an arena's**: a one-shot pistol and a knife, hitscan, **no magazine and no reload**. Reloading takes a hand off the strafe keys, and on a surf map that is falling. The rate of fire is the cost instead; spread is wide when moving and tight when still, so the fastest player on the map is the hardest to hit and the worst shot.
- **Entity ids come from `DotEntityTable`**, not from the player id with the `u` taken off: a derived id is a formula with an inverse, and two spellings of one id format never meet. The `u` still comes off for the **userid** (a loadout's storage key and `session_by_userid` want the account number). `G2GCombat.entity_for` is `id_for_key` and `player_id_for` is `key_for_id`. A caller that hashed the name instead would get a stable, plausible number that is not the one health, hitboxes and the kill feed use.
- **The match carries no time limit.** The map's clock (dot-vote's) ends the map; a second clock would be two authorities over one question.
- **The ghost is not armed.**
- **Every weapon row is written in 128 Hz ticks and says so** (`authored_tick_rate = G2GArsenal.TICK_RATE`). dot-weapon then scales each count to the running rate, so a server set to `sv_tickrate 64` fires, deploys and recovers bloom in the same real time. Left at 0 (the field's default, "use as written") the deagle fired at half its rate on such a server. `dedicated` drives both rates and compares the shot times in seconds; dot-weapon's `docs/design.md` has the reasoning.
- **`G2GArsenal.weapon_table` is the join** between dot-loadout (which has never heard of a `DotWeapon`) and dot-combat (which has never heard of a `DotItem`). Without it the loadout manager was a manager of nothing.
- **Spawn points move with the map**: `G2GCombat._on_map_ready` must replace the previous map's points (dot-match has no `remove_spawn_point`; calling it aborted the handler before the new points went in). `dedicated` changes map twice with combat up.
- **The weapon in hand is named bottom right, with no count** (dot-ui's `DotAmmoCounter`, `G2GHud.show_weapon`): neither weapon has a magazine and both reserves are endless, so a number would never move. A client has no combat layer to ask, so `G2GCombat._note_held` writes `G2GPlayer.held_weapon` on the authority and `G2GPlayerNet.net_weapon` sends it to the owner alone, as `G2GArsenal.WIRE_IDS` numbers it (appended only; 0 is empty hands). Empty with `sv_deathmatch 0`, and while watching somebody else. Offline in `headless_presentation`, over the link in `headless_net`, drawn in `screenshot_hud`'s `hud_hit`.

## A deathmatch ends with the last kill, the winner and the board

When a deathmatch reaches its score limit every client plays, in order, the final killcam, the winner reveal and the board. `G2GKillcam` (`game/g2g_killcam.gd`) puts every drawn frame of every runner and every kill into dot-replay's `DotKillcamBuffer` (no new traffic for the frames; a `KILL` event carries killer, victim, weapon and head, `MATCH_END` the killcam's seconds and the top three rows) and replays the last kill from the killer's eye. Then dot-ui's `DotWinnerReveal` names the winner over a podium of three, and the board opens for a few seconds. Both skip on jump or Escape, and a respawn or a map change skips whatever is still up. `mp_killcam_time` (0 off, default 7) is added to the match's end on the authority (`G2GCombat.apply_killcam_wait`), so the server never waits on a client; the player setting `reduce_motion` (Gameplay, Comfort) shows the reveal's last frame at once. A pure timer server has no match and nothing of this. Look at it with `tools/render_killcam.sh [--reduce-motion]`.

- **The match's end is sent deferred**, on the server and offline: the last kill ends the match from inside its own report, before the kill is broadcast or noted, and a killcam with no kill plays nothing.

## The trigger is one tick's input

A shot happens on a tick and has to be replayed with that tick's movement, so the fire command is **a bit on `G2GNetCommand`**, not a request (a separately delivered trigger would be replayed against a different tick's position every time). It is applied in `_net_apply_input`, the one place that runs on a replay as well as a fresh tick.

- **Not retained across a lost packet**, unlike movement: a held trigger that survives a hiccup is a weapon that empties itself during one. dot-net skips `_net_apply_input` for a tick whose packet never arrived, so `G2GCombat.tick` reads the meta with `has_meta` and **consumes it on read**; `previous` is left alone on a starved tick so a trigger really held across the gap is not a fresh press.
- **Never `get_meta(key, null)`**: a null default is the engine's *no default*, and every armed player without a command was an engine ERROR every tick on a suite that reported 0 failed.

## A timer map is a critical path, so the hunters have no navigation graph

`G2GHunters` (dot-npc + dot-npc-ai + dot-npc-ai-director). A hunter cannot catch a runner who is running well (the fastest does 8 m/s; a good bhop line does forty). What a hunter punishes is **stopping**, which the timer already punishes, made visible. Being chased costs the record (see [movement.md](movement.md#a-movement-effect-is-a-style-and-a-style-you-did-not-choose-is-a-record-you-did-not-set)), which is what makes hunters interesting rather than annoying.

`DotNpcDirectorFlow` is "the map's own critical path" as something a position can be measured along, and a timer map *is* one: start, stage lines, end. The route is built from the map's own zones, the director spawns **ahead** along it, and a hunter with nothing to chase patrols it. **`require_navigable_spawn` is off, and must be**: there is no graph, so the requirement would refuse every spawn. `g2g_hunt spawn` is the admin door. Replication is in [netcode.md](netcode.md#hunters-reach-a-connected-client).

## Practice blocks are frozen, and they cost you the record

`G2GProps` (`sv_props`). What a records community places is a practice line, a temporary block on the section everybody fails, a marker at the spot people keep asking about. All want to stay where they were put, so a prop is spawned **frozen**, the opposite of a sandbox's default (and why `g2g_prop_body.gd` has `starts_frozen`). Sizes are 32, 64 and 128 units, the genre's grid.

**`only_practice` is on, and it is what makes the feature safe to ship**: a board with one time set over a placed block is a board nobody trusts, and trusting an admin to clear up is a rule enforced by memory. Admin-only by default. **A grab is once and a held prop moves every tick**: a layer that calls `grab` without `hold` leaves the block where it was picked up. `g2g_nudge` is the admin door to the physics gun. This is not a sandbox; game-playground is.

**No toys from dot-props' catalogue, by decision (2026-10-13).** Toys belong in a hub people stand around in, and this game has none: a session is timed runs on imported maps. A toy fixed on a course would be part of the route (something to bounce off is a line through a stage, and a stage nobody else's record used), and a loose set dropped at each imported map's spawn is clutter in the one place every run starts. The practice blocks above are the only props, and they cost the record.

## Effects

`G2GEffects` splits combat effects (anybody, any time) from movement effects (refused during a ranked run unless `allow_movement_during_runs`, which taints): see [movement.md](movement.md#a-movement-effect-is-a-style-and-a-style-you-did-not-choose-is-a-record-you-did-not-set).

## A dead player falls

A player killed in deathmatch, by a hunter, or by an admin's slay falls as dot-player-char's ragdoll (its [docs/ragdolls.md](../../dot-player-char/docs/ragdolls.md) has the reasoning) and the rig stays hidden until dot-match puts them back at a start.

- **The server picks the fall.** `G2GCombat._on_entity_killed` calls `decide_death` (the reaction rule over `sv_ragdoll_reactions`, seeded from the victim's entity and the tick, the killing weapon's def) and puts it on `G2GPlayer.death` before `player_killed`. The bridge sends it to everybody as **DEATH** (victim, then the fall, last and optional) and the return as **ALIVE**; a solo client reads the same two signals off its own combat layer. Before this nothing connected `player_killed`: a dead runner stood upright on every screen until the respawn teleported them.
- **A hunter's swipe pushes away from the hunter**: `hunter_attack` sets the damage's direction, because world damage has no attacker to measure from.
- **The swipe carries the tick, and so does every `DotDamage` made here.** It did not, and `DotHealth` compares a damage's tick with the end of spawn protection (tick 0 is inside every one), so a runner who had been respawned once (every round start) could never be hurt by a hunter again. `dedicated` checks a hunter's kill.
- **The `sv_ragdoll*` cvars are the module's, REPLICATED**, and a connected client follows them: the client is what draws the body.
- **No ragdoll of your own body in first person**: the copy would start with the camera inside its head. In third person you see yourself fall.

## Spectating

**On a timer server spectating is the point**, not a consolation for being dead: a record is set by one person, once, and everybody else wants to watch. `G2GSpectate` over dot-spectate.

- **`force_camera` is 0**: there are no sides, so "your own team" means everybody. It tightens to 1 the moment `sv_deathmatch` is on, where a living player watching a living one is a free wallhack.
- **`allow_while_alive` is on**: somebody in the start zone deciding whether to run is not dead.
- **`!spec` with no argument watches whoever is furthest into a run**, not the fastest: "who is nearly finished" is the question a spectator asks. `!spec <name>` matches the whole name, then a prefix, then anywhere.
- **A client builds a mirror** (`DotSpectatorManager.authoritative` follows the game's), and the bridge watches the server's manager and sends **SPECTATE** (target key, mode, name) to the viewer; the camera follows from poses the client already draws, once a **frame**. A viewer with nobody to watch is stopped, not parked. `Ask.SPECTATE` carries left click (previous), right click (next), stop and best. While spectating the sampler is suspended.
- **Who is watching you is `sv_spec_list`, gated on the server**: SPECTATORS (up to 32 names) goes to the watched player and their watchers when it changes; `sv_spec_list 0` sends every list empty once and then nothing, so a modified client cannot draw what was never sent. `show_spectators` hides it locally.
- **Free roam is on by default and follows the family cvars** (`mp_freeroam`, `mp_freeroam_speed`, `mp_forcecamera`, bound by the module with `rules.bind_cvars` and mirrored on the client with `rules.follow_cvars`). The key (G, `g2g_roam`) or `!spec free` sends SPECTATE_ROAM; the server runs `toggle_roam` and the ordinary SPECTATE event carries mode ROAMING with an empty target (the bridge's "no target means stop watching" rule exempts it). The client flies `DotSpectatorFreeCam` once a frame from the camera as it was, never moving the body, and the server holds only the mode. The deathmatch layer does not tighten roaming itself (a hard-coded rule would be overwritten by the cvar default); it keeps `allow_while_alive` false, so only the dead can roam, and `mp_forcecamera 1` holds them to their side.
