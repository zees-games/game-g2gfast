# game-g2gfast

A bunny-hop and surf timer game in the competitive-shooter shape: the genre's
movement, its units, its cvars, a timer with zones an admin draws from the console, first and
third person, and every player drawn as an avatar.

Read the family-wide conventions in [`../../CLAUDE.md`](../../CLAUDE.md) first, and
each addon's own `CLAUDE.md` before working in it. This file is only about what this
game decides.

## What this game is, versus game-playground

game-playground is a sandbox that happens to have a surf ramp. This is the *timer
server*: the thing one of those communities would actually migrate to. Everything it
adds over the addons is one of four decisions, and the decisions are the file.


## An admin's help can never make a time

dot-moderation's live tools are here (`G2GModTools`, built in `G2GServices`, commands on the module), and on a timer server the first rule about them is the product's: **no admin tool can help a run.** Noclip abandons the run it interrupts; `G2GPlayer._on_simulated` taints any run while a noclip, a speed step or a gravity step is on the player — every tick, because a noclipped player can fly into a start zone and out again and begin a new run; an admin's teleport ends the run like every teleport here. Taint is dot-timer's own "assisted" mark, so the run still finishes and shows and `can_record` refuses to file it. Freeze is deliberately not a taint: it can only cost a runner time.

Health, weapons and god mode exist only while `sv_deathmatch` is on, so god, buddha, hp, slay, give and strip answer "not running its deathmatch" rather than being absent — whether they mean anything is a cvar, not a build. `dedicated`'s live-tools section asserts the timer half: abandoned, tainted, refused a record, clean once it is off, and tainted by a speed step too.

**Blind and beacon were refused as "no client overlay" until 2026-09-24, and are two flags now**, on game-arena's pattern (0e818b3). `G2GPlayer.blinded` and `G2GPlayer.beacon` are set by the handlers and replicated in `G2GPlayerNet` after the movement specs — `net_blind` **owner-only**, because nobody else's screen changes and an opponent on the deathmatch layer who could read it would know when to go and find somebody; `net_beacon` to everybody. State rather than an event, so a joiner, a lost snapshot and a map change are corrected by the next snapshot. `G2GHud.blind_overlay` fades a near-black rect in over a quarter of a second, **under** the clock and the keys and sized to the viewport rather than to the HUD; `G2GBeacon` is a ring and a once-a-second ripple at the drawn position, sized to this game's 32-unit hull rather than the arena's, and a column through walls that the beaconed player's own camera does not draw; each ripple is `beacon_pulsed`, which `G2GClient` plays as `G2GPresentation.BEACON_SOUND` — the BLIP an octave under `timer_start`, positional, on SFX, and below the landing and the jump in priority so a ping can never take a voice from the rhythm. Three things differ from the arena on purpose:

- **Neither taints a run.** A blind can only cost a runner time, like a freeze, and a beacon changes nothing the movement can feel. `dedicated` asserts a run made blind is not marked assisted.
- **Nothing re-applies them on a respawn, because nothing has to.** A respawn here is `G2GGame.spawn_player`, a teleport of the same node, so both flags simply stay — and this game never calls `DotModTools.respawned`, so adding them to `persist_on_respawn` would be a setting nothing reads.
- **A beacon changes no relevance.** Every player entity here is `always_relevant` already (`G2GNetBridge._build_entity`); copying the arena's `always_relevant = beacon` would CUT every runner the moment their beacon went off. `dedicated` and `headless_net` both assert it stays on, and both fired when the arena's line was put in (`headless_net` lost the ghost's replication with it).

`headless_net`'s **who is told** adds a second player owned by another peer, blinds and beacons both over one-in-five loss, and asserts this client is told its own blind and not the other's, and both beacons; armed by dropping `to_owner_only()`, two fired. `headless_presentation` asserts the overlay is the HUD's first child, fades, covers the viewport (armed by removing the sizing), and that a beacon pings once a second rather than once a frame. `tools/screenshot_hud.sh` renders `hud_beacon` and `hud_blind`.

## Layout

```
game/
  g2g_units.gd      genre units → metres. The ONLY place the ratio lives
  g2g_config.gd     every cvar, in genre units, layered like every DotConfig
  g2g_movement.gd   G2GConfig → DotFpsTunables. The only place units cross
  g2g_game.gd       the simulation: maps, timers, boards, players. Headless
  g2g_player.gd     controller + rig + camera + timer, joined
  g2g_rig.gd        the visible character: attachment nodes for the avatar slots
  g2g_avatars.gd    the stock schema, stock parts, and a player's own avatar
  g2g_camera.gd     first and third person, with the genre's field of view
  g2g_hud.gd        clock, keys, speed in u/s, PRACTICE, and an admin's blind
  g2g_beacon.gd     an admin's beacon: ring, ripple, a column through walls
  g2g_replays.gd    the best replay per map, track and style. What the ghost plays
  g2g_query.gd      what a server browser is told: map, tick rate, styles, the WR
  g2g_client.gd     one local player. Never loaded by a server
  g2g_module.gd     the DotServer bridge: sv_autobunnyhopping and friends, and
                    the netcode's owner on a dedicated server
  net/
    g2g_net_bridge.gd  joins a G2GGame to a DotNetManager. The ordering is the file
    g2g_player_net.gd  one player as a replicated entity; DotFpsNetSync's specs
    g2g_net_command.gd a DotFpsCommand as a DotNetInput
    g2g_net_link.gd    the @rpc surface, identical on both ends. Never edit one end
    g2g_events.gd      every event and request body, and the movement config's wire
    g2g_event.gd, g2g_request.gd  the two DotNetMessages: a kind and a body
  g2g_geometry.gd   boxes and ramps, in units
  g2g_map.gd        base for the built-in maps; a map declares its jumps here
  g2g_reach.gd      what a jump reaches, from the tunables; every declared jump, measured
  g2g_map_survey.gd slots, unreached ground and traps, swept over a hand-built map's boxes
  g2g_bsp_map.gd    base for an IMPORTED map: mesh, materials and zones from a
                    manifest. See Decision 11
  g2g_map_mechanics.gd  what an imported map's volumes DO, once a tick: pushes,
                    gravity, conveyors, sinking blocks per player, lethal hurt
  g2g_ladder_mode.gd    climbing, as a DotFpsMoveMode beside swimming
  g2g_map_rotation_file.gd  cfg/map_rotation.yml (yml/json/txt/cfg/ini): which maps rotate
  g2g_zone_outlines.gd  every zone drawn as a glowing box. Client only
  g2g_zone_editor.gd    Z: drawing zones by aiming, offline or as an admin
  g2g_bsp_lightmapped.gdshader  albedo x the lighting the map's own compiler baked
  g2g_bsp_translucent.gdshader  the same, plus the ALPHA write. 20 surfaces of 420
  g2g_lighting.gd   which DotLightProfile this machine gets. The rest is dot-lighting
  g2g_map_catalogue.gd  finds every map by looking. There is no list of maps
  g2g_stats.gd      every per-player number, declared once. See Decision 12
  g2g_awards.gd     achievements as rules over those ids
  g2g_progress.gd   dot-stats and dot-achievements, joined to the runs
  g2g_arsenal.gd    the deathmatch half's weapons, items and match rules
  g2g_combat.gd     dot-combat + dot-loadout + dot-match, as a layer over the timer
  g2g_hunters.gd    dot-npc + dot-npc-ai + dot-npc-ai-director, along the course
  g2g_props.gd      practice blocks, frozen, and what they cost a record
  g2g_vote.gd       dot-vote over the map catalogue. Replaces the rtv that was not one
  g2g_services.gd   dot-chat + dot-voice + dot-moderation, on a dedicated server
  g2g_identity.gd   dot-cloud + dot-auth + dot-user + dot-platform
  g2g_client_extras.gd  the client halves of chat and voice
  g2g_browser.gd    dot-browser's client half: !servers, and what a row says
  g2g_bindings.gd   every key the client reads, as one table (dot-menu's DotMenuBindings)
  g2g_flashlight.gd the player's own light, on shaded AND unshaded surfaces
  ui/
    g2g_menu_pages.gd  what is on the Escape menu: dot-menu's stock pages, rearranged
                    and reworded, and this game's rows. The menu itself is dot-menu's
npcs/               two hunters and the body they share
props/              three practice blocks, in the genre's 32/64/128 sizes
maps/               bhop_g2g_intro, bhop_g2g_stages, surf_g2g_intro, and their .zones.json
  imported_map.tscn THE scene every imported map uses. In the build; the maps are not
  imported/<id>/    what tools/bsp_import.py wrote: <id>.bin, <id>.json, the lightmap
                    atlas and the textures. Data only -- no scene, no script.
                    Derived; gitignored; never hand-edited
  zones/<id>.json   what a .bsp does NOT say about itself: which volume is the finish,
                    and why. Hand-written, checked in, merged at import. See
                    Decision 11 and maps/zones/README.md
avatars/            six stock parts and the tint shader
textures/prototype/ the installed prototype set: one PNG per G2GTextures.Role, CC0,
                    and what the IMPORTED maps draw in. See its README
scenes/
  g2g_server.tscn   what a dot-server loads. A G2GGame under a plain Node
  fx/               start_gate and finish_gate: particles, no script, nothing loaded
examples/           headless_run (219), headless_net (157), dedicated (180),
                    headless_imported (45 per map, plus one per track and stage),
                    headless_maps (64), headless_mechanics (5 sections per
                    imported map), jitter_probe (4 configurations)
tools/              export_zones.gd — run after changing a map
                    route_preview.gd/.tscn/.sh — render ONE TRACK of a hand-written
                    map from its own spawn, looking down it. bsp_preview orbits a
                    whole map, which on a map whose four routes span 5,800 units of
                    X makes every one of them a sliver
                    bsp_read.py, vtf.py, bsp_import.py — Source .bsp to a map
                    bsp_mechanics.py — what its brush entities do: water, pushes,
                    gravity, hurt, conveyors, ladders, sinking blocks.
                    docs/brush-entities.md is every class and its handling
                    bsp_props.py — static props (sprp, MDL/VVD/VTX, .phy) and
                    their light probes
                    import_maps.sh — import a whole directory of them, idempotently
                    bsp_preview.gd/.tscn/.sh — render an imported map and exit
                    route_bot.gd — a bot that follows maps/routes/<id>.json and
                    air-strafes; route_plan.py writes that file from collision.
                    stage_ride.tscn -- <id> 0 rides it; headless_imported asserts it
                    replay_follow.gd, follow_replay.tscn -- drive the real movement
                    along a recorded run (maps/routes/<id>.replay) and say where it
                    leaves the line; headless_imported asserts it
                    ramp_bump_probe.gd/.tscn — ride ramps with the real motor and
                    count the ticks a camera would see jump, by cause
                    collision_probe.gd/.tscn — drop the player's hull on every
                    standable triangle in an imported map and count what it goes
                    through. `--trimesh` builds the old collider for comparison
```

**There is no `[input]` block in `project.godot`, and that is deliberate.** There was
one — `player_forward`, `player_back`, `player_left`, `player_right`, `player_jump`,
`player_crouch` — and nothing read any of them: [DotFpsSampler] keys off its own
`actions` dictionary of `dot_fps_*` names and `register_default_actions` adds them to
the [InputMap] at runtime for a project that has none. Six actions declared once and
read nowhere, which is the family's own detector for a setting that does not exist.
Removing them rather than wiring them up is what makes this game's client work
**inside another project**: it now ships in dot-server-deploy's browser shell,
whose `project.godot` has no input actions at all, and a game that depended on its own
would have had no controls there.

The keys are `G2GBindings.ROWS` (a `DotMenuBindings` through `G2GBindings.make()`), applied at runtime from the settings document and rebindable in the Escape menu; the movement rows ARE the sampler's `dot_fps_*` actions, so there is still no second copy. Duck is **Ctrl**, not Shift — the README said Shift for as long as the dead block did, and neither was ever true.

## Where this game runs, besides here

`dot-server-deploy` vendors it: `setup.sh` copies `game/`, `scenes/`, `maps/` and
`avatars/` into that project, `content/g2gfast/game.yml` points at
`res://scenes/g2g_server.tscn` and `res://game/g2g_module.gd`, and the browser shell
maps content id `g2gfast` to `res://game/g2g.tscn`. That is the deployment shape — a
separate process, a real socket, a browser — and by this family's repeated lesson it is
where the bugs are. It found four; two of them are below and two were in other
repositories.

## Decision 1: everything the operator touches is in genre units

`sv_airaccelerate 1000`, `sv_gravity 800`, a run speed of 250 u/s, a surf ramp that is
"1024 wide at 60°". A bhop server operator knows what those mean and nobody knows what
19.05 m/s² is. So every cvar, every config field, every HUD number and every map file
speaks genre units, and **the conversion to the metres the simulation runs in happens
at exactly one boundary — `G2GMovement.tunables_for`** — with `G2GUnits` as the only
definition of the ratio. A conversion anywhere else is a second copy of the ratio, and
two copies drift.

The ratio is **1 unit = 0.01905 m** (0.75 inch), the scale the genre's maps were
built at, not the 1-inch
figure sometimes quoted. It is what the 72-unit hull, the 64-unit eye and every map in
the genre were built against; at the wrong scale a surf ramp is one the movement cannot
hold.

The jump is specified as a **launch velocity** (301.99 u/s) and converted to the height
the tunables want with `h = v²/2g` — 57 units under 800, the number every bhop player
knows — so it stays honest when an operator changes `sv_gravity`.

## Decision 2: auto-bhop is the server's, and the styles defer to it

`sv_autobunnyhopping` (`G2GConfig.auto_bhop`) is the setting this game exists to expose.
It reaches every player through `G2GGame.apply_movement`, which rebuilds the tunables
and hands them to everybody — **abandoning every run in progress**, because a run half on
one movement and half on another is a run on neither. Same rule as a tick-rate change.

**The shipped `DotFpsStyle.defaults()` force auto-hop ON**, which is right for a game
with no cvar and wrong here. The first version left them as shipped and
`sv_autobunnyhopping 0` reached every player's tunables and was then undone by the
style on top — silently. `_build_styles` now sets every style's `auto_hop` and
`easy_bhop` to `INHERIT`, except `prebhop`, whose whole identity is "no auto-hop".

**A movement cvar is validated before the config is written**, through the console's
own validator on a *copy* of the config. The first version wrote the field, validated,
and on failure returned — leaving the config invalid, after which every later cvar
wrote its field, found the config still invalid because of the first, and quietly did
nothing while the console reported them all as set.

### A thing that looked like a bug and is the genre's physics being faithful

A player holding jump from a standstill creeps at exactly 30 u/s — the air cap — for
ever. On the tick a jump fires the player is already airborne when acceleration runs,
so a held key never gets a ground-acceleration tick. Those games do precisely this
(`CheckJumpButton` runs before `WalkMove`), which is why every real bhop run begins with
a **prestrafe**. The headless suite's bot walks before it hops; an hour was spent
finding out why it had to.

## Decision 3: the genre's field of view, not Godot's

`fov_desired 90` is 90° **horizontal at 4:3**, and those games widen it on a wider
screen.
Godot's `Camera3D.fov` is vertical and fixed. `G2GUnits.source_fov_to_vertical`
converts through the 4:3 frame: 90 becomes 73.74° vertical, which on 16:9 shows 106.26°
horizontally — exactly what they show. Handing 90 straight to Godot gives 121° at
16:9 and a player who cannot aim and cannot say why. Tested to the hundredth of a
degree, with the naive number named so it stays a mistake.

`sensitivity` has its usual meaning too: degrees per count is `sensitivity × 0.022`, so a
player's 2.5 works unchanged.

**Third person is cosmetic.** `G2GCamera` keeps both cameras and flips `current`; the
first-person one culls the local rig's render layer so the player does not see the
inside of their own head, the third-person one sits on a `SpringArm3D` and draws
everything. The controller aims from the eye whichever is active.
`sv_allow_thirdperson 0` is server-side because third person sees over ledges first
person cannot, and it puts anybody already in it back.

**`show_own_body` is a third state, and it is not "first person with the cull off".** The
rig's three mounts are in two different places relative to the camera: the body mount is
40 cm below the eye and draws as a torso, arms and legs, while the head and hat mounts sit
*at* the eye — that is what they are for. So a switch that simply showed the whole rig
would put the camera inside a 40 cm cube and fill the view with one flat colour behind a
straight edge, which is exactly the artefact `G2GRig._set_layers_recursive` was written to
end and exactly what it looks like in a bug report. `G2GRig.owner_sees_head` is therefore
a second flag and the three states are *nothing* / *body only* / *everything*, settled in
one place in `G2GPlayer._apply_own_body`.

**The default is applied where the camera is built, not on the first frame that draws.**
`visible_to_owner` defaults to true because that is right for everybody else's rig, so the
local one was only ever *corrected*, once a frame, from `present()` — a `_process` body,
where a script error aborts the call and the game carries on. Any frame that did not
finish drew the player's own avatar at point-blank range. A default that has to be
corrected is not a default.

## Decision 4: one avatar schema, two sources of parts

`G2GAvatars.schema()` is a real `DotAvatarSchema` — body, head, hat — and the rig has one
attachment node per slot. **A stock character and a player's own avatar from the
platform are the same thing at different addresses**: the six stock parts ship in the
build under `res://avatars/`, a platform part names dot-cloud content, and
`DotAvatarBuilder` does not care which it got. A player with no avatar gets
`stock_avatar(id)`, a real document over the same schema, deterministic in the id so the
same player is the same colour on every machine.

`DotAvatarSchema.conform()` **edits the document in place** and returns what it changed.
`G2GAvatars.apply` runs it on a copy, or a server that could not draw one part would
quietly rewrite a player's own avatar. A part from a newer client is dropped, never
refused: a player is never invisible because their hat is from the future.

## The maps, and how they are textured

Three of them now: `bhop_g2g_intro`, `surf_g2g_intro` and `bhop_g2g_stages`, plus whatever has been imported.

**The default is an imported map, and not one of the three.** `G2GConfig.initial_map` is `surf_mesa`. A straight line of blocks over a flat plane is what a *suite* should run — and every example here still names one explicitly — but it is not what a player arriving at a server should be met by. It also makes the imported half the default path rather than the one nothing reaches unless somebody types a map name, which is this family's own rule about deployment shapes: a built-in map is a scene and a script and can never fail to be there, and an imported map is data at a path that has to be found, parsed and built.

**`bhop_g2g_stages` is the first one that is a map rather than a fixture.** The other
two are a straight line of blocks and a pair of ramps: they prove the movement and there
is one thing to do in each, once. It is the timer community's staged shape — five sections
with a line between each, one idea per section, so a player who fails knows which idea
they failed:

```
1  straight    blocks in a line, gaps growing.      Keep the speed.
2  the turn     the course bends 90 degrees.        Strafe through it.
3  the climb    blocks rising 24 units each.        Height costs speed.
4  the drop     a descent onto narrow blocks.       Do not overshoot.
5  the zigzag   blocks alternating left and right.  Both directions.
```

Everything is derived from `_course()`, which walks a position and a heading and returns
every block; the geometry and the zones both read that one list. On a map that *turns*
that is not a nicety — a hand-placed stage line on a course whose gaps somebody later
changes is a leaderboard nobody can compare, and nothing reports it: the run still
finishes, the splits are just taken somewhere else.

**And it had no finish, for as long as it has existed.** `_build` drew the finish pad 384 units along world -Z; `build_zones` placed the finish zone 384 units along the *course heading*, which the turn in stage 2 leaves at 90 degrees and every stage after it inherits. So the pad sits at -Z and the zone sits at -X, 543 units apart, overlapping by a 128 x 24 corner nothing lands on. A player ran the whole map, arrived on a pad drawn in the finish colour, stopped, and the timer counted on for ever. Nothing errored and nothing could: a run that has not finished is a legitimate thing for a run to be, and the pad was exactly where the geometry said to put it.

`_pad_centre()` answers "where is the finish" now and the geometry and the zone both call it — this map's own rule about `_course()`, applied to the one place that was still doing the arithmetic twice.

What let it survive is the more useful half. `headless_maps` asserted the zone set is well formed, `headless_run` asserted the sidecar matches, `headless_imported` drove a timer over the eight imported maps — **and every one of those checks is about the zones, not about the zones adding up to a run.** The check that says so has to cross from the zone set into the geometry, so it is a raycast: drop a ray down the middle of every START, END and STAGE volume and require it to land inside that volume. A zone hanging over nothing is a zone the run never reaches, and from inside the game it is indistinguishable from a map with no end zone in it. It fails on `bhop_g2g_stages` without the fix and passes with it.

The stale-list bug came along for the ride: `_test_zone_files_match` carried `["bhop_g2g_intro", "surf_g2g_intro"]` and there are three maps, so `bhop_g2g_stages` had never been checked against its own sidecar. The files happened to agree; the check was blind either way. It discovers now, which is what `tools/export_zones.gd` stopped carrying a list for.

Its bonus is a **surf** descent on a bhop map, deliberately. A bonus track is a whole
second route with its own records, and making it the same thing as the main route wastes
it; it is also the cheapest proof that a track is a route and not a game mode.

**Every stage zone carries a `destination`**, through `G2GMap.zone_stage`, because
dot-timer's `request_stage` hands the host the zone's destination and one drawn without
it resolves to `Vector3.ZERO` — a point in the sky over the start, reached with no error
at all.

**Surfaces are roles, not colours.** `G2GGeometry.box` used to take a `Color` and set a
flat `albedo_color`, so every surface in the game was one unbroken tone — which in this
genre is not cosmetic. A surf ramp is a plane ridden at 30 m/s and a bhop block is one
cleared in eight ticks, and both are judged by *how fast the surface is going past*; the
only cue for that is a repeating pattern with a known size. `G2GTextures` supplies one,
triplanar and in **world** space, so one square is 64 units — the grid this genre's maps
are built on — on every surface whatever its size. The old `COLOUR_*` constants are role
ids now and keep their names, so no map file changed.

## Decision 12: everything else this family ships, and the timer keeps running

This game had the timer, the movement, the maps and the boards. It now has the rest of
the family — twenty-six addons — and the rule every one of them was added under is the
same sentence:

> **A player who came to run must not be stopped by anything added for a player who
> came to do something else.**

That is not a slogan; it decides the shape of four of them.

```
game/
  g2g_stats.gd     every per-player number, declared once
  g2g_awards.gd    achievements as a document of rules over those ids
  g2g_progress.gd  the node joining the two to the game, and to nothing else
  g2g_arsenal.gd   two weapons, and why they are the genre's rather than an arena's
  g2g_combat.gd    dot-combat + dot-loadout + dot-match, as a LAYER
  g2g_hunters.gd   dot-npc + dot-npc-ai + dot-npc-ai-director, along the course
  g2g_props.gd     practice blocks, frozen, and what they do to a record
  g2g_vote.gd      dot-vote over the map catalogue
  g2g_services.gd  dot-chat + dot-voice + dot-moderation
  g2g_identity.gd  dot-cloud + dot-auth + dot-user + dot-platform
  g2g_client_extras.gd  the client halves of chat and voice
```

### Statistics are read, not counted a second time

`DotFpsStats` has counted jumps, perfect jumps, strafes and top speed on every
controller since dot-player-controller was written, and dot-timer counts runs and records.
`G2GProgress` reads those out and files the **difference**; it measures exactly one
thing itself, which is distance, because nothing else does.

**The difference is not optional and the reason is this game's own.**
`G2GGame._on_player_finished` calls `controller.stats.reset()` on every finish, so
filing the total on each sample would file the whole history on every sample and then
start again from nothing. A total that went *down* is a reset, and the whole new value
is filed rather than a negative one — the same rule `DotAchievementStatsLink` applies
one layer up, for the same reason.

**A best time is `LOWEST`, and getting that wrong is a personal best of zero for
everybody.** dot-stats' `merge` takes the incoming value whole when there is nothing
held, which is the distinction between "held zero" and "never seen"; `Under Thirty` is
the achievement that shows what happens without it, and it carries a second rule
requiring a finished run precisely because *a missing stat reads as zero and "at most
30" is satisfied by having never played*.

### Deathmatch is a layer, not a mode

`sv_deathmatch` adds hitboxes, health, an arsenal and a scoreboard and **takes nothing
away**: the timer still runs, and a player who never presses fire plays exactly the
game they played before. Surf and bhop communities have run deathmatch on their own
maps for twenty years and the reason is that a map whose movement everybody has learned
is a map where a fight is about movement.

The weapons are the genre's rather than an arena's, and that is the whole design: a
one-shot pistol and a knife, hitscan, **no magazine and no reload**. Reloading takes a
hand off the strafe keys, and every second a player spends not strafing on a surf map
is a second they spend falling. The rate of fire is the cost instead. Spread is wide
when moving and tight when still, so the fastest player on the map is the hardest to
hit and the worst shot.

Three things in the wiring that are not obvious:

- **Entity ids come from `DotEntityTable` and are not derived from anything.** They
  used to be the player's own id with the `u` taken off, which worked and taught the
  family why it should not: a derived id means a formula, a formula has an inverse, and
  two spellings of one id format are two ends of a serialisation that never meet. The
  `u` still comes off for the **userid** — a loadout's storage key and
  `session_by_userid` both want the account number, and neither wants a runtime handle.
  One function used to serve both, which was harmless while they were the same integer
  and would have been silent the day they stopped being.
- **The match carries no time limit.** The map's clock ends the map, and a second clock
  underneath it that ends the match is two authorities over one question — dot-vote's
  director already owns the first.
- **The ghost is not armed.** It is a replay: it cannot press a trigger, cannot be hurt
  in any way that means anything, and registering it would put a name on the scoreboard
  that never dies and never leaves.

### A timer map is a critical path, so the hunters have no navigation graph

A hunter cannot catch a runner who is running well — the fastest does 8 m/s and a bhop
player on a good line does forty. What a hunter punishes is **stopping**, which is what
the timer already punishes, made visible.

`DotNpcDirectorFlow` is literally "the map's own critical path" as a thing a position
can be measured along, and a timer map *is* one: start pad, stage lines, end zone. So
the route is built from the map's own zones — the same list `bhop_g2g_stages` derives
its geometry from — the director spawns **ahead** along it, and a hunter with nothing to
chase patrols it. The pathfinding a mesh would give is spent on a map whose route is
already known.

`require_navigable_spawn` is therefore **off**, and it has to be: there is no graph, so
a navigable-spawn requirement would refuse every spawn on the map.

### Blocks are frozen, and they cost you the record

What a records community actually places is a practice line, a temporary block on the
section everybody fails, and a marker at the spot people keep asking about. Every one
of those wants to stay where it was put, so a prop here is spawned **frozen** — the
opposite default from a sandbox's, and the reason `g2g_prop_body.gd` has a
`starts_frozen` export at all.

**`only_practice` is on, and it is what makes the feature safe to ship.** A board with
one time set over a placed block is a board nobody trusts, and the alternative —
trusting an admin to clear up — is a rule enforced by memory. The sizes are 32, 64 and
128 units, the grid this genre's maps are built on, converted at the one boundary
`G2GUnits` owns.

### The vote this game shipped with was not one

`G2GGame.rock_the_vote` forwards to `DotMapTimeLimit`, which counts votes against a
fraction and expires the map: a countdown and a tally. `G2GVote` is the ballot a
records community actually runs — nominations with caps and seconding, an instant
runoff so a six-option vote is not won by a fifth of the server, a cooldown, and an
**extend** option, because a player two stages into a run they have been learning for an
hour should not lose the map to a clock.

Two decisions in it:

- **`begin_on_apply` is off.** The map session's own `changed` is the one signal that
  says what is running, because it fires for an admin typing `g2g_map` as well. Both
  firing means two entries in the play history for one play, and a "not in the last
  five maps" cooldown that is quietly two or three.
- **The ghost is not a voter.** `_player_count` excludes it, because otherwise a
  one-player server passes a quorum of two and can rock the vote on its own.

### Chat is the policy; dot-server stays the transport

`G2GServices` hooks `player_chat` and **cancels** it, routes the text through
`DotChatRouter`, and hands each recipient's line back to dot-server's manager to put on
the wire. Exactly one of the two delivers a line, which is what stops them being two
chat systems.

The channel that is about this genre is `running`: everybody who is mid-run. It is a
`MEMBERS` channel and the membership rule — "their timer is going" — is a thing only
this game knows, which is exactly why dot-chat asks rather than deciding. The team key
falls back to it, because a timer server has no teams and a team message on one reaches
the single player whose team number matches.

**dot-moderation is built first, and the order is load-bearing.** It publishes
`dot_mute_source` on `_ready` and both routers look that name up when they start; a
router that started first would find nothing, warn once, and enforce no gag for the life
of the server. It is here at all because dot-server's mute is two booleans on a session
object and a session dies with its connection — on a records server that matters more
than usual, because a gag is how an admin stops somebody spamming `!wr` at everybody.

**Voice rides its own channel on the link.** A talk spurt is fifty frames a second per
speaker relayed to every listener; on the state channel it would sit in the same ordered
queue as the snapshots, so somebody holding the talk key would add a frame of latency to
everybody's movement — and on a server where a run is counted in ticks, latency must not
depend on whether anybody is talking. The speaker id is stamped from the transport's
sender and never read out of the payload.

Its default channel is **ALL**, which is the opposite of game-arena's, and both are
right: an arena is a room, and a course is long and thin with half the server two
hundred metres away.

**UDP on a desktop and TCP in a browser, and neither is chosen anywhere.** The two
voice calls are declared `unreliable`, which is what voice wants: a lost frame is 20 ms
of silence a jitter buffer conceals, and a resent one arrives after the frames either
side of it have already played. What that becomes on the wire is `DotTransportAuto`'s
decision, and it has one sensible answer either way — ENet honours the unreliable
channel as UDP, and a browser has no UDP at all, so WebSocket delivers it reliably and
in order over TCP whatever anybody asks for. The platform rule falls out rather than
being written, and neither game names a transport.

### The server browser, from the other end

`G2GQuery` has contributed the map, the tick rate, the styles and the world record
since the module was written, and **nothing had ever read any of it**. `G2GBrowser` is
dot-browser's client half: the list model, three protocols, local filters, favourites
and history — and `dedicated` now has a real browser ask a real `DotServer` over a real
UDP socket, which is the seam the family's notes name as untested.

Two things a reader of a query section gets wrong once, and both were got wrong here
first:

- **The map is not `entry.map`.** That is dot-server's `info.map`, which means "the
  content id of the loaded game" and is empty on a server that never switches games.
  dot-browser nests a game's own section under `rules["game"]` precisely so a game
  putting a field called `map` in it cannot overwrite the other one.
- **JSON has one number type.** `tick_rate` is contributed as an int and comes back as
  a float, so `game_field(entry, "tick_rate")` is `"100.0"`. `game_number` is the
  accessor; `wr` is a dictionary and has a third.

The list is a chat command rather than a screen — `!servers`, or F3 — because that is
what this genre's fingers already do, and because this client has a HUD and a keyboard
rather than a [DotScreenStack]. game-arena has the screen. The same addon does the same
work either way; where it is drawn is the half a game is supposed to decide.

## The menus, the keys and the flashlight (2026-10-08)

Escape opens a menu (General, Gameplay, Video, Audio, Controls), H a help screen, F a flashlight, O hides everybody else. `tools/screenshot_menus.sh [map] [yaw] [pitch]` renders the real offline client's every page, the help screen as a browser player on a server sees it, and the flashlight off and on from one view; it is how three of the bugs below were found.

**`G2GBindings.ROWS` is the one list of keys, and four things read it**: the client matches events against its actions, the settings schema declares a binding per row, the Controls page draws a key button per row, and the help screen lists each with the key it is on NOW. Before it the keys were a `match` on keycodes in `G2GClient` and a sentence in its doc comment. Bindings are DEVICE scope (a key is a fact about a keyboard) except the two chat keys, which were ACCOUNT before the table existed and keep it, because changing a stored setting's scope resets somebody's key. A binding that names nothing falls back to the default rather than unbinding, and binding a key that is taken SWAPS the two, so no action is ever left on nothing. Escape is in no row and cannot be bound: it is the menu, and it is how a browser releases the pointer.

**The flashlight has to light two kinds of surface, and the one people play on ignores lights.** Every imported map is `unshaded` (the baked lightmap is its lighting), so a `SpotLight3D` lit the hand-built maps and nothing on the maps that matter. Both BSP shaders compute the cone themselves from a 4 x 1 float texture `G2GFlashlight` rewrites each frame and sets as the SHADER's default for `flashlight_tex` — not per material (one write for every surface) and **not a `global uniform`, which has to be declared in the host project's settings or the shader does not compile**: this game is delivered into a client shell whose `project.godot` it does not own. `hint_default_black` means a server, a suite and an older pack draw exactly as before. A spotlight still lights the shaded half. It is client-only and never replicated; the server's say is `sv_flashlight`, which arrives in the RULES event.

**RULES** (`G2GEvents.Kind.RULES`, appended) carries `sv_flashlight`, `sv_allow_thirdperson` and the chat commands, as JSON, on admit and whenever either cvar changes. The command list is read off the server's console by `G2GModule.chat_commands` (public, chat-reachable, sorted), so the help screen is never a list somebody typed. A list too long for the cap is shortened from the end, never cut, because `write_string` truncates and half a JSON document loses the flags with the commands. `headless_net`'s *what a client may do on its own screen* round-trips it and sends both cvars over the link; armed by putting truncation back.

**The menu is a view of the settings, never a copy.** A switch reads `DotSettingsManager` when its page is built and writes it when flipped; `G2GPresentation._on_setting_changed` (engine, audio, bindings) and `G2GClient.apply_client_settings` (HUD, camera, mouse) are the only places a setting is applied, at boot and on change alike — so there is no Apply button, and a value changed from the console is what the menu shows next. The style, the flashlight and third person are not settings: the server has a say in each, and a stored "on" would be a promise the next server can refuse. **It does not pause** (dot-ui's `allow_pause` reason); the sampler is suspended instead, so a runner who opens it stands still.

**Five settings were declared and applied by nothing**, which is this family's most repeated bug: `sensitivity`, `field_of_view`, `show_speed`, `show_splits` and `preferred_style`. The menu would have been five switches that do nothing; all five are wired now. `field_of_view` was 110 over 70..130 and meant nothing either way; it is the genre's `fov_desired` now (90, 75..120) — and **every settings document on disk stores 110**, because a document stores defaults too, so schema 2's migration drops exactly 110 rather than widening everybody's view overnight (nobody can have chosen 110 and seen it). Found by the first rendered frame of the Video page reading 110°.

**In a browser, the menu opens when the pointer is taken away, not only on the key.** A browser exits pointer lock on Escape and may not deliver the key at all, so `_watch_pointer` opens the menu when a lock it had seen is gone; an Escape that arrives within 250 ms of that is swallowed, or the menu would flash and close. Closing the menu by Resume (a click) recaptures; closing it by Escape cannot (Escape grants no user activation), so twelve frames later an uncaptured pointer puts the client back on "Click to play". Fullscreen from the Video page calls `navigator.keyboard.lock()` where it exists, which is what keeps Ctrl+W — Duck held while pressing forward — from closing the tab; the help screen says so to a browser player.

**Hiding the others is drawing only.** Every other `G2GPlayer` (the ghost included) gets `visible = false`, and their beacon pings are not played; they are still simulated and replicated. The player being spectated is never hidden.

Three bugs the frames found and no check could: the sidebar lit two pages at once (`set_pressed_no_signal` goes round a `ButtonGroup`), a listening key button drew its prompt over its own edge, and the 110° above. `headless_presentation` has five sections for this (146 checks), driving the menu's own switches, picks and rebinds against a fake host.

## The menus are dot-menu's now (2026-10-09)

Everything under *The menus, the keys and the flashlight* above still holds as behaviour; the code moved. The Escape menu, help, the map list, "Move HUD elements", the switch, the key rebinder, the six themes, the frame-rate counter, the browser's pointer-lock handling and the stock settings with the code that applies them are `dot-menu` (`DotMenu`, `DotMenuApplier`, `DotMenuStock`, `DotMenuBindings`), extracted from this game's `ui/` so every game gets them; seven files and about 1,600 lines left this repository. What stayed is this game's: `g2g_menu_pages.gd` (which rows go where, in the genre's words, and the live rows for the style, the flashlight and third person), `g2g_bindings.gd`'s rows, `G2GPresentation`'s own settings and their defaults (no shake, no flashes, `fov_desired`), and the `menu_*` methods on the client the live rows ask. Rendered before and after with `tools/screenshot_menus.sh`: every page is the same picture, except the map list's sentence, which the first render of the new one dropped (a dot-menu fix).

- **The stock settings kept their keys and scopes**, so nobody's stored choice moved. `raw_input` is gone: declared here and applied by nothing.
- **Tab is the scoreboard, held, and Next style is N.** Schema 3 drops a stored `bind_style_next` of exactly "Tab": a document stores defaults too, so every player who never chose has "Tab" written down, and keeping it would put two actions on one key.
- **The board is a timer server's**: style, best time and rank on this map, time connected and ping, fastest first. Online the names, pings and times are dot-server's roster (sent only while a player holds Tab) and the columns are `G2GModule`'s `scoreboard_fields`, from `G2GGame.board_fields`, which is the standing `refresh_standing` already works out for the HUD, so a held board costs no store reads. The module takes the hooks back on unload, and sets them only on a dot-server that has them, because this pack runs on whatever server the host has. Offline, and against a server with no roster, the board is the local game. The record's ghost is not a session and is not on the online board.
- **The client shell must be built with dot-menu before this pack is published**: a shell without it cannot parse any script here that names a `DotMenu*` class.

`headless_presentation` drives the real menu with this game's pages against a fake client (181 checks, including the board and the migration); `headless_client` holds Tab and presses P on the real offline client (24); `dedicated` asserts the module's columns reach the server's board and leave with the module (189).

## Validating

```bash
godot --headless --path . --import
godot --headless --path . --script tools/export_zones.gd
godot --headless --path . res://examples/headless_run.tscn   # 241 checks, 27 sections
godot --headless --path . res://examples/headless_presentation.tscn  # 181 checks
godot --headless --path . res://examples/headless_client.tscn  # 24 checks: the real client, offline
godot --headless --path . res://examples/headless_net.tscn   # 193 checks, 27 sections
godot --headless --path . res://examples/dedicated.tscn      # 189 checks, 16 sections
godot --headless --path . res://examples/jitter_probe.tscn   # 4 configurations
godot --headless --path . res://examples/headless_imported.tscn  # 45 per map, +1 per track and stage: 2074 over the 42 (run with --fixed-fps 128)
godot --headless --path . res://examples/headless_maps.tscn      # 51 checks
godot --headless --path . res://examples/headless_stack.tscn     # 29 checks
```

`headless_maps` is the one that says there is no list of maps anywhere: it removes a
map from the catalogue that is still on disk and checks a rescan puts it back, and adds
one to the catalogue that is *not* on disk and checks a rescan takes it away. Counting
three maps proves nothing — a hardcoded list of three counts three too.

`headless_imported` skips cleanly when `maps/imported/` is empty, because an imported
map is optional content and a fresh clone that has never run the importer is not
broken. It iterates whatever is there rather than naming a map, for the reason the
catalogue does.

Its last two sections are the ones that say a map is a **level**. `_test_runnable`
drives a `DotTimer` over the map's own zone set and asserts a time comes out with every
split in it; `_test_stands_where_it_sends_you` teleports a player to each track's spawn
and each `!s<n>` destination and waits to see whether they are still there a second
later. A zone set can pass `problems()`, have no thin volumes and still be impossible to
finish, and a stage destination that is in the sky succeeds at every step and drops the
player out of the world.

`tools/bsp_preview.sh` renders each of them from its spawn, because four of the bugs in
this family's list were found by looking at a picture. It uses `xvfb-run`: `--headless`
gives a null renderer and saves a frame of nothing, which is worse than no screenshot
because it looks like one.

`jitter_probe` is the only one that measures a **rendered frame** rather than a
simulated tick, which is the whole class of bug the others cannot reach. See
Decision 10.

**Two checks in `headless_run` were measuring the wrong thing and only stopped when
dot-timer was fixed.** `DotTimer.effect_requested` was emitted by nothing, so this
game's maps had respawn zones that did nothing and a bot that missed the ramps fell out
of the level and kept falling. "Most of the descent is spent not grounded, which is
surf" was counting 1500 ticks of a bot nowhere near the map, and passed comfortably.
The bot is now put back on the start platform after about 500 ticks; the loop stops
there, is airborne for 94% of them, and the suite asserts the pit fired at all. The
bhop test's fixed 420-tick prestrafe had the same problem and now drives until the run
starts.


`headless_net` runs a server game and a client game in one process over a lossy
loopback: admission, prediction converging, the timer and a finish replicated to the
sub-tick fraction, a cvar changed under a live client, styles, tracks, a published
avatar, a map change through dot-map's protocol — a client that has the map, one still downloading it, and one that refuses — a bot, and leaving.

`dedicated` counts its sections and its checks since 2026-09-24 — it had neither, the one suite here without a total — and exits 1 when either is off; armed by raising `CHECKS` by one.

`dedicated` configures the server for **100** ticks in `server.cfg` — deliberately not
the project's 128 — and checks the game and the timer count at 100, because a test
using the same number at both ends would pass with the chain disconnected.


## Two layers, and the one line that had to tell them apart

`G2GRig` keeps a player's body on two visibility layers so the **owner's** first-person camera can cull it while every other camera still draws it — layers rather than `visible`, because a first-person player who is culled out of their own view still needs their shadow, which is the only cue a first-person view has for how tall they are and where they are standing.

Every part of that worked except the part that had to differ. `G2GCamera.first.cull_mask` correctly excludes `LAYER_LOCAL_BODY`, `third` correctly includes it, `G2GPlayer` correctly sets `rig.visible_to_owner = camera.is_third_person()` — and `_set_layers_recursive` then set **both** layers unconditionally, so the culled layer was never the only one. `owner_sees` arrived and was used for nothing but a `cast_shadow` ternary whose two branches were identical, which is the tell. The first-person camera therefore drew its own player's avatar at point-blank range and the bottom third of the screen was a magenta dome, on every map, in every frame, for every player.

**No assertion in this repository looked at a layer mask**, and none of the numbers involved were wrong — there was nothing to notice except the picture. It was found in a screen recording. `headless_presentation` checks it now, because the check is one bitwise AND against the camera's own cull mask and the alternative is noticing again.

## The player layer is reached, and third person here stays cosmetic

`G2GPlayerStack` was built, installed and instantiated, and most of it was not *asked*
anything. Three joins were made in one pass and each is a decision.

**The spawn director chooses the start now, and the map is the fallback.** It had every
track's start in it and `spawn_player` used the map directly beside it, so the director
answered nothing for the life of a server. What it adds over the map is the per-site
cooldown, the occupancy check and — with `sv_deathmatch` on — the protection window, which
`DotSpawnProtection.grant` only ever opens from inside `DotSpawnDirector.choose`.

**A start is per TRACK, which needed a condition dot-spawn did not have.**
`MetaEquals` compares a site against a constant fixed when the condition was built;
nothing compared one against the *request*. So a course whose every track starts somewhere
else either built one director per track or picked the site itself — and picking it
yourself is one line, which is what every game had done. `DotSpawnConditions.MetaMatchesRequest`
is the addition, and `DotSpawnRequest.make` carries an `extra` dictionary for it.

**The sites are checked against the loaded map rather than trusted to arrive in order.**
`map_ready` and the respawn that follows a map change are not ordered, and losing that race
means answering confidently from the previous map. See `docs/bugs-found.md`.

**`sv_deathmatch` is what opens the protection window**, and it is shut on a pure timer
server: there is nothing to be protected from, and a window with no attacker is a rule with
no purpose. The duration is `G2GArsenal`'s own match rule rather than a second copy.

### Third person stays `G2GCamera`'s, and does not become `DotTpsController`'s

game-playground now runs dot-player-controller's third-person half over a
`DotPlayerControllerSwitch`, and **this game deliberately does not.** Decision 3 already
says why in one line: *third person is cosmetic.* `G2GCamera` flips between two cameras
over **one motor**, so a run set in third person is comparable with one set in first.
`DotTpsController` is a genuinely different motor — camera-relative input, its own
acceleration, coyote time, a jump buffer — and a player who could switch to it mid-run
would be setting a time on movement nobody else was using. On a records server that is not
a feature, it is a leaderboard nobody can compare.

### And the HUD can be looked at

`tools/screenshot_hud.sh` renders the clock, the keys, the stage line and a notice.
`tools/bsp_preview.sh` draws MAPS and this game had nothing that drew its interface — the
only game in the family without one. Its first frame found a filed time drawn straight
through the clock.

## Decision 5: the movement configuration travels, not the tunables

`G2GNetBridge` sends a joining client the server's `G2GConfig` movement fields
(`G2GConfig.MOVEMENT_FIELDS`) and both ends derive `DotFpsTunables` through the same
`G2GMovement.tunables_for`. The alternative — sending the tunables — is one more
representation that can drift, and prediction only converges when the two ends
simulate with identical numbers. The server fingerprints what it derived and the
client compares; a mismatch is one log line rather than "the netcode feels bad".

That is also why `G2GConfig.snap_movement()` exists and why `G2GGame` calls it before
deriving anything: the wire carries float32, and a server simulating with the doubles
it read from a file while its clients simulate with what they received differs in the
last bit, silently. The values are rounded once, on the server, before anything reads
them.

The bridge is modelled on dot-2d-hungry's, the one in this family proven over a real
socket. What is specific to this game:

- **The tick is a whole-game property.** dot-net simulates per entity; here everybody
  moves and then every timer is fed the position its move produced. The first
  behaviour through on a tick runs the whole game (`ensure_game_ticked`); the rest find
  it done. The client's `client_tick` does the same for what it predicts and then feeds
  every timer, so a remote player's clock on your HUD advances with theirs.
- **Timers replicate as run identities, not per tick.** `DotTimerNet.RunState` carries
  the start tick and the sub-tick fractions; the client's clock does the counting
  between packets. A finish carries ticks and fractions, and the client reproduces the
  server's arithmetic to the digit — `headless_net` compares them at 1e-4 s, which is
  how it found `DotTimerNet.Finish.time()` subtracting the end fraction the run adds.
- **A peer receives nothing until it says READY.** dot-server's signon finishes and
  *then* the client builds its scene; a HELLO sent in between lands on nothing.
- **Bots are session ids without a peer.** Peer 0 is dot-net's broadcast address, so
  a bot is never a peer; `remove_player` handles both, `remove_peer` delegates.
- **A player's avatar comes from dot-platform's admission** (`G2GModule._avatar_for`,
  duck-typed through the `platform` module) and, failing that, from what the client
  publishes (`G2GClient.avatar`), and failing that the stock one. Every one goes
  through `G2GRig.dress`, which conforms it to the server's schema.

## Decision 6: the record's ghost is a player

The replay bot every community timer has: the server record's replay runs the map
as a `G2GPlayer`
with `replay` set and no timer. That one choice does three jobs. It draws through the
same rig everybody else does; it replicates through the same bridge, so a client —
browser included — sees the run without ever decoding a replay; and it counts as a
bot in the server query, which is what it is.

`sv_replay_bot` turns it on and off live, and off takes the current ghost away rather
than waiting for the next map — an operator who turns a bot off wants it gone now.
`g2g_ghost` says whose record is running and how far through it is.

`G2GReplays` keeps the fastest replay per map, track and style, in memory always and
on disk beside the records when there is a directory, using `DotTimerReplay`'s own
file format — so a replay set at 64 Hz plays on a 128 Hz server. **A replay is kept
only with an accepted record**, never with a merely faster run: a checkpoint-assisted
or tainted run is not a record and must not become the ghost everybody chases.

The bridge adopts any player the game made itself (`player_added`) as an entity with
no peer, and `ensure_game_ticked` applies received commands **only to players that
have a peer** — a bot is driven by something else, and an empty command applied on
top of a replay stands the ghost still. That rule was found by `dedicated`, whose
driven bots stopped hopping the moment the bridge started adopting them.

`!r`, `!wr`, `!top`, `!style`, `!track`, `!rtv`, `!s <n>` / `!stage <n>` and `!rs` are
chat triggers as well as console commands, because twenty years of bhop servers taught
everybody's fingers those. The last three go through `DotTimerManager.request_stage`,
which stops the run, and `G2GGame._on_stage_requested` moves the player to the stage
zone's destination and yaw. Until 2026-09-28 nothing listened to that signal, so no
stage destination on any map could be reached (`[stage-yaw-1]`).
`g2g_map` is not: changing the map from chat is an admin's, through the console.

## Decision 7: the client counts at the SERVER's tick rate

`HELLO` carries `tick_rate` and always did. Nothing read it back out.

`G2GGame._resolve_tick_rate` takes `Engine.physics_ticks_per_second`, which on a server
is `sv_tickrate` and on a client is whatever the host project exported — 128 in this
repository, **60 in dot-server-deploy's browser shell, which never sets one**. So a
client simulated at a rate the server did not, and three things are derived from that
number: the step prediction replays with, the divisor every replicated run time is
reconstituted through, and `DotNetClock`'s own rate.

Measured, by putting `headless_net`'s client on 60 against its 128 server: **correction
rate 0.96** — prediction never converging — and the client's clock reading a finish as
0.466 s where the server filed 0.218 s, which is 128/60 of it. On a leaderboard that is
every time on the board wrong by the ratio of two numbers nobody thought were related.

`G2GNetBridge._adopt_tick_rate` now applies it before `sync_from_server`, because the
clock converts its error and its input lead through `tick_rate`. All three copies move
together: `G2GGame.set_tick_rate` (which takes the timer manager with it and reads the
rate back rather than assigning it), `net.config.tick_rate`, and `net.clock.tick_rate`
— the last one being a copy taken at `setup()` that writing the config does not touch.

**`headless_net` could not have found this and now can.** Both halves run in one
process, so they read one `Engine.physics_ticks_per_second` and agreed no matter what
the wire said; the check that asserted "at one tick rate" was passing for that reason
rather than for a good one. The suite now puts the client on 60 deliberately, the way a
host project would, and asserts that HELLO is what corrects it.

The same shape found two more, both only visible in a browser:

- **A client's own configuration was invalid.** `G2GClient` clears `initial_map` when it
  is networked — correct, the server decides — and `G2GConfig.validate()` refused an
  empty one unconditionally, so `load_layered` failed and every networked client logged
  "the g2gfast configuration is not usable". Only an authoritative instance chooses a
  map.
- **dot-timer warned every client that its times would be wrong.** The rate/engine
  mismatch warning is real on a server and meaningless on a mirroring timer, which
  counts at the rate it was told precisely so a run set at 128 is comparable on a client
  rendering at 60. It is now guarded on `authoritative`.

## Decision 9: the local player is adopted, not looked up

`HELLO` says who you are. `JOIN` is what creates you — `G2GNetBridge._apply_join` calls
`game.add_player` — and it arrives afterwards. So `G2GClient._watch`, called from
`hello_received`, resolved `game.players.get(id)` **one message too early**, got null,
and never tried again: [member G2GClient.player] was null for the entire session on
every networked client.

**What that broke is a strange list, and the strangeness is the point.** The HUD binds by
id, so it worked. The camera follows the entity, so it worked. Movement worked, because
`DotFpsSampler.sample` polls the [InputMap] rather than reading events. What did not work
was everything below the `player == null` guard in `_unhandled_input` — **mouse look, F5,
Tab, R, C, V and M**. A client that connects, draws, shows a live HUD and walks around,
on which the mouse and the whole keyboard do nothing.

`_on_player_added` is the fix: connect [signal G2GGame.player_added] before anything can
create a player, keep the id in `_watch_id`, and adopt when the player named by it
appears. `_adopt` is also where the sampler is put on the player's tunables, which
`_on_hello` used to attempt against the null it had just fetched.

`headless_net` drives two bridges directly and never instantiates `G2GClient`, so nothing
in the suite had been through this. It now asserts the ordering the bug lived in — that
the local player does **not** exist when HELLO names it, and that `player_added` fires for
it — which is what a client has to be written against.

**How it was actually confirmed.** Not by a test: Playwright cannot move a pointer-locked
mouse — `movementX`/`movementY` come through as `0` on every synthetic event — so the
symptom the player reported is not directly reproducible in the harness. F5 is, and it
sits in the same `match` under the same guard: press it, screenshot, and third person is
either drawn or it is not. *When the thing you want to test is unreachable, test the
thing beside it that shares the failure.*

## Decision 10: the client draws BETWEEN ticks, and the engine runs at the server's rate

Reported as "very jittery in the browser", and every number in every suite was right.

The simulation was already correct. `G2GClient._physics_process` asks
`DotNetClock.advance` how many ticks a frame is worth, so a client on a 60 Hz engine
against a 128-tick server ran exactly the right ticks — **in bursts of two and three**,
2.133 of them per physics frame. Nothing rendered between ticks: `G2GPlayer.present`
drew `controller.state` directly, so the camera advanced 74 mm on six frames out of
seven and 112 mm on the seventh. **A 47% change in apparent speed, eight times a
second**, for as long as a browser client has existed.

Two halves, and **either one alone measures as no better than doing nothing**:

- **`DotFpsController.render_state` exists and nothing called it.** It has interpolated
  between the last two ticks since the controller was written, and its guard was
  `if drive != Drive.LOCAL: return state` — LOCAL being the one drive no networked game
  uses. So the cure was written, documented as the cure, and unreachable from every
  deployment shape that needed it. `_accumulator` is never advanced under EXTERNAL
  either, so even reaching it would have blended at a constant alpha of zero.
- **`_adopt_tick_rate` moved three copies of the tick rate and not the engine's.** The
  fraction a renderer interpolates at is a fraction through a *physics frame*, which is
  only a fraction through a tick while the two rates agree. At 60-against-128 the
  interpolation changes nothing measurable.

`examples/jitter_probe.tscn` runs all four combinations and fails unless exactly the
shipped one is smooth — because a probe that only tested the fix would have passed for
either half on its own.

| | drawn at the last tick | drawn between ticks |
| --- | --- | --- |
| **engine 60** | 47% spread | 47% spread |
| **engine 128** | 47% spread | **0%** |

**View angles are deliberately still not interpolated**, and they never juddered: mouse
motion is delivered once per frame and `DotFpsSampler.sample` consumes everything
pending, so whichever tick runs next absorbs exactly that frame's motion and the yaw
tracks the mouse per frame however many ticks ran. Blending it would add a tick of
latency to aiming to fix nothing.

The cost is real and worth naming: a browser client now steps Godot's physics 128 times
a second instead of 60. The work inside the tick is unchanged — the clock was already
producing 128 ticks a second — so what is added is the engine's own physics step, which
for a world of static geometry and one query-driven controller is close to free.

**Nothing headless could see any of this**, which is why it survived every suite:
every check in this repository asserts a simulated value, and every simulated value was
correct. `jitter_probe` is the first thing here that samples what a *frame* shows.

## Decision 8: the browser is asked for the mouse, not told

`G2GClient._ready()` set `Input.mouse_mode = MOUSE_MODE_CAPTURED`, which is right on a
desktop and impossible in a browser: pointer lock needs **transient user activation** —
a real click — and `_ready()` is the one moment in a client's life guaranteed not to
have one.

It is refused *silently*. `Input.mouse_mode` reads back as CAPTURED, the view still
turns with the mouse, and nothing anywhere reports a problem; what the player gets is a
cursor sitting on top of the game that wanders out of the window mid-run.

**This is the family's deployment-shape rule on a capability nothing had needed yet.**
game-hungario is the only other browser client in the family and it is 2D — it reads the
cursor's position and never locks it — so g2gfast is the first thing here that has ever
asked a browser for pointer lock, and the first place this could have been found.

- Desktop captures immediately. A player who launched a first-person game should not
  have to click their own window first.
- Web shows the cursor, says "Click to play" on the HUD, and captures on the first
  mouse-button press. That press is handled *before* the `player == null` guard, because
  a browser player clicks while the world is still loading more often than not, and a
  click swallowed for want of a player is a click that never captures anything.
- Escape **releases** and does not toggle, on both platforms. Escape is how a browser
  itself exits pointer lock and it then refuses to re-enter for about a second, so a
  toggle bound to it silently does nothing every other press on the web. One key that
  releases and one gesture that captures is the same contract everywhere — and it is
  what this file's own class documentation had claimed all along while the code toggled.

Verified with a real click in headless Chromium: `document.pointerLockElement` is null
before and set after. `tools/browser_check.mjs` never clicks, which is why nothing had
exercised this.

## Decision 11: an imported map is content, and it is read rather than rebuilt

`tools/bsp_import.py` turns a Source-engine `.bsp` into a map this game
loads: geometry, the textures the file carried inside itself, the lighting its
compiler baked, its start line, its finish, its stages, its bonus tracks and the
volumes that catch a player who fell off the ride. It was written against
`surf_kitsune` and `Surf_Mesa` in `godot/inspirations/`, and now runs over the eight
maps there.

**The scale is not converted, because there is nothing to convert.** Source stores map
coordinates at 0.75 inch per unit and [G2GUnits] already declares exactly that ratio,
for exactly this reason — a surf ramp imported at the 1-inch figure is a ramp the
movement cannot hold. A BSP coordinate *is* a genre unit. The whole transform is the
axis swap, because Source is Z-up and Godot is Y-up:

    godot = (src.x, src.z, -src.y)

**START and END zones are read, not guessed — and where there is nothing to read they
are written down by hand.** The paragraph that stood here said a map of this genre has
no convention for a start and a finish that survives compilation. That is true of
`surf_kitsune`, which really does drive its stages with
`OnTrigger !activator,AddOutput,targetname X` and a filter chain, and it was false of
five of the eight maps beside it, which carry `zone_start`, `map_end_zone`,
`startzone_s4`, `tm_bonus2_endzone` and `tm_checkpoint1` in the entity lump in plain
text, because they were built for a timer. **Reading a label the mapper wrote is not
guessing, and throwing it away cost every one of those maps its timer.** `zone_role()`
is the whole rule; `assign_tracks()` turns `bonus2`, `koga` and `b_` into track
numbers.

Three of the eight label nothing, and for those — and for the halves the labelled ones
are missing — there is **`maps/zones/<id>.json`**: one file per map, checked in, saying
which volume is the finish and *why*, in terms of what is in the .bsp rather than in
coordinates somebody typed. A zone there names its volume as an entity
(`"named": "startzone_s4"`), as the teleport aimed somewhere (`"teleport_to":
"endroomdest"`), as a box grown around a destination, or as the nearest trigger to a
point; anything that fails to resolve **stops the import**, because a finish line that
quietly resolved to nothing is a map nobody can finish and nothing about playing it
would say so. `maps/zones/README.md` is the format.

That directory is beside the repository and not beside the import for one reason:
`tools/import_maps.sh --force` rewrites every manifest, so a hand-written zone kept in
one would survive exactly until somebody re-imported the map it describes.

**The solid is the brushes, and the drawn faces are only the ones that ended up
visible.** The importer read the face lump and the map got `create_trimesh_collision()`
over what came out of it, which sounds right — a surf map is static geometry and a
trimesh is what a swept hull wants — and is a collider with most of itself missing.
vbsp deletes every face nobody can see, a mapper paints the rest `nodraw`, and a surf
ramp is routinely wrapped in `tools/toolsplayerclip`, which is invisible by definition
and is the reason the ramp is smooth to ride. **Between 31% and 77% of the sides of a
solid brush are not drawn**, over the eight maps in `inspirations/`. So the brush lumps
are read now — `LUMP_BRUSHES`, `LUMP_BRUSHSIDES` and the leaf tree that says which model
owns what — and each brush's half-spaces are solved into the convex hull the mapper
drew. That is the same geometry the genre's own player movement traces against, and it
is why it is **convex per brush and not one trimesh**: a concave shape is loose
triangles and a sliding hull catches on every interior edge between them, which on a
45-degree ramp at 3000 u/s is a run ended by a bump that is not there. Displacements
are the exception, because terrain is not convex in any useful way; they stay triangles,
welded across the map so the seams between them at least are shared.

Two things decide what is solid, and the contents flags are only one of them: a
`trigger_teleport`'s brushes carry `CONTENTS_SOLID` — 186 of them in `surf_beginner2`,
and they are the pits — so `SOLID_BRUSH_ENTITIES` in `bsp_read.py` decides by classname,
and a classname in neither list is left non-solid and **printed**, because the
alternative to a note is an invisible wall nobody can explain.

**What a surface is FOR comes from its slope, not from the name of its texture.** There
was a list of regexes over material names here — `concretefloor039a` is a ramp,
`nodraw` is a platform — on the reasoning that the name is the only intent a compiled
.bsp still carries. It is not, and the regexes scored almost nothing: `surf_beginner2`
came out 97% FLOOR, one grey mass with the ride invisible inside it. In this genre what
a surface is for is exactly what its angle lets a player do with it, and that is a
number in the plane lump. Face area by normal Z comes out in three clean bands on every
map: ~30–43% at +1.0, ~46–55% at 0.0 and a distinct 1.6–8.5% between — the ride. The
line between PLATFORM and RAMP is `G2GConfig.max_slope`, because a texture that says
"you can stand here" where the movement says otherwise is a texture that lies.

**Brush entities are drawn, not only the world (2026-09-26).** A jump map's blocks are `func_door`s and its decoration `func_brush`/`func_illusionary`, each its own brush model, and the importer drew model 0 alone -- so every block was solid (collision already came from the brushes) and invisible. Counted per map: 47% of bhop_eazy's drawable faces, 30% of aztec's, 22% of monster_jam's, 16% of tesquo_v2's. `drawn_faces()` in `bsp_import.py` adds every brush entity whose class a player sees (`DRAWN_BRUSH_ENTITIES`: the solid list minus `func_clip_vphysics`, plus the illusionary ones), offset by the entity's `origin` for `brush_box`'s reason, skipping `rendermode 10` and a `func_brush` that starts disabled. UVs stay computed from the stored position. The manifest's `brush_entities` records the solid count and the faces drawn, from two code paths, and `headless_imported` fails a map with solid entities and none drawn. Not handled: a brush entity's `angles` (geometry is offset, not rotated) -- measured on 2026-09-27, not one drawn brush entity in the 26 maps has non-zero `angles` (only two `env_embers`, which are not drawn), so it costs nothing today; and a door is drawn where it rests -- it does not move with the player (bhop_aztec 152, bhop_eazy 188, bhop_monster_jam 467 `func_door` blocks, which sink when stood on; standing still is what they punish, so no route needs them to move).

**And the prototype grid is painted the texture's own colour, which IS in the .bsp (2026-09-26).** vrad stores every texture's mean albedo in `dtexdata_t.reflectivity`, linear, for its bounce lighting, so a stock texture whose pixels never shipped still has a known colour: `cs_havana/woodm` is (0.09, 0.05, 0.03), kitsune's neon strips are their neon. `bsp_import.py`'s `surface_colour` writes it as sRGB `colour` on each surface and `G2GBspMap._material_for` tints the greyscale grid with it; the grid stays for scale. Rendering all 26 maps before and after is what showed it: every untextured wall had been one of four role greys under a dark lightmap, which read as black, and afterwards aztec is sandstone, lego2 is its bricks and monster_jam its sand. **A measured black is only trusted when the name says black.** A `$selfillum` light panel has no albedo, so `lights/white001` -- the whole of surf_kitsune's ramps -- came out black and vanished; zero now falls back to the role colour unless the name contains `black`. `headless_imported` checks each map paints at least half its prototype surfaces this way. Also from that render pass: the maps float in their skybox, so `G2GLighting.profile()` sets dot-lighting's `sky_below_horizon` -- the dark "ground" half of the procedural sky made every look down between two ramps a floor that is not there (checked against the source game's own kitsune screenshot in `inspirations/g2gfast/extracted/`). And `tools/bsp_preview.sh` defaults to a NEUTRAL stage, so its frames are not what a player sees: `GAME=1 tools/bsp_preview.sh` draws the map under its own sky, fog and tone map.

**A surface the .bsp carried no texture for gets the prototype set, not a flat
colour.** Most of a surf map is built from textures that live in the game's own VPKs
and were never inside the file — 97% of `surf_beginner2`'s triangles, 100% of
`surf_year3000`'s — and those used to be painted one flat `G2GTextures.ROLE_COLOURS`
tone each. They get `res://textures/prototype/` now, keyed by the role above, with UVs
built from a **tangent frame in the face's own plane** rather than an axis projection:
dropping the dominant axis is one line and stretches the grid by root two along exactly
the direction a player is travelling on a 45-degree ramp, so the one surface whose
texture is being read for speed is the one drawn at the wrong size. A frame in the
plane has no stretch and falls out with one axis running down the slope, which is the
line a surfer steers by. The mesh carries UVs in **64-unit squares** and the material
scales by the tile's share of that, because how many squares are in a tile is a
property of the image and which image is installed is not known until load.

**`surf_kitsune` renders as black silhouettes with neon wireframes on them, and that is
the map.** It is worth writing down because it looks exactly like a broken import and
was checked twice. Its own textures came out of the pakfile correctly: `grids_grid_*`
are 1024x1024 and mean 6 to 11 out of 255 — a black panel with one bright line on it —
so the map is black because it was built black. Raising [member G2GBspMap.ambient]
changes nothing there, which is the tell: ambient multiplies the albedo, and ten times
nearly nothing is nearly nothing. `surf_mesa` through the same path is a lit rock
canyon.

**Half of that has since turned out to be a bug after all, and the reasoning above is why it took so long to see.** Two of `surf_kitsune`'s black surfaces were the map and two were not, and the paragraph above could not tell them apart because it only ever asked whether the *albedo* was black. Its `grids_grid_*` panels are still exactly what it says — built black, on purpose, and they stay. Its `tools/toolsblack` panels are 1024x1024 pixels of flat zero with nothing in them at all, which is a missing texture wearing a correct decode, and they get the prototype set now. And every surface of every map, kitsune included, was being drawn in the transparent pass — see the ALPHA entry under *What building it found*. A map that is black for a stated good reason is the ideal place for a rendering bug to hide, because the explanation arrives before the question does.

`tools/collision_probe.gd` is how any of this is checked. It drops the player's hull on
every upward-facing triangle in a map and counts what it goes through, with `--trimesh`
to build the old collider from the same data for comparison — **32.8% → 1.1% on
`surf_beginner2`, 16.4% → 0.0% on `surf_kitsune`, 26.9% → 0.0% on `surf_year3000`**, and
what is left on the first is water. It is a tool and not an assertion because the answer
is a percentage of one map rather than a pass. The suite's own check — one bot, one
spawn, still standing three seconds later — passed on all eight maps the entire time.

**Solid is not the same question as rideable, and only the second one is what a surf map is.** `collision_probe` asks whether a surface holds a player up; nothing asked whether a player can *travel along* one, which is the entire activity. `tools/surf_probe.gd` sweeps the hull down the steepest line of every RAMP triangle and `tools/surf_run.gd` runs the real [DotFpsMotor] from one for four seconds. Both exist because a run that dies halfway down a ramp is invisible to every assertion here — the ramp is solid, the spawn is fine, the map is right in a screenshot, and the bot that stands on it for three seconds never moves.

What they say about `surf_mesa`, which is the map the complaint came from:

- **The slope rule is not the problem.** Zero of 13,086 simulated ticks reported grounded on a face steeper than `max_slope`, so a player is never *standing* on a ramp and friction is never applied to a ride. That was the first suspicion and it is wrong.
- **2.4% of ramp sweeps stop dead against a face that opposes the travel**, and two thirds of those clear when the hull is lifted eight units — so they are obstructions standing proud of the ride, not walls the mapper drew across it.
- **Roughly 40% of them are the displacement collider.** Rebuilding the map without it takes the dead stops from 98 to 58 out of 4000. That is the concave-shape warning three paragraphs up, arriving: a displacement is `ConcavePolygonShape3D`, which is loose triangles, and a hull sliding across one catches on the interior edges between them. `surf_mesa` is the worst case in the set — 183,552 displacement triangles and **zero** playerclip brushes, so nothing smooths the ride the way the other seven maps' clip brushes do.

Not yet fixed, and the fix is not one line: a displacement grid would have to become convex geometry the way a brush does, which is 91,000 quads on this map and cannot be 91,000 shapes. The measurement is written down here so the next attempt starts from a number.

**Second pass, with the real motor and a seeded sample, and the first pass's headline number was noise.** `tools/surf_run.gd` runs [DotFpsMotor] itself; `Array.shuffle()` uses the global RNG, so two runs sampled different triangles and a sweep over `max_slide_iterations` came out 5:1488, 8:2525, 12:1212, 16:619 — which reads as a result and is entirely which triangles got picked. Both probes seed now. **Every before-and-after in a tool that samples has to sample the same things, and a tool that does not say so will produce a trend on request.**

What the seeded numbers say, over ~15,000 simulated ticks per map:

- **The slide almost never fails.** Genuine wedges — iterations exhausted — are **1 tick on `surf_beginner2` and 0 on `surf_mesa`**. That was not visible before, because [member DotFpsMotor.stuck_ticks] counts the duplicate-plane early-out as well, and that path is the *intended* one. It reads 10% to 14% of ticks and is almost all the early-out. `ran_out` and `stopped_on_duplicate` are separate now; the counter that anybody would have reached for was reporting a working mechanism as a fault.
- **What actually fires is the duplicate-plane break, on 1481 and 2219 ticks.** `_remember_plane` treats normals within 2.56 degrees as the same plane, which is right for one long ramp and is the exact shape of an imported one: **a curved ramp is not a surface here, it is a fan of convex hulls a degree apart**, so the second contact of nearly every tick is a near-copy of the first. The move then breaks with most of the tick's motion unspent, keeping the velocity. A player holding 900 u/s on the HUD and crawling up a ramp is that, and it is what was reported.
- **The two maps fail for different reasons**, which is why one fix will not do. Rebuilt without the displacement collider, `surf_mesa` goes 2219 → 278 (87% of it is the terrain trimesh) and `surf_beginner2` goes 1482 → 1482, not one tick (all of it is brush hulls).

Two things were tried against it and neither is kept. The classic 1.001 **overbounce** is genuinely missing — `_resolve_planes` clips with `Vector3.slide`, an exact projection, while its own acceptance test carries a `-1e-5` tolerance because "a direction exactly in a plane reads as entering it about half the time" — and adding it moved the count the wrong way by 2%. **Clipping and continuing** instead of breaking took `surf_mesa` from 2 runs carried to 7 and `surf_beginner2` from 0 to 2, and took stalls from 7 to 9. Both are changes to collide-and-slide in an addon five games share and the netcode predicts against; neither earned that on those numbers. The diagnosis is here and the decision is not this file's to make.

**Two things the probes cost before they measured anything**, both in [docs/gdscript-hazards.md](../../docs/gdscript-hazards.md) now: `%g` is not a GDScript format specifier and a failed format returns the string unchanged rather than raising, so a probe printed its own placeholders; and `const X := PackedFloat32Array([...])` is not a constant expression, which fails at parse time with a message about constants rather than about packed arrays.

**A track with a start and no end is dropped, and said so.** `surf_summit`'s third
bonus has a start zone, eight checkpoints and no finish anywhere in the map. Left in,
it is a track a player can begin and never complete and one `DotTimerZoneSet.problems()`
refuses the whole map over; dropped silently it is a bonus that quietly does not exist.

**A teleport is the pit unless the map says otherwise.** Every `trigger_teleport` left
after the zones have claimed theirs becomes `DotTimerZone.Kind.RESPAWN`, which is what
it always was and the reliable half. **Since 2026-10-08 a pit sends the player to its own
destination with the run kept** (see *What a map's brush entities do*), so most of what
follows about doors is now true of every teleport; `doorways` still makes a door a
TELEPORT zone, which the timer treats the same way. `surf_kitsune` is where that is not enough: all 53
of its teleports aim at one of nine colour destinations, and the ones the size of a
room are the pit under that colour's section while the ones the size of a door are how
you leave one section for the next. Treated alike — which is what "every teleport is a
RESPAWN" does — **walking out of the first section ends the run and puts the player back
at the start, for ever.** `"doorways": {"max_horizontal": 512}` in the map's own file
opts into the measurement that separates them, and the doors become
`Kind.TELEPORT`, which keeps the run. It is opt-in because it is only true of a map
whose sections are joined by doors.

**The mesh is a binary and not a glTF, and the reason is one array.** The baked
lighting needs `ARRAY_TEX_UV2` to reach the shader, and every route through an
importer decides for you what a second UV set means: glTF's occlusion channel is
greyscale, so the coloured neon that is `surf_kitsune`'s entire character goes grey,
and its emissive channel is additive, so it washes out. Building the [ArrayMesh] from a
`PackedByteArray` costs one pass and keeps this repository's own convention anyway —
maps here are made in code.

**Imported maps are discovered, not listed.** `G2GMapCatalogue.scan` scans
`maps/imported/` for manifests. The three hand-written maps above it are a list because
they cannot appear without somebody editing this repository; an imported one arrives by
running a script, and a second place to remember it is the shape that has gone stale
four times in this tree — `setup.sh`, `tools/check.sh`, `package_check.sh` and the
bootstrap manifests. The manifest cannot be forgotten, because the map does not load
without it.

### What building it found

- **`dmodel_t` is 48 bytes and reading it as 52 still produces a perfect world.**
  Model 0 is the first record, so every field before the overrun lands correctly: the
  map rendered flawlessly, at the right scale, with correct materials — and every one
  of the 92 brush models after it was misaligned, so all 53 trigger volumes were
  garbage. Nothing errored, because a wrong AABB is a legitimate AABB. It showed only
  because the sizes came out **negative**. The family's own "a value produced correctly
  and consumed by nothing", with the halves swapped: one consumer was right and the
  other was reading noise, from the same table.

- **`Image.load_from_file` on a `res://` path works from source and ships nothing.**
  An export packs the *imported* `.ctex`, not the `.png` the importer consumed, so
  every texture in the map comes back null in an exported build — which for this game
  is the browser client, the one target that cannot be debugged by looking at it. Godot
  says so, in a warning that scrolls past with one per texture. `load()` is correct in
  both. This is Decision 8's shape again: a development path and a shipped path that
  are not the same path.

- **VTF mip levels are stored smallest-first**, so mip 0 — the full-size image — is at
  the *end* of the run. Walking forward and stopping at the first mip is the obvious
  reading and yields a 1x1 texture stretched over a wall.

- **Ignoring displacements deletes the terrain and nothing says so.** A displacement's
  face is the flat quad the mapper drew; the real surface is a grid of offsets from it.
  `Surf_Mesa` has 1434 of them, including ramps players ride, and drawing the quads
  instead produces a map that is complete, plausible and missing every rock face.

- **You cannot tell "the lightmap is unlit" from "the albedo is black" by looking**,
  and `surf_kitsune` is 5892 triangles of `tools/toolsblack`. There is no camera angle
  that separates them, because both render black through a multiply. `bsp_preview`'s
  `lm` mode overrides every material to show the baked lighting alone, which is the
  only thing that answers it. The family's "an interface is invisible to assertions",
  reached through a shader.

- **A script error inside a test aborts THAT TEST and not the run — again.** A call to
  `DotTimerZoneSet.all()`, which does not exist, removed a check while the suite
  printed **19 passed, 0 failed**. `headless_imported` asserts its own check count for
  that reason, which is the guard this tree already knew it needed.

- **One `ALPHA = base.a;` drew every imported map through itself, for as long as there have been imported maps.** Godot decides a spatial shader is transparent by whether it *writes* `ALPHA`, not by what it writes — so an unconditional write at the bottom of `fragment()` moved all 420 surfaces of all eight maps into the alpha pass, where depth is not written and geometry is sorted per surface instead of per pixel. What that looks like is not "the map is see-through": it is `surf_mesa`'s grey concrete floor reading as brown sand, because the terrain *behind* the floor was drawing in front of it, and half the map reading as black holes where a distant unlit surface won the sort. Every value involved was correct — the texture decoded, the UVs were right, the material was configured — and the only thing that could ever have found it is a person looking at a picture beside the original. `g2g_bsp_translucent.gdshader` is the ALPHA write now, on the 20 surfaces out of 420 whose own VMT said `$translucent` or `$alphatest`. The manifest had carried that flag since the importer learned to read a VMT and **nothing had ever read it**: this tree's own "a value produced correctly and consumed by nothing", for the fourth time, and the consumer that was missing is the one that would have made the write conditional.

- **Dividing a lightmap by 255 reads as a conversion and is not one.** `c * 2**e` is already the linear value Source's own `TexLightToLinear` returns; 255 is the range of the *mantissa byte*, not of anything the number means. Over `Surf_Mesa`'s 1.9 million luxels the median linear value is **8.1** and the 99th percentile is **398** — so the divide put the median luxel at 0.03 and the map came out about three times too dark, with every surface the sun did not reach directly reading as a hole rather than as a shadow. No fixed divisor could have worked: p10 to p99 is a factor of five hundred and any linear scale that keeps the top from clipping crushes the middle to black. `lightmap_key` exposes each map against its own median instead, through a Reinhard curve that never clips — so a map exposes itself, which is what "a map is content" has to mean when the content is somebody else's compile.

- **A texture that is flat black is a texture that is missing, and it decoded perfectly.** `tools/toolsblack` is 1024x1024 pixels of zero; so is `cs_italy/black`, and between them they cover **5.9 billion square units** of the eight maps. Drawn faithfully, that is indistinguishable from a load failure to anybody playing. They go to the prototype set now, by the same route as a texture that was never in the file, because "no texture" is what both of them are. The rule is flat **and** dark, not either: `grids/grid_white` is a black panel with one bright line — mean 12, deviation 30 — and it is most of what `surf_kitsune` is made of, so a rule keyed on darkness alone would repaint that whole map over a property it has on purpose.

- **Kenney's prototype set was installed, loaded, scaled correctly, drawn on every surface it should have been, and invisible.** The report was "I still don't see any usage of kenney prototype textures", and the set was on screen the whole time. Its tile is a flat field with a ONE pixel line on a 128 pixel square: **1.4% to 3.5% of the image is anything but the field colour**, against 52% for `grid_texture`, which draws a three pixel line and darkens alternate squares. Ink is the only thing that survives a mipmap — every texture converges to its own average with distance — so a tile that is 97% one colour *is* that colour a few metres out, and on a ramp seen edge-on, which is the angle a surfer spends the whole map at, it is that colour everywhere. Two whole maps rendering in flat orange and flat grey, correctly.

  `grid_texture`'s own comment had already worked this out and written it down — "a pure grid on a ramp seen edge-on collapses to nothing between the lines; the checker is what still carries speed at a glancing angle". The generated grid has a checker. The installed set did not, and nothing compared them, because **both are correct images and the difference only exists once one of them is on a ramp forty metres away**. The checker is composited onto Kenney's own pixels at load now, once per role: every pixel of theirs survives, the palette that tells a ramp from a wall is untouched, and the only thing that changes is the part a mipmap keeps.

- **And the constant beside it is 8, was doubted, and is right.** Measuring the tile to check gave four — lines on rows 0, 256, 512, 768 and 1023 of 1024 — and four is wrong. The lines alternate STRONG and FAINT: every 256 pixels they are 97 luma steps above the field and every 128 they are ten, so a threshold chosen to ignore block-compression noise ignores half the grid with it. The wrong answer was plausible, arithmetically tidy, and would have drawn every imported map at half scale on the one number that constant exists to hold still. Written down because the measurement is the part that was hard, not the number.

- **`tools/bsp_preview.sh`'s `ambient` and `light_boost` overrides had never changed a pixel.** The comment above them said to assign before `add_child`, because `_build()` runs from `_ready()`. It does not: `build_from` builds there and then, so every material already existed by the time either line ran and the assignment reached nothing. Two renders at different exposures came out **byte-identical**, which is the only reason it was noticed. The one tool in this repository whose entire job is to let a person look at the thing no assertion can see was silently ignoring half of what it was asked to show.

- **Every spawn on a map is a place a player can be put, and exactly one of them was ever checked.** `headless_imported` asserts the MAIN spawn is somewhere a player can stand. `tools/spawn_check.gd` asks it of all of them — the per-track spawns and every zone destination a teleport can land on — and finds **36 points inside solid geometry across five maps**: 18 of 83 on `surf_beginner2`, 9 of 77 on `surf_summit`, 5 of 70 on `surf_aquaflow` including its **main spawn**, 4 of 174 on `surf_kitsune`, and none on `surf_mesa`. A player put inside a brush is stuck there until they find the respawn key, and the map is perfect from every other angle — which is how this arrived, as "I get stuck when I spawn".

  **An overlap test alone proves nothing, and two probes were built on one before this was noticed.** Shapes have collision margins, so a capsule resting a millimetre above a floor overlaps it: "is the player in solid" answers yes for everybody standing anywhere, and a bhop probe built on it reported 70% to 75% of runs broken and **did not move when the motor was changed**. What separates a real bad spawn from a margin is how far up it takes to get clear — `surf_aquaflow`'s main spawn is clear only 64 units up, against a 72-unit player, and that number is not a margin.

  `floor_of` is one cause and is fixed: it returned `box[0][2]`, the bottom of the trigger VOLUME, and a mapper sinks a trigger into the ground on purpose so nobody can walk under its edge. It is not the only cause — a `destination` is wherever the mapper put an entity — so the lift is applied to every route rather than to that one.

  **And the lift cannot see displacements, which is where `surf_aquaflow`'s spawn actually is.** A brush is half-spaces and a point test against it is exact; a displacement is welded triangles with no inside. So `lift_out_of_solid` looks at a spawn buried in the reef and correctly reports it clear, and the 36 stand. The answer is almost certainly not in the importer at all: the game has a physics world, and one shape query per spawn at map load settles brushes and terrain alike in the one place that knows about both.

### What importing the other six found

The importer had been run on two maps. Running it on the eight in
`godot/inspirations/g2gfast/` — and then asking whether each one could be *finished*
rather than merely loaded — found five more, and four of them were in the two maps that
had already been imported and passing.

- **A brush model's bounds are relative to the entity's `origin` key, and the importer
  ignored it.** vbsp moves a brush entity's geometry so its origin sits at (0,0,0) and
  records where that was; only worldspawn, whose origin is the world's, is the same
  either way. So **every pit volume in both imported maps was drawn piled around the
  centre of the map**, where no player goes. Nothing errored and nothing could: a
  RESPAWN volume that is never entered is indistinguishable from one nobody has fallen
  into yet, and the suite's zone section counted them and measured their thickness
  without ever asking where they were. Confirmed against the faces rather than reasoned
  about — for every trigger in `surf_kitsune` the model's own vertices span exactly the
  model's bounds, and the origin is the offset to where the mapper drew it.

- **Three of the eight maps have LZMA-compressed lumps and nothing in the header says
  so.** `bspzip -repack -compress` is what every map host runs, because a 112 MB `.bsp`
  is a 112 MB download for every player who joins; it rewrites each lump as a
  `lzma_header_t` plus a raw LZMA1 stream and leaves the file's VBSP version at 20. The
  reader read the compressed bytes as structures, got a plausible plane array out of
  them, and died in the texture string table — which is simply the first lump whose
  contents are checked against anything. `surf_aquaflow`, `surf_arcade` and
  `surf_interference` could not be imported at all, and the failure named the wrong lump.

- **A spawn yaw was never converted.** Positions crossed the axis boundary and the
  angle beside them did not. Source measures yaw about +Z from +X and `DotFpsMotor`
  builds forward as `(-sin y, 0, -cos y)`; solving the two against each other gives
  `yaw - 90`, and the manifest was writing Source's number straight through. **No number
  is wrong when this is wrong** — the player stands in exactly the right place facing
  the wrong way, which on a map with an obvious route reads as the spawn being fine.

- **A spawn 8 units above the floor is a coin toss.** `Surf_Mesa`'s spawn destination
  sits 25 units over its platform. Dropped from 10168 the player lands; from 10170 the
  player lands; from **10169**, which is where an 8-unit lift put them, the player goes
  through the floor and keeps going — and moving them one unit in x, or 320 units in y,
  fixes it. One point, on one map, and it was the point the map shipped with. A capsule
  that starts that close to a triangle seam is a coin toss whichever way the collision
  backend rounds, so the answer is not to start there: the lift is 24 units, which is
  clear of the seam and still leaves a 94.5-unit player 9 units of headroom under
  Source's own minimum 128-unit ceiling. **The `--check-only` pass and every assertion
  about the zone set passed throughout**; what found it was the one check that puts a
  player on the map and waits.

- **Two brushes sharing a targetname are ONE entity in Source, and mappers use that.**
  `surf_summit`'s `tm_checkpoint1` is a pair, one in each of the map's two mirrored
  lanes. Emitted as two zones they are two stage zones with the same number, which
  `DotTimerZoneSet.problems()` refuses — correctly — so the map went from "no timer at
  all" to "no timer, and now it says why". They are unioned back into the one volume the
  map always meant.

And one in the suite, which is worth the same: **`headless_imported` had four zone
checks and not one of them asked whether a run could be finished.** A zone set with a
start, a finish, stages numbered 1..n and no thin volumes passes every one of them and
can still be impossible to complete. `_test_runnable` drives a `DotTimer` over the map's
own zones — start, away, each stage, finish — and asserts a time comes out with every
split in it; `_test_stands_where_it_sends_you` teleports a player to each track's spawn
and each `!s<n>` destination and waits to see whether they are still there. Those two
are what say these are levels rather than geometry, and writing them found the
`Surf_Mesa` spawn above and two more artefacts of stepping a timer by hand.

### Decision 13: a map says how it is lit, and that was being thrown away

Every one of these `.bsp` files carries its own lighting in the entity lump, and the importer read the geometry, the collision, the zones, the spawns and the baked lightmap and left all of it there. `light_environment` has the sun's pitch, yaw, colour and compiled brightness and a separate ambient colour; `env_fog_controller` has the fog's colour and range; `worldspawn` names the sky; `sky_camera` describes the 3D skybox. So every imported map was drawn under one hardcoded sun at (-55, -35) against one flat blue-grey background — `Surf_Mesa`, which asks for a low warm sun at -28 degrees in 235/222/177 with pale cyan fog from 5000 units, and `surf_beginner2`, which asks for one straight overhead in 255/211/168 with no fog at all, **came out looking like the same room**.

`lighting_of` writes it into the manifest and **dot-lighting** applies it — `DotLightDocument.from_dictionary` over the block, `DotLightRig.apply` over the world. [G2GLighting] is forty lines of caller now, and the one decision it keeps is which `DotLightProfile` a machine gets: `web()` in a browser, which drops shadows and keeps glow. That is doubly right here — a surf map is a large open volume, so the shadow pass costs the whole canyon, while the glow is what makes a neon strip read as a light, and a neon strip is how one of these maps signposts the route. Four things about that are worth keeping:

- **The sun lights the characters and not the world, and that is correct.** An imported map's surfaces are `unshaded` because the baked lightmap *is* their lighting. What changes how the world looks is the post-processing — the tone map, the fog, the glow and the colour behind everything — and those four are most of the difference between this and the engine these maps were built for.
- **The tone map is the largest single change and it costs nothing.** Godot defaults to `LINEAR`, which is not a tone map, it is a clip. The engine these came from ran a filmic curve, and the shoulder on it is why a bright sky and a dark rock face can both be readable in one frame.
- **The glow threshold is under 1.0 on purpose.** The lightmap atlas is an 8-bit sRGB PNG tone-mapped at import, so nothing in an imported map is ever above white; an HDR threshold would find nothing to bloom, on any map, for ever. The neon strips a surf map is signposted with sit near the top of that range, and this is what lets them read as light rather than as paint.
- **`_light`'s fourth number is not a multiplier on the first three.** It is the intensity the map's own compiler was given and it runs from 20 to 600 across these eight maps, so feeding it to `light_energy` gives a sun six hundred times too bright on one map and twenty times on the next. It is a ratio against a reference, soft-curved, because the range is two orders of magnitude.

**Calibrated against a reference frame — see Decision 14.** What follows was written before that and is kept because both cases are still real. `surf_aquaflow`'s fog is cyan at full density by 8536 units, which is exactly what the map says and makes an orbit preview one flat teal rectangle — correct, and a reminder that a preview outside the map is not a view a player has. And that map is 98% prototype-textured, where PLATFORM is Kenney's *Light* tile at a mean of 213, so a filmic curve over a map made almost entirely of near-white tiles is a white-out. Neither is the lighting being wrong; both are the lighting being applied faithfully to something else that needs a pass.

### Decision 14: the lighting was being flattened three times before it reached the screen

Decision 13 read a map's lighting and applied it. It still looked nothing like the engine these maps were built for, and the reason turned out to be measurable rather than a matter of taste. A reference frame of one of these maps as its own engine draws it spans a **linear luminance ratio of 303:1** between its fifth-percentile pixel and its ninety-fifth. The same view of our import spanned **7.9:1**. That single number is the whole of "why does theirs look so much better": a cave lit by one warm lamp was coming out as an evenly grey room, and no amount of correct geometry, correct textures or correct sun angle was going to change it.

Three things were compressing it, and only the third was interesting.

**The atlas encode was a tone map, and a tone map has no business there.** `build_lightmap` wrote Reinhard, `v / (v + median)`. Reinhard is a *display* operator: it takes a finished image to a displayable range. This atlas is not a finished image, it is a light term that still has to be multiplied by an albedo — and Reinhard compresses ratios everywhere, including the midtones where everything readable in a map lives. It is now expose, clip, gamma: divide by a white point, clip the top, write through 2.2. Every ratio below the clip survives exactly, because **gamma encoding is already the compression an 8-bit image needs** and a 500:1 linear range is what sRGB was designed to carry. Atlas contrast went from 3.5:1 to 226:1.

**The white point has to be a statistic an outlier cannot move.** Dividing by the 99th-percentile luxel is the obvious reading of "use the range" and it hands a whole map's exposure to its brightest few luxels: `Surf_Mesa` exposed perfectly and `surf_beginner2` — dim, with a handful of bright sources — went almost black. Anchored on the **median** instead, every map in the set lands in the same midtone and clips between 0% and 3.4%. That percentage is printed per map at import now, because it is the one number that says whether a map's exposure is sane.

**And two thirds of the map's triangles were reading their lighting from the wrong place.** A displacement is a flat quad plus a grid of offsets, and its lightmap is parameterised over **the quad**, not over the terrain that came out — the luxel extents say so plainly, being 12x12 or 7x12 where the displacement grid is always 9x9. The importer projected the *displaced* point through the face's lightmap axes, which overshoots the luxel range by however far the terrain bulges, and the clamp then parks whole hillsides on one edge luxel. Displacements are 67% of `Surf_Mesa`. They rendered as smooth bright gradients with no shadow anywhere, which is indistinguishable from a map that is simply lit flatly — and every check passed, because the atlas was right, the UVs were in range and the geometry was in the right place. Projecting the flat point moved the rendered median from 191 to 49 against an atlas median of 47. **The tell was that mismatch: a lightmap that renders nothing like its own histogram is being sampled somewhere other than where it was written.**

End to end, the same view went from 7.9:1 to **87:1**, with the median at 31 against the reference's 15.

**The tool that was supposed to catch all of this was lying.** `tools/bsp_preview.gd` builds its own neutral `WorldEnvironment` so a diagnostic render shows the map and nothing else — and added it beside the one the map now brings. A second `WorldEnvironment` does not merge and does not warn at runtime; one is simply used. Every render it had ever made was drawn under the map's own tone map, fog and glow while the code said otherwise. It removes the map's by name now and prints which it used, and takes `keepenv` for the question it could not otherwise answer.

**The sky is drawn from the map's own numbers.** `sky_name` names a texture set that lives inside the game these maps were authored for, is not in the file, and is not ours to copy. dot-lighting builds a procedural sky instead: the fog colour as the horizon, the ambient as the top, the sun at the map's own angle. A flat rectangle in the fog colour — what stood here before — is a blown highlight the moment the world around it is exposed correctly.

### What is not imported

- **Static props from the source game's own archives.** Props whose model the pakfile carried are imported since 2026-09-27 (see *The triage of 2026-09-27* below); a prop naming a stock model is counted in the manifest's `static_props.stock_models` and not drawn -- 80 of `bhop_monster_jam`'s 81, all 72 of `surf_year3000`'s, all 13 of `bhop_mario_fxd`'s, 94 of `bhop_tesquo_v2`'s 188.
- **Animated and scrolling materials, and a sky the map did not pack.** `tools/toolsskybox` faces are skipped, so behind the 3D skybox (drawn since 2026-09-27) is the map's own packed sky where it has one (since 2026-10-09, below) and dot-lighting's procedural sky otherwise. Water is drawn as a flat surface in its own texture or the prototype grid (a `_beneath` water face from below like any other face), and since 2026-10-08 it is also swum in: see *What a map's brush entities do*.
- **Anything from the source game's own archives.** A `.bsp` embeds only what the mapper
  added: 84% of `surf_kitsune`'s triangles and 91% of `Surf_Mesa`'s. The rest — the stock
  texture library, which on these maps includes the ramp itself — is drawn in the
  [G2GTextures] prototype set instead, chosen by what the surface is FOR, which is what
  an untextured surface means here.

**These maps are third-party work.** `godot/inspirations/` is read-only reference in
the shape `external-study/` already has: reading a map for its dimensions, its ramp
angles and its stage layout is the point of having it. Shipping extracted geometry in a
released game is a different act and needs the author's permission.

### Maps are dropped in, not listed

There is no list of maps in this repository. `G2GMapCatalogue` scans, and a map is
whatever has a scene and a sidecar, or is just a manifest:

```
maps/<id>.tscn   + maps/<id>.zones.json    hand-written: a scene and a script
<root>/<id>/<id>.json                      imported: data, and nothing else
```

**An imported map has no scene and no script, and that is what makes it droppable.**
Every one of them is `maps/imported_map.tscn` — one scene, inside the build — pointed
at a different manifest through `DotMapDef.meta`. The obvious alternative, a generated
`<id>.gd` and `<id>.tscn` beside the data, was what this shipped first and it cannot
work for a map that arrives *after* the export: `res://` is a read-only PCK in a built
game, so a scene that is not in it does not exist. A script in a delivered dot-cloud
pack could not resolve `extends G2GBspMap` either — this family measured that and wrote
it down — so the same change fixes both.

The roots searched are `res://maps/imported` (baked into an export), `user://maps`
(where anything downloaded at runtime lands, and **the only way a shipped server can be
given a new map**), and whatever `g2g_maps_directory` names. First root wins, so a map
in the build is not silently replaced by one dropped in beside it.

```bash
cp somewhere/surf_whatever.bsp ../inspirations/g2gfast/
tools/import_maps.sh            # imports what is new, skips what is current
tools/import_maps.sh --prune    # and deletes imports whose .bsp is gone
tools/bsp_preview.sh            # and renders every one of them from its spawn
```

If the import prints `NO START` or `NO END` for the main track, the map labels neither
and needs a `maps/zones/<id>.json`. It is still offered — a map you can walk around is
worth having — but nothing will time a run on it.

and on a running server, `g2g_maps_reload` rescans without a restart.

**A delivered map belongs to somebody (2026-09-26).** The map id is what a player types and every record is filed under, and it does not change; the pack is `<owner>/<map id>` on the origin, the shape the site gives every pack. `sv_map_content_owner` (`G2GConfig.map_content_owner`) is the owner, prefixed only where a map is fetched (`map_content_id`), and `_mark_delivered` reads the content id back off the mount path so a client is announced the id that was actually fetched. Empty keeps the old unowned layout. Both descriptors set `gamemann`. `tools/publish_maps.sh --owner gamemann --key ../dot-server-deploy/keys/content.key` signs every imported map with the key clients trust as `default` (the one the unowned packs were signed with; measured) into `<out>/<owner>/<id>/`, for uploading to the origin's `content/` as it stands. The map sweep waits one frame before its first request so an owner set by the same descriptor pass lands first whatever order the cvars are written in. `headless_net`'s *a map published under an owner* fetches, marks and follows one; armed by fetching the bare id.

**The boot map's owner is read from the descriptor being loaded (2026-09-30).** dot-server instantiates the game scene, whose `_ready` starts fetching `initial_map`, before it applies the descriptor's `cvars:`, and `sv_map_content_owner` is the module's, which the host registers after the scene is up; so the first fetch ran with no owner and asked for the unowned `surf_mesa`, working only while the origin still carried the legacy pack. `G2GGame._adopt_descriptor_owner` reads `sv_map_content_owner` (`G2GConfig.MAP_CONTENT_OWNER_CVAR`) off the game manager's `pending()` descriptor (by registry name, `game_manager_service`) just before the boot fetch; the module's later pass sets the same value. An owner set only in a per-game `.cfg` still lands after the boot fetch. `headless_run`'s *the first map comes from the owner the game descriptor names* covers it with a stand-in manager and cloud; armed by removing the call. **Review, 2026-10-01: one seam was missed.** When a game change fails because the new scene is missing, dot-server re-instantiates the *previous* game while `pending()` is still the game that failed, so the restored g2gfast took the failed game's owner (or none). `_descriptor_for_this_scene` takes `pending()` only when its scene path is this scene's (a path either side cannot compare counts as a match), else `current()`, which the manager has already set back to the restored game; armed (the third check fails with the path test disabled, asking `the_failed_game/<map>`). Map changes after boot, votes and prefetch read the module's cvar and were fine; neither `headless_net` nor `dedicated` loads g2gfast through a descriptor, so the live path is still only covered by the stand-in.

**The rescan mutates the catalogue in place rather than replacing it.**
[DotMapRotation] holds the catalogue by reference and reads its pool live, so swapping
the object leaves the rotation offering exactly the maps that are no longer there.

**The map being played is deliberately not unloaded when it disappears from disk.** Its
scene is resident, the players on it are mid-run, and taking the world out from under
them to enforce a directory listing is worse than letting it finish and never be chosen
again. `g2g_maps_reload` says so in its reply.

This replaced **three** hardcoded copies of the same three map ids —
`G2GGame._map_catalogue`, `tools/export_zones.gd`, and the ad-hoc lists in the export
scripts. That is this tree's most repeated bug and it had reached this repository too.

**Verified by dropping one in**: a map copied into `user://maps/`, never in the build,
with no script, no scene and no `.import` files, loads and plays and renders
identically to the same map under `res://`.

### What making it dynamic found

- **A client could not be configured at all.** `G2GClient` built a bare `G2GConfig` and
  never called `load_layered()`, so the family's `defaults < JSON < env < argv` chain —
  which this file's Decision 1 is about — ran on the server, in every suite, and nowhere
  on the client. `--g2g-initial-map surf_kitsune` reached a dedicated server and went
  nowhere offline, which always played whatever the export defaulted to. It is the
  family's own convention missing from exactly one file, and no test could see it
  because every suite sets `config.initial_map` directly, which is the path that works.

- **Every imported pit volume was thin enough to fall through.** Source *sweeps* its
  trigger tests; `DotTimerZoneIndex` asks `contains(point)` once a tick. A mapper draws
  a `trigger_teleport` as a 16-unit plane because in Source that is enough — and at
  3500 u/s and 128 Hz a player travels 27 units between samples, so a falling surfer
  steps clean over the pit and falls for ever. **48 of surf_kitsune's 53 respawn volumes
  and 7 of Surf_Mesa's 10** were that thin. The importer now inflates a thin volume into
  a slab centred on the original plane — centred, because downward is right for a pit
  and wrong for a boundary trigger above the play space, and a centred slab is the
  honest approximation of the swept test Source was doing.

  This is the same failure this file already records twice: *the thing dot-timer's
  RESPAWN zones exist to prevent was the thing that did not happen*, and it announced
  itself as one warning line during an ordinary run. `headless_imported` now asserts
  `thin_zones()` is empty, which is the check `headless_run` has always made for the
  hand-written maps and nobody had extended to the imported ones.

## The detector, turned on this game's own new code

The family's rule is that **an exported setting whose name occurs exactly once in its
repository is a setting nothing reads**. The same grep over *methods* is worth as much
and had never been run: a public method whose name occurs once is a method nothing
calls. Turned on the twenty-six-addon pass it found seven, and the first is the one
that matters:

- **`G2GCombat.set_fire_command`, which meant `sv_deathmatch` was a mode nobody could
  shoot in.** The arsenals were built, the hitboxes were registered, the match was
  counting, and the fire command every tick read was one nothing ever set. The fix is a
  bit on `G2GNetCommand` rather than a request, and the reason is prediction: a shot
  happens on a tick and has to be replayed with the movement of that tick, so a trigger
  arriving reliably-and-separately would be replayed against a different tick's
  position every time. It is applied in `_net_apply_input`, which is the one place that
  runs on a replay as well as on a fresh tick — and **not retained across a lost
  packet**, unlike the movement: a held trigger that survives a hiccup is a weapon that
  empties itself during one.
- **`G2GArsenal.weapon_table`, which meant `DotLoadoutManager` was a manager of
  nothing.** It was built, given a schema and a store, and asked for nothing; everybody
  got a hard-coded knife and deagle. dot-loadout has never heard of a `DotWeapon` and
  dot-combat has never heard of a `DotItem`, and the table between them is the whole
  join.
- **`G2GClientExtras.receive_line`.** The client's `DotChatClient` was a history nothing
  fed. `G2GServices` routes a line through dot-chat and hands it to dot-server's manager
  to put on the wire, so on the client it arrives on `DotClientLink.chat_received` — not
  on anything dot-chat owns.
- **`G2GIdentity.avatar_for`.** dot-platform's module runs off `client_state_changed`
  because dot-server has no cancellable stage between authentication and content, so a
  player can be in the world with the platform still resolving them. The module's own
  `_avatar_for` now falls through to the hub, which falls through to the stock document.
- **`G2GProps.phys_gun`, `G2GHunters.spawn_one`, `G2GStats.finish_rate_of`** — a tool,
  an admin spawn and a derived figure, each reachable from nothing. `g2g_nudge`,
  `g2g_hunt spawn` and `!stats` are the doors.

Two things the new checks found that were not on the list:

- **A grab is once and a held prop moves every tick.** A layer that only called `grab`
  gives an admin a block that stays exactly where it was picked up, which reads as the
  physics gun not working rather than as a missing `hold`.
- **A GDScript lambda captures locals by value.** The shot counter was an `int`
  incremented inside a signal handler, so it stayed zero outside it — and the assertion
  reported a failure for a signal that had fired perfectly. This file's own family notes
  carry that warning, and the check was written wrong anyway.

## The characters are Kenney's, scaled to the genre's hull

`avatars/{body,head}_kenney_<a..r>.tscn` are 18 characters from Kenney's Blocky
Characters (CC0), generated by `tools/build_avatar_parts.gd` out of `avatars/kenney/`.
The two primitives that came first stay at the FRONT of `BODIES` and `HEADS`: `[0]` is
the schema's default, so a deployment without the art directory still resolves a default
part and an avatar document written before the art arrived still loads. A capsule is a
worse character and a better fallback.

**The scale is the whole job, and this game is the awkward one.** A Kenney character is
2.70 m; this game's player is 72 genre units, which is **1.372 m** — so an imported
character is very nearly TWICE the size of the thing it represents, standing with its
head above the camera, with every property of every node correct. The generator measures
the kit and derives the factor (0.508 here) rather than carrying a constant, because
game-arena runs the same kit against a 1.8 m capsule and gets 0.667: one number, written
down twice, would be this file's most repeated bug in a new place.

`G2GRig` mounts the body at 42% of the hull and the stock capsule is centred there, which
floats it about 13 cm — invisible on a capsule and a character standing in mid-air the
moment the part has legs. The body is foot-aligned; the head stays centred. **The rig is
not changed for this**, because arena mounts the same way and its parts are still
primitives: the art fits the rig.

`tools/avatar_preview.tscn` draws the parts inside a wireframe of the hull they have to
fit. Every one of those three was found by looking at a frame — "is this the right size"
is not a question an eyeball on a character alone can answer, and it is the same lesson
as the 0 x 0 `Control`s.

## Spectating, and effects with a rule

### `!spec`, which this game shipped without

**On a timer server, spectating is the point rather than a consolation for being dead.**
A record is set by one person, once, and everybody else on the server wants to watch it
being set — `!spec ada` is a command bhop and surf servers have had for fifteen years.

Two settings follow from that and both are the opposite of an arena's:

- **`force_camera` is 0.** There are no sides on a timer server, so restricting the
  camera to "your own team" restricts it to everybody and means nothing. It tightens to
  1 the moment `sv_deathmatch` is on, where a living player watching a living one is a
  free wallhack.
- **`allow_while_alive` is on.** Somebody standing in the start zone deciding whether to
  run is not dead, and refusing them the camera is a rule from a game this is not.

`!spec` with no argument watches whoever is **furthest into a run** — furthest rather
than fastest, because "who is nearly finished" is the question a spectator is asking and
somebody two seconds into a personal best is not the answer. The camera is driven once a
**frame**, for the reason `jitter_probe.tscn` exists.

### A movement effect is a style, and a style you did not choose is a record you did not set

This is the whole design of `G2GEffects` and the reason it is not four lines.

Everything in this game exists to make a run comparable with one somebody else set, on
another server, at another tick rate: sub-tick zone crossings, a rate taken from
`sv_tickrate` rather than an export, styles paired between dot-player-controller and
dot-timer by id. **An effect that quietly multiplies `max_speed` by 0.65 undoes all of
it**, and the player has no way of knowing it happened.

So effects here are split, and the split is enforced rather than documented:

| | |
| --- | --- |
| **Combat effects** — a bleed, a burn | Anybody, any time. They cannot change a time. |
| **Movement effects** — a maul, a haste | **Refused** while a ranked run is live. |

`G2GEffects.is_movement()` asks the *definition* whether it changes `move_speed_scale` or
`jump_scale`, rather than consulting a list of ids — so an effect added later is
classified by what it does rather than by somebody remembering to name it.

A server that wants hunted runs to count anyway sets `allow_movement_during_runs`, and
every such run is **tainted**. `DotTimerRun.tainted` has existed since dot-timer was
written and this is its first caller; it is what keeps a hunted run off a board beside a
clean one, which is the honest version of allowing it.

That is also what makes the hunters interesting rather than annoying: being chased has to
cost you something, and the thing it costs you is the record.

### Two id spaces meet at `entity_for`

This game keys players by `StringName`; dot-combat and dot-effects both key by `int`.
`G2GCombat.entity_for` is the direction that was missing — `player_id_for` had existed
since the class was written and nothing went the other way. A caller that hashed the name
instead would get a number that is stable, plausible, and **not** the one the health, the
hitboxes and the kill feed use.

Both directions are `DotEntityTable`'s now. `entity_for` is `id_for_key`, `player_id_for`
is `key_for_id` — which also stopped it walking every kit comparing ints on a call that
runs once per kill, once per respawn and once per hunter swipe. The paragraph above is
kept because the reasoning is what produced the addon: the comment that sat on
`player_id_for` is, word for word, what `DotEntityTable` exists to make unnecessary.

## `!spec` did nothing, and `g2g_map` deliberately still does

Two halves of the same gate, and they point opposite ways.

`G2GServices` hooks `player_command` as well as `player_chat`. Without it,
`DotChatRouter.command_entered` **could not fire**: dot-server's chat manager checks for
a command prefix before it fires `player_chat`, `_handle_command` returns on every path
including the unknown one, and its prefixes are `["!", "/"]` — identical to
`DotChatRules`'. So no `!` line ever reached the router.

`!rtv` survived that because `rtv` is also a console alias registered `.with_chat()`.
**`!spec` and `!spectate` are handled nowhere else and did nothing at all** — and the
module's own `_` branch said "left for dot-server's own chat commands", which was true
for `!r`, `!wr` and `!top` and quietly false for the two this game added later.

**`g2g_map` is the only command in its block without `.with_chat()`, and it is reachable from chat anyway.** It carries `CHANGEMAP` instead, and the flag is what answers — `examples/dedicated.gd` asserts that now, where it used to assert `not map_command.chat_allowed`.

The old assertion was written on sound reasoning — a map change destroys every run in progress, so a records server does not let a player do that by typing — and it was enforcing that reasoning in the wrong place. The chat check ran before the permission check and never asked who was typing, so the person it actually stopped was the operator holding `changemap`, typing `/map surf_beginner` into the chat box already in front of them. A player without the flag is refused either way, by the check that was always doing the work. `sv_chat_commands 0` puts the old behaviour back server-wide, and `allow_chat_change = false` on the dot-map block puts it back for the map change alone.

The episode is still worth the paragraph it takes: **a missing flag its neighbours have is evidence of nothing until you have checked whether a suite asserts the difference.** That assertion caught the flag being added once and sent the suite to 120/1 on the spot. What it could not tell anybody is whether the difference it was defending was the right one.

## The presentation layer, and the sentence every decision in it comes from

`G2GPresentation` holds dot-settings, dot-audio, dot-fx and dot-console, and every choice
in it is downstream of this project's own rule: **a player who came to run must not be
stopped by anything added for a player who came to do something else.**

- **Camera shake defaults to zero here and to one in every other game in the family.** A
  surf ramp is a precision input at 20 m/s; shaking the camera for a landing is not
  atmosphere, it is taking the run away. It is still a *setting*, because the same server
  runs a deathmatch layer and somebody in it may want one.
- **Full-screen flashes default to off**, same reason, same switch.
- **The effect budget is 24**, which is small on purpose. A frame here is a tick and a tick
  is 7.8 ms of somebody's time, and nothing drawn is allowed to cost one. That is safe
  because an effect never changes the simulation — which is the property that makes the
  whole addon shippable on a timer server.

The one thing audio genuinely adds is **the landing**. A bunny-hop is a rhythm, and a
rhythm you can only see is one you have to watch your feet for — so the landing is pitched
by the speed you landed at, which is the cheapest speedometer there is. It is **watched
rather than listened for**, for the reason game-hungario watches its own eating: a landing
fires on the authority, which on a netted client is somewhere else, so a client that hooked
a signal would be silent online and perfectly noisy offline.

**And that landing made no sound at all until now.** The catalogue named seven `.ogg` files nobody has produced, so the speedometer above was arithmetic reaching a path that does not exist — a decision made carefully and then inaudible. `sound_recipes()` maps each of the seven to a `DotAudioSynth` voice and `DotAudioSinkGodot` falls through to that bank when the path resolves to nothing, so the rhythm is audible without this repository shipping a byte of audio. The same restraint as the camera shake applies to the choice of voices: `land` is an impact rather than a thud with a body, because a long tail smears the rhythm it is there to mark. `tools/audio_probe.sh` is the only thing here that can tell "this game would make a noise" apart from "this game has a table of sounds" — a headless run has no audio device, so every assertion about audio in `headless_presentation` passes on a silent build.

**Both gate effects were refused on every run until 2026-09-27 (`[fx-scenes-1]`).** `fx_catalogue()` named `start_gate` and `finish_gate` under `scenes/fx/`, which did not exist, and dot-fx refuses a missing scene at DEBUG, so no suite noticed. They exist now as two script-free scenes with no external resource, so a delivered pack has nothing inside them to rewrite and `FX_DIR` (through `G2GPaths.rebase`) is the only path: a green ring of motes rising from the runner's feet in the start colour, and a warm column plus a spray of sparks for the finish. `_build_fx` warns when a scene the catalogue names is missing. **Every emitter is `local_coords`, and that is a bug fix, not a style:** dot-fx adds a scene to the tree and then sets its transform, and a world-space `CPUParticles3D`'s first burst goes out from where the node entered -- the world origin. Rendered, the start gate was drawn on another part of the map and the finish's column half there; nothing headless could see it, because the node itself is in the right place. `headless_presentation`'s *a start and a finish are drawn* asserts `missing_scenes()` is empty, that driving the timer's own signals through `follow_runs` puts particles in the tree at the feet `watch_movement` last saw, that somebody else's finish draws nothing, and that every emitter follows its node; armed by removing a scene (5 fired), by dropping the start's origin (1) and by removing one `local_coords` (1). `tools/screenshot_hud.sh --fx` renders `g2gfast_fx_start`, `_finish` and `_both`. **In first person a runner mostly does not see their own start gate:** it is drawn at their feet and rises to about knee height, below a level view; the finish's sparks do reach eye level. Spectators and third person see both.

**The server's console is bridged in with a prefix here and unprefixed everywhere else.**
The two consoles share names that mean opposite things — `!s3` on a client is a local
navigation and on a server is a teleport that ends a run — and an unprefixed remote console
is how somebody types something meant for their own client and loses the run they were
three stages into.

## The chat box, and a run nobody may lose to a keystroke

This game could be talked to and could not talk back: `DotChatClient` held the history, the HUD drew the notice, and no key opened anything to type in. It is dot-ui's `DotChatWindow` now, built by `G2GPresentation` beside the console, in the bottom-left corner — which is free here because the clock and the key display are along the bottom centre and the status line is along the top.

Three settings decide it, all `ACCOUNT`-scoped for the reason the sensitivity is: a runner who found their key once should never have to find it again.

| | |
| --- | --- |
| `chat_window` | `auto` / `on` / `off`. `auto` hides the box on a server already carrying chat somewhere the player can see it; `on` draws it regardless, which is how a relayed server and an in-game box run at once; `off` never does. |
| `chat_open_key` | `Y` by default. |
| `chat_team_key` | `U` by default. |

The log keeps drawing what other people said in all three cases. Off means "you type somewhere else", never "you are out of the conversation".

**`G2GPresentation.swallows_input()` covers the box, and `DotFpsSampler.suspended` is set beside it — and on a timer server the second one is the expensive half.** `swallows_input` keeps typed keys out of `_unhandled_input`; it can do nothing about `Input.is_action_pressed`, which is polled off the device every physics frame and does not care what consumed an event. A client that keeps reading movement while somebody types does not merely walk them into a wall here, it strafes them off a ramp and ends a run they have been building for minutes. **Nobody may lose a personal best by saying "gg".**

`auto` is answered by the server, because only the server can answer it: `G2GServices` points `DotChatManager.watch_relay` at the relay it built, and `G2GClientExtras` turns the payload that arrives into `chat_relay_changed`.

**And every line this game drew was blank until dot-chat was fixed.** `receive_wire` handed dot-server's `{kind, userid, name, text, admin}` to `DotChatClient.receive` expecting a refusal; `DotChatMessage.from_dictionary` defaulted every field, so it parsed as a valid message with no text and no sender, and the fallback underneath — the one that actually draws chat here — had been unreachable since it was written.

## A practice session taints every run in it

`G2GParty` is the sharpest disagreement the five games have about one addon.

A peer-to-peer host is a player's own machine, and it holds the tick rate, the zone
crossings, the sub-tick fractions and the map — which between them **are** a time. A host
who wanted to could file a world record by editing a number, and nothing on the receiving
end could tell.

So a run made in a peer-to-peer session is **tainted the moment it starts**, using
`DotTimerRun.tainted` — the field dot-timer has had since it was written, whose first
caller was this game's own effects layer, for the same sentence one level over: *a style
you did not choose is a record you did not set*, and a host you cannot vouch for is that
sentence about the machine instead of about the movement.

**Tainted rather than refused, and at the start rather than at the end.** A run you cannot
compare is still a run worth doing — practising a map with a friend on a machine neither of
you pays for is exactly what peer-to-peer is good at — and a run tainted on *finishing* is
one a player made believing it counted.

Migration is off: a time made of two machines' clocks is worse than no time at all.

## Three imported maps are not courses, and the suite used to say that was a failure

`maps/zones/README.md` has said since it was written that three of the eighteen imported maps have no finish and that **none of them is a mistake**: `buses_from_hell_fixed` is a vehicle map with no route to time, and `bhop_eazy` and `bhop_lego2` are section-chain maps whose sections are all labelled and whose END is not — nothing in either file distinguishes the last gate from the twenty-six before it. Guessing a finish would produce a leaderboard that looks right and measures a route the map does not have.

`headless_imported` asserted the opposite for every map it found, so it had been **exiting 1 on three maps behaving exactly as documented**. The check and the decision contradicted each other for as long as both existed, and the check was the one that was wrong. A suite that is red for a reason nobody intends to fix is a suite people stop reading, and it takes the real failures with it.

**The exemption is asserted in both directions, which is what stops it being a mute button.** `NOT_COURSES` maps are checked for *not* having a runnable main track: if one grows a finish, the list has gone stale and the failure is how anybody finds out. `NO_PIT` is a separate list of one for the same reason at a smaller scale — `bhop_eazy` and `bhop_lego2` do have pits and are still checked for them, and folding the two lists together would stop asking two maps a question they currently answer correctly. Armed by listing a real course in `NOT_COURSES`; it fails with both checks naming the list.

## One imported map lost 55 surfaces, and it was the renderer rather than the importer

`bhop_monster_jam` has **311 surfaces** and Godot's per-mesh limit is 256 (`RenderingServer.MAX_MESH_SURFACES`), so while `G2GBspMap` built one mesh the last 55 never reached it — `Condition "surfaces.size() == RenderingServerEnums::MAX_MESH_SURFACES" is true`, 55 times, at every load. It is the only one of the eighteen over the cap; the next largest is `bhop_mario_fxd` at 153.

**It cost rendering and not play**, because collision is built by `_build_collision` out of the manifest's convex-per-brush block rather than out of the drawn geometry — which is also why every collision and stands-on-it check passed on that map throughout.

`G2GBspMap` now starts a new `MeshInstance3D` every 256 surfaces. The first keeps the name `World`, which the suite and the probes look up; the rest are `World2`, `World3`. Each drawn surface also carries the index of the manifest surface it came from, because the materials used to be assigned by position in a second loop — the same index only while no surface is skipped, and one empty surface would have given every surface after it its neighbour's texture. `headless_imported` asserts that every surface a manifest lists is drawn, which fails on this map with the one-mesh build (256 of 311).

The probes that read `World` alone (`collision_probe`, `surf_probe`, `bhop_probe`) still see only the first 256 surfaces of this one map. They sample, so that is a smaller sample rather than a wrong answer.

## The timer's sounds were reachable from the suite and from nothing else

`G2GPresentation.on_run_started`, `on_split` and `on_run_finished` were written, catalogued with priority 100 because "they ARE the game", tested in `headless_presentation` by calling them directly — and never called by the client. Every run on every build started, split and finished in silence. `follow_runs` listens to the client's own `DotTimerManager` now, which is fed on a netted client too (`G2GGame.tick_timers_only`), so the start sounds on the tick the local prediction crosses the line rather than a round trip later. The personal-best fanfare is `record_accepted`, which only fires where records are filed: offline it plays, and a netted client — which is told a rank, not whether it beat its own time — plays the finish without it rather than guessing. The suite drives the timer's signals rather than the methods now, and a probe of the real offline client heard `timer_start` and `timer_finish` with the fix and neither without it.

## A trigger is one tick's input

`G2GCombat.tick` read the fire command with `get_meta("g2g_fire", null)`. A null default is the engine's *no default*, so every armed player who had not yet sent a command was an engine ERROR with a backtrace, every tick — 1,146 of them in one `dedicated` run, on a suite that reported 0 failed. And the command was never cleared: dot-net skips `_net_apply_input` for a tick whose packet never arrived, so the last trigger was replayed until the next packet — exactly the held trigger surviving a dropped packet that `G2GPlayerNet.last_attack` says does not happen. It is `has_meta` and consumed on read now; `previous` is left alone on a starved tick so a trigger really held across the gap is not read as a fresh press either. Both weapons are semi-automatic today, so the replay had no visible cost yet — it would have had one the day an automatic weapon was added.

## The second batch of imports, and three ways a pit was catching the wrong people

Eight bhop maps from `inspirations/bsp-maps/` were imported on 2026-09-23 — `bhop_badges_mini`, `bhop_evolve`, `bhop_grove`, `bhop_interloper`, `bhop_pandora2_fix`, `bhop_pit`, `bhop_supernova` and `bhop_tesquo_v2` — each with a `maps/zones/<id>.json` that carries an `attribution` block (author, the page it came from, the archive, the date) as well as its zones, because the credit is only ever written down in the archive and on its download page. Two were not imported and are not a gap in the importer: `bhop_zelda_final` is a puzzle map whose route runs through moving doors, keys and a quest counter, which is the map's entity logic and not geometry; and `bhop_grove_backwards` is `bhop_grove` plus a `trigger_look` that punishes facing forward, which is also logic. Without the logic the first cannot be finished and the second is a copy of grove.

Importing them found three faults in how a `trigger_teleport` becomes a RESPAWN zone, and **every one of them was already in maps that had been shipping** — the new maps only made them loud.

- **A filtered teleport is a condition, and it was imported as a pit.** The bhop genre's anti-standing trap is a `trigger_multiple` on each block that renames the player after a delay and renames them back after another, and a teleport on the block that only fires for the first name. This game does not run the map's outputs, so imported unconditionally every one of those fired on every landing: 258 on `bhop_mario_fxd`, 144 on `bhop_badges`, 185 on `bhop_lego2`, 124 on `bhop_arcane_v2`, all imported months ago. `"conditional_teleports": {"filters": [...]}` in a map's file drops them, **opt-in and by name**, because the same mechanism with a name that STAYS set is how a checkpoint pit is built (`bhop_pandora2_fix`'s `fcpN`), and those are real pits. The evidence that tells the two apart is in the entity lump — a trap's name is set and reset by the same trigger, a checkpoint's is set and left — and each file says which it saw. A teleport behind a `filter_activator_class` naming a class no player is (`filter1`..`filter4` on `bhop_tesquo_v2`) never fires in Source either, and that one is dropped automatically: there is nothing to decide.
- **A thickened pit swallowed the floor above it.** `MIN_ZONE_THICKNESS` grows a thin pit into a 192-unit slab centred on the plane, and a bhop map draws its pit a block's height under the blocks — so the slab reached up through them and standing on a block was standing in the pit. `inflate_pit` hangs the slab from the mapper's plane instead when the upper half has a solid top in it (19 of `bhop_aztec`'s 20 pits, 111 of `bhop_monster_jam`'s), and `clear_arrivals` trims any grown slab back off a spawn, stage or door it would contain, which is what fixed `bhop_pandora2_fix`'s stage 4 between two checkpoint planes 136 units apart and `surf_aquaflow`'s stage 2. A pit is also one zone **per brush** now rather than one box around a multi-brush trigger, because dot-timer's zones are boxes and the box around an L covers the elbow.
- **A door ended the run.** `doorways` makes a door a `TELEPORT` precisely so it keeps the run, and `G2GGame._on_effect_requested` handled `TELEPORT` with `G2GPlayer.teleport`, which stops the timer. So `surf_kitsune` — the map `doorways` was written for — could not be timed past its first section, and nothing said so. `teleport(..., keep_run)` is the fix and the handler is its only caller that passes true.

`headless_imported` asks both halves of it on every map now: *no spawn, stage or door lands inside a pit on its own track*, and *a door keeps the run*, driven through the real handler. The first failed on the old imports of `surf_interference` (its main spawn) and `surf_greensway`, and the second on three maps with the fix reverted. Three arrivals are still inside the mapper's OWN trigger rather than inside anything this importer added, and `ARRIVES_IN_PIT` lists them — asserted both ways, like `NOT_COURSES`. Two of them are fixed (`[arrive-1]`, 2026-09-24). `surf_mesa`'s door was inside the box of a sloped teleport brush and 237 units above the brush itself, since a zone is a box and a brush is a hull; `trim_to_hull` in the importer asks `point_in_brush` of every arrival and cuts the box back. `surf_summit` stage 3 landed on the floor beam of a gate with the fail plane on its far side, and its zones file now moves `!s3` onto the deck past the gate (a `STAGE` override with only a number and a destination, see `maps/zones/README.md`). `surf_greensway` stage 2 is still listed, and it is not a wedge: its arrival is inside the hull of the mapper's own teleport, and so is every floor and both canyon rims near `checkpoint_1`. The checkpoint is a split with nowhere to stand, and choosing where `!s2` goes needs somebody to look at the map in-game.

The size check assumed every map is more than 1,000 units along X. `bhop_grove` is one corridor 704 units across and 32,192 long; it asks the longest side now.

## One rock-the-vote, not three

This game had three: the console's `rtv` and `g2g_rtv` went to the map session's own `DotMapTimeLimit`, `!rtv` in chat was claimed by the module and went to the ballot, and a client's `Ask.RTV` went to the map session again. A player who typed `rtv` at the console and one who typed `!rtv` in chat were voting in two different votes. And none of dot-vote's operator commands — `setnextmap`, `nominate_addmap`, `forcertv`, `votereload` — existed here; the module's own `nominate`, `nextmap` and `timeleft` stood in for three of the players' ones.

`G2GVote.install_commands` puts `DotVoteCommands` on the module, `vote` keeping its name so `!vote 2` still works. The chat handler claims `!rtv` and `!vote` only when the vote failed to load, so an unclaimed line reaches the console's — one path. `g2g_rtv` is the ballot's rock-the-vote too, and `G2GNetBridge.rtv_fn` sends a client's request there. Without a vote, `rtv` is registered as the map session's tally, which is then the only rock-the-vote there is.

**The map session's clock no longer ends a map when there is a vote.** It ran beside the vote's at the same length, and on expiry changed to the rotation's next map — so a map the players had voted to *extend* was ended on the old clock anyway. `G2GGame.rotation_ends_maps` is off once the module has a ballot; the session's clock still counts and decides nothing.

**And the HUD's time left is the vote's clock, not the session's (2026-09-24).** The status line drew `game.maps.time_limit`, which on a client is a clock the client started when it loaded the map and nothing the server decides ever reaches — so an extend added ten minutes on the server and none on any screen, and under `trigger: rtv_only` it counted down a limit the server did not have. `G2GVote.advance` keeps a `DotVoteClockView` of what every client believes and emits `clock_due` only when that belief is stale — an extend, a new map, a clock stopped for a ballot — so a quiet map sends nothing; the module puts it on the wire as `G2GEvents.Kind.CLOCK` (last, after VOTE), and a joining peer is told the current one in `_admit` through `G2GNetBridge.clock_fn`. The client's bridge adopts every CLOCK into one `clock_view` the HUD holds and counts down between messages. **No clock at all is drawn when the vote has none** — no "no limit", the slot is gone — and a HUD nothing has told (offline, where the local session is the real clock) keeps the session's. `headless_net`'s **the vote's clock over the link** extends a real `G2GVote` and asserts the client's number moves by the extension, that three quiet seconds send nothing, and that an rtv-only vote with no limit leaves no clock on the HUD; it was armed by making the view never stale on a count, and the extend check fired. `tools/screenshot_hud.sh` has `hud_clock` and `hud_no_clock`. The server's own `describe_lines` "time left" reads the vote's clock too since the same day — see below — and a client shell exported before `DotVoteClockView` existed cannot load this client — the shell needs a rebuild before this game's pack is published.

**`g2g_status` says the vote's time left, and "no limit" when the vote has none (2026-09-24).** `G2GGame.describe_lines` read `maps.time_limit` after the vote had taken the map's end over, so an operator asking how long was left was told a limit an extend had already moved — the HUD's bug, one screen over. The game does not know the vote exists, so the module hands it `G2GGame.clock_fn = vote.clock_state` beside `rotation_ends_maps = false`, and `time_left_text()` reads that: `m:ss`, `(stopped)` while a ballot holds it, `no limit` with no clock — words here where the HUD shows nothing, because a status line is read when somebody asks and a missing row reads as a diagnostic that forgot. A server with no vote keeps the session's, which is then the real clock. `dedicated` extends the vote through the console's view and asserts the line moves by the extension while the session's clock does not, and that rtv-only with no duration says `no limit`; armed by putting the old line back, three checks fired.

**The vote's cues reach the client.** `G2GVote.cue_due` carries each `cue` and countdown second, the module broadcasts it as `G2GEvents.Kind.VOTE`, and the client plays it through `G2GPresentation`'s catalogue — on voices the run does not use, and below the timer's four in priority, because a ballot opening must never cost a runner the sound of their own split. No countdown before a ballot here: a runner is not in a fight. `dedicated` asserts the reply to `!rtv` and `g2g_rtv` is the ballot's (its delay) rather than the session's (a tally), and `headless_net` sends a cue, a second and an RTV request across the link.

A timer server has no leading score, so nothing here calls `note_score`; `trigger: score_limit` is a setting this game has no use for.

## No message preloads itself

`g2g_event.gd` and `g2g_request.gd` each began by preloading themselves, for a typed `of()` factory. mg-buses-from-hell measured that line (8ed866c) as enough to leak the whole script graph at exit on Godot 4.7.2: a script that `extends DotNetMessage` and preloads ITSELF, first loaded by a module inside a running `DotServer` — which is how every deployed server loads a game. Both are built with `new(kind, body)` now, an `_init` whose arguments default because dot-net's registry decodes with a bare `new()`.

`dedicated`'s last section, **exiting clean**, reads every `DotNetMessage` script under `game/` as text and fails on a self-preload. It is on the source deliberately: the leak is printed by the engine after `quit()`, where no assertion can reach.

**Here it was not the cause, and the leak is still open.** `dedicated` exits with 407 ObjectDB instances, 303 resources, a VariantPools page and six dummy material, shader and texture RIDs — exactly as many before the change as after (2026-09-23). `--verbose` shows the same "every script still loaded" shape buses had (324 `GDScript`s, 55 native class wrappers), so something else is holding the graph up. The one self-preload this game has that buses does not is `g2g_browser.gd` (`extends Node`); it has not been tried.

**`g2g_browser.gd`'s self-preload has been tried now (2026-09-24), and it was fifteen objects of it.** Removing it took `dedicated` from 411 to 396. The same run ruled three more out: `g2g_paths.gd`, `g2g_net_command.gd` and `g2g_net_link.gd` also preload themselves, and removing all three together moved the count by nothing. The rest of what holds the graph is not a self-preload.

**What 9515974 added was two scripts, not two objects a Callable held.** `dedicated` went 409 → 411 with that commit. The game half (`clock_fn = vote.clock_state`) moves nothing — the new code under the old suite leaks 409 — and a `--verbose` diff of the two runs is exactly two more `GDScript` instances, `dot_vote_rules.gd` and `dot_vote_clock.gd`, which the new check's typed `vote.director.rules`/`.clock` and `DotVoteRules.Trigger` load for the first time. Every loaded script is in the graph that leaks, so any check that names a new type adds to the count; untyping the check would lower the number and fix nothing. The remaining non-script instances are the static caches — `G2GTextures._materials`, `_grid`, `_installed` and `G2GCombat._shared_catalogue`, which are the four material, one shader and one texture RID lines — and clearing them at exit takes 14 more off; they are process-lifetime caches by design and are left.

## A map change is announced, and then made

This game had the ad-hoc version dot-map's protocol was written to replace: `G2GNetBridge._on_map_ready` broadcast a map id from `map_ready` — which fires **after** the server has already swapped — and HELLO carried the same id for a joiner. A client changed to it by id out of its own build. Nobody asked whether it had the map, nothing fetched one it did not have, and a client that could not load it stayed on the old world while the server simulated it on the new one, with nothing on either end aware of it.

It is `DotMapSyncHost` and `DotMapSyncClient` now, carried over dot-net: a host message is `G2GEvents.Kind.MAP` to one peer and a peer's answer is `Ask.MAP`, both a `DotMapMessage` as JSON inside a byte cap (4096 from the host, 256 from a peer, because the second is what a client can make the server parse). The bridge builds the host half and hands it to the game as `G2GGame.map_sync`; `G2GGame.change_map` goes through it on a server, so `map`, `g2g_map`, the vote and the rotation's clock — which all already called `change_map` — announce, wait and then swap without knowing it. HELLO no longer carries a map at all: the map a joiner lands on arrives as the protocol's own announce, right behind it.

**JSON rather than a field-by-field encoding**, because dot-map owns these shapes. A game that re-encoded each field would silently drop whatever `DotMapDef.to_dictionary` gains next, until somebody noticed. JSON's one lossy step — an int back as a float — is one `from_dictionary` already undoes. A message too large for its cap is refused whole with an ERROR rather than cut, because `DotNetWriter.write_string` truncates without a word and half a JSON document looks, on the far end, like a hostile host.

**A built-in map is announced as one.** Its definition has no content id, the client finds it in its own catalogue, reports ready without starting a fetch, and nothing pretends it is a pack. `headless_net` asserts exactly that — no content id, nothing fetched, ready before the server swapped, and the change made as soon as everybody was ready rather than at the timeout.

**The wait is thirty seconds, not dot-map's three hundred** (`sv_map_sync_timeout`, `G2GConfig.map_sync_seconds`). The wait holds the whole server on the old map for its slowest client, and a timer server's players came to run. Missing it costs little: `swap_without_stragglers` stays on, the server tells the straggler, and the straggler follows the moment its download finishes. **The server does not kick it**, and the reason is that the server is authoritative — a straggler's inputs are simulated on the new map whatever its screen shows, so nothing it does there reaches a board. **A client that refuses leaves** (`G2GClient._on_map_refused`, with the reason): dot-map keeps a refusal silent to the host by design, so the client is the only end that knows it cannot follow, and staying would put a player on a world the server is not simulating.

**Running it found five things wrong in dot-map, and they are fixed there now** (dot-map's CLAUDE.md, "What the first transport found"). For a day the bridge carried a workaround for four of them, and each was armed here before it went: it answered a joiner's `ready` with a `load` itself, because a host only sent `load` at the end of a change (`headless_net`'s handshake fired without it); it held a joiner mid-change back until the change settled, because `_wait_for_peers` counted every peer and not the ones the change was announced to (5,029 ms against a 5 s timeout instead of one poll); it thinned progress to four a second, because dot-net's server drops a client's excess messages without asking which, and a burst could cost the `ready`; and it fetched a delivered map by its own convention before dot-map saw the announce — then had to queue every map message behind that fetch, because a straggler's `load` overtook it and was dropped. All of that is gone from the bridge; `admit_peer`, the change's peer snapshot, `progress_interval_sec` and dot-map's own hold on a `load` that overtakes its fetch do it, and the same `headless_net` checks pass against the addon.

**What is left is the one decision that is this game's: the imported-map scene is a trusted template.** Every imported map is one scene in the build pointed at a manifest (see *Maps are dropped in, not listed*) — the mount constraint forbids putting a scene that extends a build class in the pack — and dot-map's rule for a map a client does not have was that its scene is in the pack, so it would have refused every delivered map this game has. The client now lists `G2GMapCatalogue.IMPORTED_SCENE` in `DotMapSyncClient.trusted_template_scenes`, and dot-map then requires the **manifest** (`meta.manifest`), and any other path the definition carries, to be inside `res://dot_cloud/<content>/<version>/`. A server marks a map it fetched into a mount as that content and version (`G2GGame._mark_delivered`, off the mount directory, so there is no second record to disagree with it); a map on the server's own disk stays local, and a client that does not have it refuses it. **That is narrower than the workaround was:** the bridge's prefetch asked the client's origin for ANY unknown id, so a map an operator dropped into the server's `user://maps` still reached a client whose origin happened to carry the same id. Now a map a client can be sent is one the server itself got from the content origin — `content_maps`, or `map <id>` on an id the catalogue lacks — which is also the only case where the two ends are known to mean the same bytes by one id. The client fetches from its own content client and origin and verifies against its own keys; the host still says only which map. `headless_net`'s *an imported map that is delivered* publishes a signed pack, has the server fetch it the way it fetches `content_maps`, and asserts the client loads the imported-map scene out of its own build from the manifest in the pack; armed by removing the template from the bridge, and again by removing `_mark_delivered`, and it fired both times. **One limit worth knowing:** the template is matched by exact path, so a client and a server must agree on where `imported_map.tscn` is — which they do when both run the same game pack, and would not with a server run from source and a client on the pack.

**What running it found that was not the protocol.** `G2GCombat._on_map_ready` has called `DotMatch.remove_spawn_point` since 2026-09-10, and dot-match has never had one. The first map has no points to remove, so the call only ran on the second map change on a server with the combat layer built. It raised a script error that aborted the function before it added the new map's points, so the deathmatch kept respawning players on the previous map's pads. `dedicated` had never changed map twice with combat up. Its unload section now does, and asserts that the points are the new map's, which fired with the old line put back. And **M changed the map on a networked client** — that client's own world, and nobody else's — so the server corrected the player into geometry their screen no longer had, every tick. It is offline-only now; online it says `!rtv`. (Since 2026-10-08 M is the map list, and online it asks the server, which checks the changemap flag: see the last section.)

## Things deliberately not here

- **A second transport.** The bridge speaks through `DotClientLink`'s RPCs on one
  `MultiplayerAPI`; browser and desktop clients on one server is the family-wide gap
  in PLATFORM.md.
- **A sandbox.** There are practice blocks now (`sv_props`), and they are deliberately
  not a sandbox: frozen on placement, admin-only by default, and a run made while
  anything is placed cannot be ranked. game-playground is the sandbox.
- **A chat window.** `DotChatClient` holds the history, the channels and the unread
  counts on the client the moment anybody writes a screen for it; what a player gets
  today is the HUD's notice line.
- **A server browser SCREEN.** The browser itself is wired in and asks a real
  `DotServer`; what it draws is a chat listing, and a table a player can click a row
  of is a `DotScreen` and a stack this client does not have.
- **A master server.** `DotBrowserSourceBackbone` reads a listing that nothing is yet
  publishing, and there is no heartbeat — so a browser here finds what somebody typed
  into it and nothing else. That gap is the family's, not this game's.
- **A kick for a client that missed a map change.** dot-map leaves the straggler to the game and dot-server kicks one that misses a GAME change; this game does neither. A straggler still downloading follows on its own, and one that refused the map is the one end that knows it, so it leaves. See "A map change is announced, and then made".
- **A texture set for the hand-built maps.** `G2GTextures` generates a prototype grid
  and the hand-built maps draw in it. `res://textures/prototype/` holds an installed
  set, and **the imported `.bsp` maps are the half that uses it** — see Decision 11.

  **Kenney's prototype kit is installed, and it draws the imported maps only.** That
  split is the second measurement of it, and it went the other way from the first for
  one half. The entry here used to say the kit was a downgrade, on two findings:

  - **The tint is a MULTIPLY**, so the source has to be light, and Kenney's *Dark* set
    is a dark base with light lines that multiplies to nearly black. **This one is
    solved rather than lived with.** An installed set carries its own colour per role —
    the vendored one spends a whole colour on each — so nothing tints it; the multiply
    only ever applied to the greyscale grid, and `material_for` says so now.
  - **The *Light* set is too low-contrast at this tiling**, and that finding stands. It
    was re-rendered on `surf_g2g_intro` beside the generated grid and it is still worse:
    a near-flat saturated panel whose white lines are gone by mid-distance, under six
    brand colours rather than a palette — a mint floor beneath a magenta ramp. A
    movement game whose floor has no readable scale is harder to play, not prettier.

  The two halves of the game are not the same pipeline, and that is why the answer
  differs. A hand-built map is a sunlit `StandardMaterial3D` over a large plane, which is
  what `grid_texture()` was designed against. An imported map is unshaded through the
  lightmap its own compiler baked — which breaks a flat tile up for free — and, more to
  the point, **its alternative is not the grid, it is no texture at all**: a flat role
  colour over 97% of the map. Against that, the kit is not a close call.

  What would still be better for the hand-built half is a light, high-contrast set whose
  line weight survives the tiling. The generated grid is the specification for that.


## `the needle`, and the first route here a bot runs end to end

`bhop_g2g_intro` bonus 2 is ten blocks at a constant 96-unit gap whose width closes from 192 down to 48, with two stage splits on it. Everything else on this map is about SPEED: the main route's gap grows until only a player who kept the last block's momentum crosses it, and bonus 1 is a warm-up. The needle asks for none of that and is still hard, because a block 48 units across is 16 units wider than the player and the whole of it is aim. It is also the practice route this map did not have, for the player who cannot yet chain hops and was refused by everything here at the tenth block.

**A constant gap is the one shape a scripted bot can complete, and that is why the route is shaped like one.** A bot cannot strafe, so it cannot gain, so any route that demands a gain is a route no check can ever drive from a start line to a finish. Every other bonus in this repository is checked by putting a bot on the pad, driving it, and asserting where it ENDED. `headless_run` drives this one through both stage splits into the finish zone, which means the geometry, the zones, the splits and the end line are all proved by something other than reading them: a block moved 100 units fails this and fails nothing else anywhere.

**Two numbers were measured rather than chosen, and both are worth keeping.**

**96 rather than 160.** At a 160-unit gap a hopping bot carried the prestrafe across two gaps and fell at the third, every time. A chained hop takes off wherever the last one landed rather than at the lip, so the distance actually available is the jump minus however far onto the block the bot arrived, and that margin bleeds a little every landing. *A gap a standing jump clears is not a gap a chain of them clears* — which is the number the main route encodes in its first block and nowhere says out loud.

**Jumped AT the gaps, not held.** A bot holding jump with `sv_autobunnyhopping 1` leaves the ground on the tick it lands, so `accelerate` never gets a grounded tick and there is no strafe to gain with in the air: it bleeds to `sv_maxairwishspeed`, which is 30 u/s, and 30 u/s clears nothing on this map. `_needle_jumps_at` presses jump only in the last thirty units of a block, which keeps the bot grounded for the rest of each one — and it reads the window out of the **map's** constants, so moving a block moves the jump with it.

That matters beyond this route. `_test_bhop_run` asserts a top speed of 240 u/s while holding jump, and that number is the **prestrafe** being carried into the first hop rather than anything hopping achieved. The check is true and it is not evidence that the bot is running.

## `the ridge`, and the second route a bot runs end to end

`bhop_g2g_stages` bonus 2 (2026-09-24) is the stages map's practice line: five blocks climbing 24 units each, a crest of four that narrows from 176 to 80 units, and five drops of 48 onto a finish pad 168 units under the start, with a stage split on the first block of the crest and the first block of the descent (drawn in the finish colour, as the main route's are). It sits at x = 3072, between the main course and the surf bonus. Every gap is a **RUN** gap, sized with `G2GReach` and at least 29 units inside it — 128 onto +24 against 166, 160 flat against 189, 192 down 48 against 222 — so it asks for a climb, a line and a drop and never for speed a player has not got. `RIDGE_SECTIONS` and `ridge_blocks()` are the one list: the geometry, the zones and `headless_run`'s bot read it, and the bot jumps in the last twenty units of each block read off it. `_test_ridge_bonus` drives it from the pad through both splits into the finish with no reset: 17.60 s, 0 resets, top 250 u/s. Render: `tools/route_preview.sh bhop_g2g_stages 2`.

## `the weave`, and a route whose line is not its shape

`bhop_g2g_stages` bonus 3 (2026-09-28) is fourteen blocks, each off to the other side of the one before: six level (gaps 96 to 128), four climbing 24 each (96 to 104), four dropping 48 onto blocks narrowing 128 to 96 (128 to 160), then a 160 gap down 48 onto a finish. Stage splits on the first block of the climb and of the descent, drawn in the finish colour. It sits at x = 9216, east of the surf bonus, with its own pad, spawn and pit. `WEAVE_SECTIONS` and `weave_blocks()` are the one list for geometry, zones and bot; blocks are 192 u long (`WEAVE_BLOCK_LENGTH`), not the map's 160, because the turn is made on them.

**The blocks zigzag and the line does not.** Each block's inner edge reaches the centre line, so the fast way through clips every inner corner and is nearly straight, while a runner who follows the blocks' centres swings 128 u every block and has to turn on each. That is the question the route asks: see the line. It took three drafts, measured each time by driving the bot. Centres 192 apart on 160 u blocks put the next landing 37 degrees off the run, and the bot came down 20 u wide of the second block every time. At 160 apart it reached block 4. Only once the inner edges met the line did a runner that aims at the next block reach the end. A bot cannot strafe, so what it proves is that the route flows at run speed, not that it is hard.

`_test_weave_bonus` aims 32 u inside the inner edge of the block it is jumping for, 48 past its near edge, keeps that block as its aim until it lands, and jumps in the last 20 u before its line leaves the block it is on. It drives pad to finish through both splits: 19.12 s, 0 resets, 245 u/s against a run of 250, and the pace is asserted (at least 80%), so a route that only works at a crawl fails. Armed with the first draft's 96 u offsets, the bot reaches block 3 of 14 with 6 resets. The survey reaches all 33,757 standable cells with no slots. Render: `tools/route_preview.sh bhop_g2g_stages 3 out.png 20 30 0`.

**Building it found that three of this file's own route checks could not fail.** The needle's, the ridge's and the hairpin's bots counted resets with `var reset := false` set inside a signal lambda, and a GDScript lambda captures a local by value. So `reset = true` never reached the loop, and "without ever being put back" passed whatever happened. The weave's first draft respawned at tick 548 and the check still said 0. All four use `var reset: Array[bool] = [false]` now. The three existing routes really do run with 0 resets.

## `the bend`, and a route that never stops turning

`bhop_g2g_stages` bonus 4 (2026-10-02) is ten blocks round a 640 u left-hand arc from a pad at x = 12288, east of the weave: four level, three climbing 24, three dropping 48 onto blocks narrowing 144 to 112, then a 128 gap down 48 onto a finish 120 u under the start. Every block is turned to face along the arc (`Basis` yaw, as the main route's turn), so each take-off is aimed somewhere the last landing was not facing, and the finish faces across the start 277 degrees later. Stage splits on the first climb block and the first descent block, each restart facing on round the arc. `bend_blocks()` / `bend_pad()` / `bend_at()` are the one copy of the arithmetic; the geometry, the zones and the bot read them. Zones on a turned block are boxes INSIDE its footprint (the largest square any yaw keeps inside it), because a zone is axis-aligned. Reach sweep: RUN, 11 jumps, widest 146 u down 48 against 222.

**The drops are 30 degrees apart and the rest 22.5, and that was measured.** The first draft spaced every block 22.5 degrees (centres 250 apart, 85 u gaps): a 48 drop at the speed the climb leaves carried about 230 u, landed on the last 10-20 u of a 160 u block, and the next take-off, from its edge and turned 22.5 degrees, went off the side of the last block -- the bot reached block 9 of 10 and was reset twice from it (`from piece 8 at (11207, 727)`). At 30 degrees it finishes.

`_test_bend_bonus` reads each piece in its own frame (`_bend_local`: the bot's offset rotated by the block's yaw, so "standing on it" and "distance to its lip along my aim" are a rectangle test again), aims 32 u short of the next block's middle, and jumps in the last 20 u before its line leaves the block it is on. Pad to finish through both splits: 12.20 s, 0 resets, 254 u/s against a run of 250, pace asserted at 80%. Armed by the 22.5-degree draft above, which failed four of its checks. Frames: `~/stack/nightly/archive/screenshots/2026-10-02/g2gfast/bend_{overview,spawn}.png`.

## `the hairpin`, and the first route here a bot has to steer

`bhop_g2g_intro` bonus 3 (2026-09-27) is the one route on this map that turns. From a pad at x = 2304, east of the warm-up, it goes out four level blocks along -Z (gaps 112 to 160), onto a 256-square corner, right along +X up four 24-unit climbs (gaps 96 to 128) onto a second corner 24 higher at 120 u, right again, and back along +Z down four 48-unit drops onto blocks narrowing 160 to 96 (gaps 128 to 192), then a 160 gap down 48 onto a finish at -120 u beside the start. 14 blocks, 15 jumps, about 4,700 u of centre line. The two corners are the stage splits, drawn in the finish colour as the ridge's are, and each split's `!s<n>` faces the way the route LEAVES the corner (yaw -90, then 180: `yaw_facing`), never `[stage-yaw-1]`'s back-up-the-course 180. Every gap is a **RUN** gap at least 29 u inside `G2GReach` (160 flat against 189, 128 onto +24 against 166, 192 down 48 against 222) because a corner spends the speed a chain would be carrying. `HAIRPIN_LEGS` and `hairpin_blocks()` are the one list: geometry, zones and bot.

`_test_hairpin_bonus` is the first bot here that is not holding forward along -Z. It reads `hairpin_blocks()`, aims through the middle of the edge the block it is over is left by, jumps in the last twenty units before that edge, and once past the lip aims at the next block's exit (aiming at a point just past the lip, it hovered there and fell: a bot that has reached its target stops). It drives pad to finish through both splits: 17.76 s, 0 resets, 4,858 u covered (including the 400 u from the spawn to the pad's edge) against a 4,688 u route. Armed by widening the jump onto the top corner to 200: the reach sweep, the zone-file match and three of the bot's checks fail. Render: `tools/route_preview.sh bhop_g2g_intro 3` (and `... 3 out.png 25 45 40` for the whole U from above).

## `the stutter`, and a route whose blocks are not one length

`bhop_g2g_intro` bonus 4 (2026-09-30) is a straight line at x = -1280, west of the needle, whose rhythm changes: every block is either a 96 u **stone** or a 224 u **runway**. Three flat stones and a runway; four rollers (up 24, down 24, alternating) onto a runway 24 u up; then five drops of 48 onto stone, stone, runway, stone, stone, and a 160 gap down 48 onto a finish 264 u under the start. The two runways that end a section carry the stage splits, in the finish colour. 14 blocks, 15 jumps. `STUTTER_BLOCKS` (gap and rise into each block, its length, width and split) and `stutter_blocks()`, which returns the hairpin's block shape, are the one list for geometry, zones and bot.

**A stone is sized from the reach, not inside it.** A jump from the lip at run speed lands a fixed distance on (`G2GReach` RUN: 189 flat, 166 onto +24, 222 down 48), so each stone's gap puts that landing 40 to 60 u onto 96: 128 before a flat stone, 112 before a step up, 144 before a step down 24, 160 before a drop. On a stone the next jump goes almost as the player lands, and on a runway there is time to get the speed back. Nothing else on this map asks a player to change the period of their hops mid-route.

`_test_stutter_bonus` holds -Z on the route's centre line and jumps in the last 20 u of whatever it is on. It asserts the bot **stood on every one of the 14 blocks** (grounded, over its footprint, at its height), both splits in order, 0 resets, the finish on track 4, and a pace of at least 80% of run speed: 15.68 s, 250 u/s against 250. Armed by shortening one flat stone to 48 u (zones re-exported, so only the bot could see it): the bot overshoots it. The survey reaches all 9,572 standable cells on the map. Render: `tools/route_preview.sh bhop_g2g_intro 4`.

## The bonus tracks had no respawn zone

A `DotTimerZone` carries a track, and a RESPAWN zone on track 0 catches nobody running track 1. `bhop_g2g_intro`'s main route has had one since the map was written and **neither of its bonuses had one at all** — so a player who missed a bonus platform fell out of the world for ever, with nothing in the log to say so, while the identical mistake on the main route put them back on the pad. Found by driving a bot off the needle: it was still falling 1,370 metres down.

`surf_g2g_intro` was given per-bonus respawn zones when its second bonus was added, and `headless_run.zones_have_respawn_on_bonuses` was written at the same time — **asked on the surf map only.** So the guard existed, passed, and was never once pointed at the map that was broken. It is asked on this map now too. Same shape as the stale copied list this tree has had in `setup.sh`, both check scripts, both bootstraps and `tools/export_zones.gd`: the fix went to one place and the question was never asked of the others. **And it happened a third time**: `bhop_g2g_stages`' surf bonus had a start, a finish and a spawn and no pit, because the helper was asked of whichever map a section had loaded and no section loads that one. The helper is gone; dot-timer's `DotTimerZoneSet.route_problems()` (`[track-zone-1]`) asks every route for a start, a finish, a spawn and a pit of its own, `_test_zone_files_match` asks it of every hand-written map, and `headless_imported` of every imported one — where four maps' bonuses had no pit at all, because the importer put every teleport on the main track. `[track-zone-2]` fixed that on 2026-09-24: `pit_tracks` gives a leftover teleport to the track whose START its destination is in, since a fail teleport sends a player back to the start of the route they fell off. bhop_pit b1, surf_arcade b1, surf_beginner2 b1-4 and surf_summit b1-2 have pits now, `BONUSES_WITHOUT_PITS` is empty and still asserted both ways, and `tools/export_zones.gd` fails on `route_problems()` too.

## What a jump reaches, asked of the three hand-written maps

`[reach-1]` asked this of game-playground and game-arena and both were wrong: a jump course unfinishable past platform three, and three maps of routes nothing had ever climbed, under suites that passed throughout. Asked here, **every jump the three maps declare is inside reach** — and the question found two things the maps' own comments never said.

**This genre has two reaches, and a gap is sized for one of them.** `G2GReach` holds both, read off the `DotFpsTunables` the server applies rather than off copied constants, so `sv_gravity` and `sv_enablebunnyhopping` move every answer with no second number to update. Since `[reach-3]` (2026-09-27) the apex, climb limit, airtime and RUN reach are `DotFpsTunables.jump_apex`/`climb_limit`/`jump_airtime`/`jump_reach` asked in metres and converted by `G2GUnits`; only the CHAIN (`hop()` and what is built on it) is this game's own arithmetic. Every number came out identical to ten decimal places:

- **RUN** is a jump from the lip at run speed. Ground acceleration gets a player back to 250 u/s in about thirty units, so anybody who lands anywhere on a block can run to its edge and take it however badly the last hop went. It clears **189 units flat, 166 onto a 24-unit step, 222 down 48** — the landing height is the whole point, because the airtime everybody writes down is the time back to the height you left.
- **CHAIN** is a hop inside a run of auto-hops, and it is a different quantity rather than a longer one. With the key held there is no grounded tick to walk to the lip on, so a hop takes off where the last one landed and the hops have to average a whole block period — the gap *and* the block. Speed is what makes a period, and strafing is the only thing that makes speed, so a chain is judged by simulating it with a perfect strafe every tick (`v² + 30²` a tick, which is `DotFpsMotor.accelerate`'s own arithmetic). **That is an upper bound on purpose**: a chain it refuses is one nobody can run, and how much of a perfect strafe a chain needs is printed rather than asserted, because that is the number that says how hard it is and no threshold on it would be anything but a guess.

**A map declares which bodies are a route and which reach it is for, and nothing else.** `G2GMap.add_course(name, track, kind, bodies)` is called from `_build` with the bodies `G2GGeometry.box` just returned; the rise, the clear air and the landing depth are read off their transforms and box shapes. That is game-arena's `climbs` pattern, and it cannot drift from the geometry because it IS the geometry — widening the needle's gap to 200 fails nine routes, and a 60-unit climb step fails seven. The clear air is the least distance between the two footprints, not game-arena's larger axis gap, because the stages map's zigzag is 80 units across as well as the gap along and the player flies the diagonal. No hull credit is spent anywhere: the capsule can stand about eleven units past a lip on this slope limit, and that is the margin.

What `headless_run` prints, all passing:

| course | reach | widest | needs |
| --- | --- | --- | --- |
| `bhop_g2g_intro` main | CHAIN, 17 hops | 288 | 44% of a perfect strafe |
| `bhop_g2g_intro` warm-up | RUN, 3 | 128 | inside 189 |
| `bhop_g2g_intro` the needle | RUN, 11 | 96 | inside 189 |
| `bhop_g2g_intro` the hairpin | RUN, 15 | 192 down 48 | inside 222 |
| `bhop_g2g_intro` the stutter | RUN, 15 | 176 down 48 | inside 222 |
| `bhop_g2g_stages` main | CHAIN, 40 hops | 288 | 54% |
| `bhop_g2g_stages` the ridge | RUN, 15 | 192 down 48 | inside 222 |
| `bhop_g2g_stages` the weave | RUN, 15 | 161 down 48 | inside 222 |
| `bhop_g2g_stages` the bend | RUN, 11 | 146 down 48 | inside 222 |

`surf_g2g_intro` declares nothing, and says why in its header: every way from one surface to the next on it is a drop onto something below, and only riding it answers whether the thing below is there.

**`!s2` and `!s3` on `bhop_g2g_intro` put a player where nobody can continue.** A stage restart is a chain that begins at run speed rather than at whatever the stages before it built, and from blocks 10 and 14 the gaps ahead need more than even a perfect strafe adds in the hops available — from 14, the next gap is 275 units and a perfect single hop from 250 u/s covers 245. `!s1` needs 78%; the stages map's four restarts need 49% to 81%. The restarts are printed and **not** asserted: they are the same three destinations `[stage-yaw-1]` is already waiting on Christian for, and the only fixes are moving a stage line on a scored track or putting `!s3` somewhere that is not stage 3.

**And with `sv_enablebunnyhopping 0`, neither bhop map's main route exists.** The landing cap trims every take-off to 275 u/s, one hop of strafing cannot span the period, and `bhop_g2g_intro` falls at its sixth gap and `bhop_g2g_stages` at its fourth. That is asserted, which is also the proof the chain arithmetic refuses something rather than approving everything. An operator turning the cvar off is turning these two maps into the needle and the warm-up.

## `surf_g2g_intro`'s single bank, driven from its pad into its finish

Bonus 1 is now run end to end, which closes this repository's half of `[bonus-run-2]`. The bank is level along its length, so nothing but the entry speed carries a rider down it and gravity pulls them toward its low lip the whole way; `_test_single_bank` holds strafe into the bank while the bot is below a line and lets go above it, and never touches forward. The line is read off the map — `bonus_bank_lip_x()` plus a hull width — which is why bonus 1's numbers are named constants now rather than literals in `_build`. It asserts the run starts, the bot reaches the bank's far end, and it lands in the finish **without being put back**; nothing in it can pass on a respawn, which is the failure `[bonus-run-2]` found the transfer's check committing. Shortening the bank fails two of the three.

**The `[surf-ramp-1]` answer for this route is the same as the main run's.** The bot loses under 150 units of height on the bank — the drop onto it and the line it holds — and then falls 753 onto the pad. The descent of this route is the fall off the end of the bank, not the bank.

Two things driving it found, and neither is fixed here:

- **A surfer holding into a bank used to freeze in mid-air with its speed intact, and dot-player-controller 94f1c87 removed it.** At several lines the bot stopped dead within a few hundred ticks and never moved again, `velocity` still 222 u/s and `DotFpsMotor.duplicate_plane_ticks` rising one a tick — the duplicate-plane early-out, on a flat hand-built bank: 708 stalled ticks of 1,815 even on the line that worked. Re-measured 2026-09-24 from a standstill spawn (a throwaway probe riding eleven lines): no line freezes, the longest motionless run is 7 ticks, and a ride has 1 to 35 duplicate-plane stalls. Lines +8, +16, +24, +64 and +96 units from the lip finish in 1,299 to 1,676 ticks. **+32, where the bot rode, and +48 do not, and it is a different stall**: the rider loses its forward speed mid-bank (254 u/s along the bank to 0, at z -1397 and -276), hangs against the bank ungrounded with about 10 u/s of jitter, and never moves on. +32 finished in the suite (1,318 ticks, 2 stalls) only because the sections before it leave the bot about 30 u/s of sideways drift and a different yaw; the tunables were dumped in both and are identical. The bot rides +24 now, which finishes from both states: 1,313 ticks and 3 stalls in the suite. The hang is dot-player-controller's, and it is queued (`[bank-hang-1]`). Lines +128 and wider cannot be reached from the pad at all: the bot walks off it first.
- **The finish only catches a slow rider.** Only the strip of bank between its lip and the pad's far edge lies over the pad, and the end zone is 512 units deep and tops out 455 units under the line the bot rides — so a rider leaving the bank faster than about 470 to 590 u/s, depending on where on that strip, passes over the whole zone and lands in the pit. A bot holding forward-and-right, which is a real strafe, left the bank at 866 u/s and was put back from 1,578 units past the pad's far edge. On a surf route, going well is what fails it. Not changed: it is a scored track, and the two fixes — a longer pad and zone, or a taller zone — respectively leave every existing time comparable and make every future one faster than it, which is Christian's call.

## Every hand-built map, surveyed for slots, unreached ground and traps

`[gate-sweep-1]` and `[gate-sweep-2]`, as a rule over the box list rather than a question about one gap (2026-09-27). `G2GMapSurvey` is game-playground's `PlaygroundMapSurvey` reimplemented in genre units, and `headless_maps`' last section runs it over every hand-built map the catalogue finds, after a built-in bad map that has one of everything it looks for. Per map it asserts: every spawn and `!s<n>` destination lands on standable ground; no two solids leave a slot narrower than the hull; nothing standable is out of reach of every start unless declared, and no declaration covers ground that is reached; nothing a start reaches is a place with no way out (a finish, a pit, a spawn); every declared CHAIN course is a way forward; and the tilted slabs a player can stand on are exactly `STANDABLE_RAMPS`.

**The numbers are the tunables' own, in units.** The hull is `2 × radius`, **32 u**, which is the genre's hull and what the motor collides with; the headroom a crouched player's 54; the step 18; the slope limit 45.57°; a jump is `G2GReach`'s RUN reach and climb limit. The grid is 16 u, half the hull, so a cell's eight neighbours are the hull.

**A CHAIN course is linked body to body when `G2GReach.chain` says a perfect strafe runs it**, because the main routes' gaps (up to 288 u) are past any RUN jump by design. Without those links both bhop maps' main routes are unreached past their first wide gap, which is how the links were armed.

**What reach means on a surf map, and why the survey stops short there.** A surf ramp is steeper than anybody can stand on, so it has no cells: it is slid on, not stood on. Where a rider on one gets to is decided by their speed, and on a ramp speed is the rider's to make, so any bound on it is either "everywhere" or a guess at skill. The survey floods only what needs none — walking, a step, a drop, a RUN jump, and a slide straight down a face's fall line off its low edge — and a surf route whose next surface is reached by a carried flight reads as unreached and is declared, naming the check that rides it. The standable parts (pads, the valley floor, platforms, finishes) are surveyed fully. On `surf_g2g_intro` that leaves exactly one such flight: bonus 1's finish pad, reached off the end of the bank, which `headless_run`'s single bank rides with no reset. The other three declarations are the start pad's back-wall top and two banks' high lips (a 60° slab's 32-u edge face is 30° from level and standable, and nobody is sent there). They live in `headless_maps._survey_declared` rather than on the maps for now; moving them onto the maps, as game-playground has them, is the next step once nobody else is editing those files.

What it found, per map (all passing now):

| map | standable cells | reached | regions | course links | declared |
| --- | --- | --- | --- | --- | --- |
| `bhop_g2g_intro` | 9,572 | all | 63 | 8 | 0 |
| `bhop_g2g_stages` | 31,589 | all | 60 | 16 | 0 |
| `surf_g2g_intro` | 31,373 | 29,715 | 42 | 0 | 4 |

No slot under 32 u and nothing trapped on any of the three. Two real findings:

- **`the fall line`'s `!s1` and `!s2` put a player under the chute, and they fell into the pit.** The destination was 64 u over the bed's centre line *at the stage line* but placed 128 u uphill of it, where the bed is 152 u higher — so the player's feet were 113 u under its surface. Driven: dropped from each destination, a bot fell 2,300 to 3,450 u into the pit and was respawned. Fixed (destinations only; no geometry, no zone volume moved): `fall_point(t - 128 / FALL_RUN)` plus 64, and driven again, both slide the bed into the finish zone.
- **`bhop_g2g_stages`' surf bonus was two 45° slabs, under this game's 45.57° slope limit**, so both were floors and a bot dropped onto one stopped mid-slope. **Steepened 2026-10-06 (`[stages-slabs-1]`, Christian's call)**: `BONUS_RAMP_PITCH` (50) is the faces' steepness, map data, and the box turns by 90 minus it (the builder's angle is the box's turn, not the face's, which is how a first attempt at 50 made the faces 40). A rider drops onto the west face, slides into the crease between the slabs and glides along it onto the finish pad: `headless_run`'s stages descent asserts it now (3159 of 3200 u, 1406 ticks, all of it in the air), resetting the movement config first because earlier sections do not all put theirs back. **It lets go of the face in the crease between the slabs** (`CREASE_RELEASE`, 48 u): pressed into one slab with the other underneath, the motor's duplicate-plane early-out pins a rider there (`[bank-hang-1]`, dot-player-controller's), and whether the bot reached the crease still pressing depended on which sections ran before it: after the needle it sat 2803 u down with 1450 stalled ticks and failed the full run on 2026-10-07; alone, or after the ridge, it finished. `--only` takes a comma list now, which is how that was found. `STANDABLE_RAMPS` is empty, and the survey declares the slabs' high lips and the finish pad (reached by speed). The zones did not change.


## The triage of 2026-09-27, and the four causes it found

`[g2g-maps-1]` ("the surf and bhop conversions are still very bad") was answered by rendering all 26 maps before touching anything: `bsp_preview` from the spawn under the map's own environment (`GAME=1`) and `tools/route_preview.sh <id> 0 <out> 14 9 0 walk`, which is new -- one frame per waypoint the map itself states (spawn, each `!s<n>` arrival or, on a stageless map, each door's arrival nearest-first, then the finish's floor), facing the arrival and facing the next waypoint. `route_preview` had never built an imported map at all (it did not call `build_from`, so every frame was sky). 404 frames, looked at as one contact sheet per map. The frames named in what follows are in `~/stack/reports/screenshots/2026-09-27/maps/`. **Grouping the defects by cause is what made it tractable**: four causes covered most of what was wrong, and several things that looked wrong were the maps.

**1. Two spellings the texture lookup missed.** A material typed with a leading slash (`/SURFACE`) was looked up as `materials//surface.vmt`, and a quoted `$basetexture` with a space in it (`"hammer textures/bhop_eazy/31_e_brick_blue"`) was cut at the space. Both fell back to the prototype grid with the texture in the pakfile: surf_interference 2% -> 99% of triangles in their own texture, surf_aquaflow 8% -> 97%, bhop_eazy 0% -> 100%, bhop_tesquo_v2 34% -> 55%. Found by asking every untextured material *why* (no VMT / VMT with no base / base not packed / blank), which is cheaper than looking at 26 maps for it. Frames: `fix1-material-slash_surf_interference_spawn_{BEFORE,AFTER}`, `fix1-basetexture-space_bhop_eazy_spawn_{BEFORE,AFTER}`. `headless_imported` fails a manifest material that keeps the slash and holds the three measured maps to 90% (`OWN_TEXTURES`); armed by reverting both, it fired on six maps.

**2. Static props.** 17 of the 26 maps place them and every one was missing: aquaflow's reef (737), greensway's forest (836), summit's trees and arches (976), interference's city (802), arcade's letters and cabinets (529). `tools/bsp_props.py` reads `sprp` (stride from the lump, not a version table), the MDL (materials, skin families, body parts, mesh vertex offsets), the VVD (LOD 0 with its fixup table) and the VTX (strip groups, whose header is 25 bytes in one generation and 33 in the next -- both are tried and the one whose indices land inside their arrays wins). Only models the pakfile carried; stock ones are counted. Three things measured on the way:

- **The leaf ambient cube is about a hundredth of the floor's light** (surf_mesa: cube 0.06 against a median luxel of 9.4) because vrad leaves direct light out of it; the engine adds the sun and the nearest lights per prop at load. Lit by the cube alone every prop was black (`fix2-static-props_bhop_pit_s9_cube-only-lighting_BLACK`, `..._surf_mesa_door2_cube-only-lighting_BLACK`). `GroundLight` adds the baked luxel of the floor under the prop -- which already is the sun and the shadows at the prop's feet -- fully from above, 0.7 from the sides, 0.25 from below. The result is written into the lightmap atlas as a 6x6 octahedral tile per distinct probe, and each vertex's UV2 is its normal inside that tile, so a prop goes through the same shader and the same exposure as the brushes and the game needed no new material.
- **`clean_material` stripped a cubemap `_x_y_z` suffix from any name**, so the mapper's own `models/corals/corals_1_5_8_9` became `corals_1` and 425,000 coral triangles were grey. Only vbsp's `maps/<map>/` names are stripped now.
- **Godot's convex hull builder kills the process on a flat piece** -- `Assertion "dot <= 0" failed` and signal 11 inside `build_from`, on bhop_interloper. Solid props (`solid` 6) collide as their `.phy` ledges, which are convex already; a ledge without four points off a plane is skipped, and a ledge whose points run past 1.5 times the model's drawn extent is a misread and dropped (two models of 346 on summit parse to 1e38).

Props are drawn in `Props` instances, not `World`, so `collision_probe`, `surf_probe` and `bhop_probe` never ask a tree whether it is a floor. They are not in the importer's `solids` list either: the pit rules were measured against brushes. Frames: `fix2-static-props_{surf_greensway_spawn,surf_arcade_s3,surf_aquaflow_spawn,bhop_pit_s9}_{BEFORE,AFTER}`. Checked: a map that placed props it carried draws some; armed by dropping the prop surfaces, it fired on all 17.

**3. The 3D skybox.** Ten maps have a `sky_camera`. Its room -- every leaf in the camera's area, boxed -- was drawn at a sixteenth of its size where it was compiled, and there was no backdrop. It is drawn now as the engine draws it, `scale` times larger about the camera (`world = (p - camera) * scale`, from the view origin the engine uses for the sky pass), in `Sky` instances: summit's mountains, aztec's canyon rim, lego2's city. Frames: `fix3-skybox_surf_summit_s1_{BEFORE,AFTER}`, `fix3-skybox_bhop_aztec_spawn_{BEFORE,AFTER}`. **surf_kitsune's is left out on purpose**: drawn, it is a black cage of `tools/toolsblack` around the whole map with the sky in the gaps (`fix3-skybox_surf_kitsune_REJECTED-black-cage`), and the reference frame shows open sky (`..._REFERENCE`). `"skybox": false` in a zones file does that, with a `skybox_why`; see `maps/zones/README.md`. Checked: a map draws `Sky` exactly when `lighting.sky_camera` (read by a second code path) says it has one and its zones file has not turned it off; armed by disabling the skybox, it fired. bhop_pandora2_fix (scale 512) and bhop_supernova (64) resolve to an area with no faces in it and draw nothing -- **fixed 2026-10-02**, see the next paragraph.

**A sky made of `prop_dynamic`s, and a scale past the far plane (2026-10-02).** pandora2_fix and supernova's sky rooms hold nothing but `tools/toolsskybox` walls and `prop_dynamic`s (pandora: clouds, two asteroids, two floating islands; supernova: two islands and `c4a1a_skybox_asteroids`), all packed, and the importer read static props only. `sky_dynamic_props` in `bsp_import.py` now takes the `prop_dynamic`/`prop_dynamic_override` standing in the sky room as static-prop records (never solid; one in the play space may be animated or toggled and is still left out). surf_aquaflow gains eight the same way. Then the scale: drawn into the world at the sky camera's 512, pandora's nearest asteroid was 5 km out and its islands past 20 km, all behind the game camera's 4 km far plane. The engine draws its sky in its own pass, where scale only sets parallax; here `sky_drawn_scale` keeps the mapper's scale unless the farthest sky vertex would pass `SKY_REACH` (3500 m), and then takes the largest scale that fits -- but never one that brings the nearest sky vertex inside the map's own bounds. pandora draws at 69, supernova at 47 (its asteroid field spans 586 to 6966 u off the camera, so no scale both fits it and keeps its inner rocks out of the map; the outer edge is clipped), and every 16 in the 26 is unchanged. The manifest's `skybox` records `drawn_scale` and `reach_units` (nearest, farthest from the world origin). `headless_imported` asks two more things per map: *a 3D skybox it draws has faces or props in it*, and *its 3D skybox is drawn in front of the camera's far plane* (nearest reach under 4000 m, drawn scale never above the mapper's); armed on the two maps with props zeroed and reach pushed out (`headless_imported.tscn -- bhop_pandora2_fix bhop_supernova` checks just those). The 11 skybox maps were re-imported in g2gfast-maps. Still open: sky props are lit by the floor under their small copy, so they read as dark silhouettes. Frames: `~/stack/nightly/archive/screenshots/2026-10-02/g2gfast/sky_up_sheet_BEFORE_AFTER.png` (rows: pandora before/after, supernova before/after, looking up from the spawn with `PREVIEW_PITCH=0.45`), `sky_up_sheet_AFTER2.png`.

**4. A start line that did not reach the floor.** surf_arcade's stage boxes are built around `sN_reset`, which stand about 240 units over their pads, and at +/-128 a player dropped at the spawn came to rest 112 units under the start zone. The timer asks the zone about the player's own position, so the player on the pad was never "in the start". `headless_imported` now lets the bot settle at the main spawn and asserts it is inside the main track's START (armed by the old box). A Python version of the same question that ignored displacements flagged bhop_badges; the physics said it was fine, because its start platform is a displacement. **Ask the physics, not a bounding box.**

**What looked wrong and is the map.** Black is black when the texture is (`cs_italy/black` 46% and `comp/whiteblink` 45% of surf_arcade, `real_dev/dev_black`, kitsune's grids); a dark floor is dark when its luxels are (checked with `lm` mode on surf_interference's start room, near zero); bhop_arcane_v2's "missing floor" is the route far below an open courtyard (the neutral render shows it); a spawn several metres over its floor is where the mapper put the `info_player`s (surf_beginner2, bhop_badges) and the player lands inside the start zone.

**Still open, in order of what it would buy:**

- ~~**The sky is white where a map's ambient is the default `255 255 255`**~~ **Fixed 2026-10-01**, in the game rather than the importer so the packs already on the CDN get it without a republish: `G2GLighting.white_sky_replacement` sees an ambient of exactly white (the map editor's untouched default, so not a statement about the sky) and recolours only the procedural sky's top (and its mirrored bottom) from `SKY_TOPS`, a table by sky name -- stock Source skies by eye, custom ones from another imported map's own `_ambient` for the same name (`space_13` from bhop_supernova, `mpa52` from bhop_lego2, deepened) -- falling back to `CLEAR_SKY`. The environment's ambient light is left as the map says. surf_beginner2 (`sky47`), bhop_aztec (`sky_day01_01`), bhop_mario_fxd (`mpa52`), bhop_evolve (`space_13`). `headless_imported`: *its sky is not a blank white dome* (armed: fails on surf_beginner2 with the call removed). Frames: `~/stack/nightly/archive/screenshots/2026-10-01/sky_sheet_{BEFORE,AFTER}.png` and `sky_<map>_<n>_{BEFORE,AFTER}.png`. bhop_eazy's sky (`militia_hdr`, ambient 242/227/191) is cream rather than white and is left as the mapper set it.
- **Textures have no mipmaps** (`mipmaps/generate=false` in every `.import` Godot wrote: it only turns them on itself when it sees a texture in a 3D material, and these are bound to shader parameters from a script). **Importer fixed 2026-10-01**: `ask_for_mipmaps` in `tools/bsp_import.py` writes each texture's `.png.import` with `mipmaps/generate=true` (keeping its other params and uid, dropping `[remap]` dest and `[deps]` so the next `--import` rebuilds). **The 26 maps in g2gfast-maps were flipped the same day** (all 967 surface textures' `.png.import`, lightmaps left without, since they are sampled at their own resolution); `headless_imported` still passes 1095 of 1095 against them, and a loaded texture reports `has_mipmaps()`. **The packs on the content origin predate it and need republishing** (`[g2g-maps-mipmaps]`, Christian's). Checked in a scratch copy of the project with bhop_eazy flipped: Godot keeps `generate=true` across `--import` and distant brick loses its moire (edge energy in the far-wall crop 12.5 -> 10.4). Frames: `mip_bhop_eazy_<n>_{BEFORE,AFTER}.png`, `mip_bhop_eazy_distance_crops_BEFORE-AFTER.png` in the same directory.
- ~~**Static props use the stock texture fallback of a flat 0.5 grey**~~ **and props with no lit floor under them are lit by nothing (2026-10-04).** Two halves, in `prop_colours` (bsp_import.py) and `GroundLight.open_sky` (bsp_props.py), begun by the nightly of 2026-10-03 (killed by the 600 s agent ceiling with the importer uncommitted) and finished in a live session. *Colour:* an untextured prop material takes the measured colour of the brush texture with the same last path part (`propper/surf_summit/cobble02` is summit's `cs_italy/cobble02`; arcade's `models/comp/<model>/black` is `cs_italy/black`), else the mean of the brush textures named with the same material word (`rockcliff02c`: the map's rock); 114 surfaces on arcade, 6 on tesquo. *Light:* `GroundLight.at` finds no lit floor under a 3D-skybox prop, a prop over water or open air, or one standing on **displacement terrain** (it does not see displacements: 593 of aquaflow's 744 props are its reef corals and ramps). Those were lit by the leaf cube alone -- nearly black (greensway's trees and candy canes were black silhouettes) -- or, with no probe at all, pointed at the atlas's full-white patch and drew unlit at full brightness (aquaflow's dome frames and half its `u_ramps`, arcade's cabinets). A prop WITH a probe takes `open_sky()` now: the 75th-percentile floor luxel's brightness in the average colour of the bright half (greensway: 583 props). **A prop with NO probe still draws unlit**, on purpose: lighting those too was rendered and turned arcade's purple and green cabinets near-black against a white map and aquaflow's white dome grey, and unlit is closer to what both maps are. **The first version took that one luxel's colour too, and on surf_arcade it is a cyan neon floor**: every fallback prop got zero red and the purple cabinets drew navy. Found by rendering arcade before and after and then reading the atlas pixel under the cabinet's UV2 -- (0, 62, 62). The manifest's `static_props.tinted` and `open_sky_lit` count both. **Still open:** displacement floors under a prop (the real fix for aquaflow's reef: sample the displacement's lightmap the way `build_lightmap` already parameterises it); and a prop whose lit floor is far below in shadow takes that shadow (aquaflow's `u_ramps/20_ramp_final` comes out at 0.05, nearly black -- a ramp the route needs). Frames: `~/stack/nightly/archive/screenshots/2026-10-04/g2gfast/props_BEFORE_AFTER.png` (final), and `props_<map>_first-version.png` (lighting the no-probe props too, rejected).
- **Doors do not move** and brush-entity `angles` are not applied (none of the 26 has any).
- **Displacement collision catches a sliding hull** (surf_mesa, measured above); not attempted.
- **A bot runs one imported map start to finish (2026-10-03), bhop_grove; the rest have no route yet.** See *A route written down as data* below for the mechanism and, per map, why the planner finds no route on the others.
- The published `surf_*` packs on the content origin predate all of this and need republishing (Christian's).

## A route written down as data, and the first imported map a bot runs end to end

`[g2g-maps-1]` asked for a bot that completes an imported map start to finish on the imported collision. Heading for the finish (`stage_ride`, 2026-10-01) finished none of eight. The line a map is run along is not in the BSP, so it is written per map in `maps/routes/<id>.json`: a list of points in the manifest's units and axes (Godot axes in genre units, what every tool prints), passed in order before the finish. `tools/route_bot.gd` drives it and is shared by `tools/stage_ride.tscn -- <id> 0 <seconds>` (the whole run follows the route when there is one, else the stage lines) and `headless_imported`.

**The bot strafes, and in the air it aims its landing.** The hand-built routes' bots hold forward and never gain (*the needle*). An imported bhop map asks for speed and for 64-unit blocks at 400 u/s, so in the air the bot works out the horizontal velocity that brings it down onto the next point's height over the next point (time to fall back to that height, from its vertical speed and gravity) and spends its wish turning its velocity into that one. Under `sv_airaccelerate 1000` a wish can change the velocity by nearly anything in one tick, so it can **brake** in the air as well as gain; the move's magnitude picks whether the air cap or the step binds (`_air`). Too slow for the landing it wants, it strafes at right angles to its velocity toward the target's side, which gains and turns at once. On the ground it runs at the point and jumps at a lip or a step too tall to walk (`ledge_ahead`, `wall_ahead`), so a chained hop never starts mid-block. **A point counts only once the bot has landed on or past it** (`land`, default true): aiming at the next block from the air above this one commits it to a jump it never took off for, which is how the first drafts fell between blocks. A door point (`door`) is passed by the teleport.

**`tools/route_plan.py <id> --reach 280 --out maps/routes/<id>.json` writes the route from the collision.** Every solid brush top that is not mostly under another solid within 72 u, plus terrain binned into 64-unit cells, is a node; two are joined when the gap between their tops is within `--reach`, the rise is at most 54, the centre-to-centre line is clear at body height, and a drop's landing column is open from the take-off down. TELEPORT doors join the tops they stand on to the top under their destination. Dijkstra from the top under the spawn to a top under the END. Blocks on these maps are L and U shapes made of several brushes, so a point is the centre of a brush top, never of a block's outline (grove's outlines have holes in the middle; aiming there was a fall).

**bhop_grove runs end to end:** 157 points, finished in 133.82 s with no put-back, top 419 u/s, deterministic. `headless_imported`'s new **route** section (10 sections and 39 checks per map now) drives it from the main spawn and asserts the game's own timer finishes a run with no pit on the way; a map without a route file passes and says so. Armed: points 31 to 45 removed, the bot is put back aiming at point 31 of 142. Without a route (the stage-line fallback) grove puts the bot back at 6.6 s. **The section runs in real time** like the rest of the suite (297 s for all 26 maps, 134 of them grove); `--fixed-fps 128` runs it as fast as the CPU allows with the same one tick per frame, and `stage_ride` is always worth running that way.

**Why the other maps have no route, measured with the planner (reach 280):** bhop_aztec plans at reach 340 but its 289-unit gap from a 258 u/s take-off is not something a bot that lands and runs can clear (it falls at point 5 of 95; hopping on every landing instead falls off the start pad). bhop_evolve's start pad is left by a teleport the importer made a pit (its zones file: "the sunken start pad ... teleports onto the block"), so 32 tops are reachable. bhop_badges_mini, bhop_tesquo_v2 and bhop_pandora2_fix join sections with teleports that are not all TELEPORT zones and stop at 42, 0 and 104 tops; bhop_badges and bhop_tesquo_v2 find no top under the spawn. bhop_fur stops at a raised box in its first room (115 tops), bhop_mario_fxd after 1,510 tops, bhop_supernova at its stage-2 room (rotated brushes make box tops), bhop_interloper, bhop_monster_jam and bhop_pit inside their first rooms. None of the surf maps was tried: the surf half of the bot is `stage_ride`'s ramp rule pointed at the next point and has not been driven down a map. What would buy the most next: the planner's top model (rotated brushes, terrain cells, the importer's pit/teleport split on staged maps), and a hand-written `via` point where it picks a wall.

## A recorded run, followed with the real movement (2026-10-07, `[g2gfast-route-bot-1]`)

A ghost (`G2GPlayer.replay`) writes each frame's pose into the state: it passes through walls, finishes every map whatever the collision is, and proves nothing about the map. `tools/replay_follow.gd` does the opposite. It drives the motor with ordinary `DotFpsCommand`s along a dot-timer replay (`maps/routes/<id>.replay`). A run it cannot repeat is a place where the map is no longer the map the run was made on, and it reports that place: *"left the recorded line at frame N, (x, y, z) u"*, which is where to look for the collision fault. `headless_imported`'s **recording** section (11 sections and 45 checks per map now) follows the map's recording and asserts the game's own timer finishes it. It then follows a copy lifted 200 u off the map from frame 2000 and asserts the report names that frame, not a pit or the clock. A map with no recording passes both and says so. `tools/follow_replay.tscn -- <id> [seconds] [file]` is the same drive as a tool (`FOLLOW_LOG_EVERY=8` traces it). `RIDE_SAVE_REPLAY=maps/routes/<id>.replay tools/stage_ride.tscn -- <id> 0 200` saves a route bot's finished run as one.

**bhop_grove is followed end to end.** The route bot recorded the run (133.82 s). The follower finishes it in 140.00 s, never more than 46 u off the line, deterministic, and the lifted copy is reported at frame 1999. **Its recording is a bot's, not a person's.** A person's record replay (`G2GReplays` writes it beside the records) copied to `maps/routes/<id>.replay` is the line the item asked for. One ride from `!s3` on surf_summit would also settle `[arrive-3]`. None exists yet: this needs a ride from Christian.

What it took, each found by tracing a fall. All of it is the genre's air physics, and the first three are why a "pull back onto the line" controller cannot work:

- **A wish near the velocity adds nothing.** Air acceleration only adds speed along the wish up to 30 u/s past what the velocity already has along it. The first version steered at "line velocity + a pull back", whose wish was mostly along the velocity, so it never turned, and it fell at 7%. A turn is a wish at right angles to the velocity, toward the side wanted.
- **The same holds on the ground above run speed.** A landing from a hop is at 270-360 u/s against a run of 250, so a wish within about twenty degrees of the velocity adds nothing there either. The bot drifted 13 u wide over 50 ticks while "steering" and jumped off the block's side.
- **Short of speed, a full strafe toward the turn.** Small corrective turns gain almost nothing, so the follower ran 10-15 u/s slower than the recording in every flight and missed the block whose lip the recording made by 2 u. Strafing at full wish on the side the line bends toward gains and turns at once, which is what a player's strafe is. That change took it from 39% to the finish.
- **A jump is copied by place and held until airborne.** The take-off is the recorded frame where jump goes down, and the bot presses once it has reached that frame or passed it along the line. A one-tick press matched to the wrong tick is never seen. If the bot is grounded while the recording is in the air more than a step above it, it jumps again.
- **Within 24 frames of a recorded landing, the air aims at the landing itself**, timed by the fall the way `route_bot._air` is, so a bot a tick behind in phase still comes down on the lip.

## The imported maps live in g2gfast-maps

`maps/imported/` is a gitignored link to `../g2gfast-maps/maps/` (`tools/g2gmaps link` there makes it). That repository holds the 26 imported maps, `maps.json` with each map's author and source, and `tools/g2gmaps` to publish each as its own `gamemann/<map id>` pack (through this repository's `tools/publish_maps.sh`) and to mirror them back from the CDN. The zone data stays here in `maps/zones/`, because starts, finishes and stages are this game's, not the map's. A published server fetches a map on a map change from `sv_map_content_owner` (`gamemann`, in `game.yml`); they went to the CDN on 2026-09-30. **Since 2026-10-05 the map set is `game.yml`'s top-level `maps:` list** (`gamemann/<id>` per course, 26 of them), carried by dot-server as `DotGameDescriptor.maps` with each version pinned by the server's installer; `G2GGame._adopt_descriptor_maps` reads it when the scene is built and `ensure_map_content` asks for the pinned pack and version. `sv_content_maps` is the fallback on a server whose dot-server predates the field, and `sv_map_content_owner` still serves a map id typed at the console that is not in the list. Maps are released by tagging g2gfast-maps (see its CLAUDE.md).

## The map vote is drawn on the client shell (2026-10-04)

The vote wrapper owns a `DotVoteBallotFeed` and polls it every `advance`; the module points its `ballot_fn` at `server.send_notice`, one copy per playing session with that session's voter id as `you`, under the topic `map_ballot`. dot-server-deploy's shell draws it as a dot-ui `DotBallotPanel` beside the server's own `game_ballot` — number keys, F3 and a click, or both, and every voter's avatar on their choice — and a click goes back as the same `!vote`-style command a player could type. Standalone, with no shell, nothing draws it and chat still carries the ballot. Defaults moved with dot-vote's: `map_seconds` is 2700 and the ballot opens 150 s before the end. A timer server has no rounds, so `time_up` has nothing to wait for here and changes on time either way.

## A displacement blend draws both its textures (2026-10-04, `[ref-1]`)

`WorldVertexTransition` materials paint a second texture (`$basetexture2`) by per-vertex alpha, which `dispvert.alpha` (0..255) carries, and the importer took only the first: grey rock where surf_mesa's CS:S footage has warm orange, on 67% of its triangles. Nine maps have such terrain with both textures shipped (surf_mesa, surf_summit, surf_greensway, surf_aquaflow, surf_interference, bhop_evolve, bhop_arcane_v2, bhop_interloper, bhop_pandora2_fix). `bsp_import.vmt_blend` reads the second texture only for that shader (bhop_supernova's `LightmappedGeneric` names one and never blends); `displacement_tris(with_alpha=True)` returns the alpha; a surface with any alpha above 0 gets `texture2` and an **`alpha_offset`: one float per vertex in its own block after the indices**, so the ten-float vertex every loader reads is unchanged and a pack imported now still loads, single-textured, in a game built before. `G2GBspMap` puts it in `ARRAY_COLOR` and `g2g_bsp_lightmapped.gdshader` mixes by `COLOR.a`. A blend material whose first texture is stock (bhop_tesquo_v2's `george/blend_rock`) stays on the prototype grid. `headless_imported`'s "a material that blends two textures draws both" (armed: a loader that drops the second texture fails it on nine maps; `BLENDED` names five that must have one). Frames: `~/stack/nightly/archive/screenshots/2026-10-04/g2gfast/blend_<map>_BEFORE_AFTER.png`.

## A stage with nowhere to stand is a split (2026-10-04, `[arrive-2]`)

surf_greensway's stage 2 line (`checkpoint_1`) is a gate across open canyon whose only floor is the mapper's own fail teleport, so `!s2` had nowhere to send anybody. A zone file can now mark a map-labelled stage `"restart": false` with a `"restart_why"` (the importer refuses one without a reason); the manifest zone carries both and `G2GBspMap` puts the reason in the stage zone's payload under `G2GBspMap.NO_RESTART`. `G2GGame.request_stage` refuses it (`CODE_UNSUPPORTED`, the reason in the message) **before** the timer stops the run, and `restart_stage` (`!rs`) from inside it goes back to the nearest earlier stage that has a start. The stage still splits a timed run. `headless_imported` asserts the refusal and the `!rs` fallback in place of standability, and skips it in the pit check; `ARRIVES_IN_PIT` is empty.

## A map pack's version is its files' (2026-10-04, `[g2g-maps-version-1]`)

Every map pack was `@0.0.0`. dot-cloud keys a mount on `id@version` and cannot undo one, so a client that had mounted the old `bhop_aztec` was told "bhop_aztec, 0.0.0" by a restarted server holding the new one and played the old geometry. `tools/publish_maps.gd` now publishes each map as `G2GMapCatalogue.pack_version(dir)`: `0.0.0-` and 12 hex digits of a SHA-256 over every file in the map's directory (path and bytes, path order; `.godot`/`.git`/`__pycache__` left out, `.import` markers in). Derived rather than kept in `maps.json` because it changes exactly when the files do, needs nobody to remember a bump, and republishing unchanged files gives the same version (checked: two publishes of bhop_eazy, the second wrote 0 objects). `--version` still forces one. The version-less layout stays: a server's `ensure(id)` reads the flat `<owner>/<id>/manifest.json` and mounts whatever version it names at `res://dot_cloud/<content>/<version>/`, and a client asks for the announced version through the shell's flat fallback, which refuses a manifest of another version.

**The client half was a dot-map bug.** `DotMapSyncClient._accept` compared the announced map's own `version` with the remembered one and never `content_version`, so a client holding the map answered a republish with the map it had. Fixed in dot-map (`content_version` compared for delivered maps; `map_selftest` armed). `headless_net`'s "a map republished with different files" publishes, mounts and follows v1, republishes changed files as v2, has the server forget the map as a restart would, and asserts the server mounts v2 and the client that held v1 plays v2 -- it failed on the client step before the dot-map fix. The server log line "a map was added from delivered content" carries the version.

## Kenney stand-ins for stock textures (2026-10-04, `[g2g-maps-stock-1]`, first batch)

Christian's rule: an imported surface draws the map's own texture if the .bsp packed one, else a **Kenney** texture (CC0, `textures/stock/`, licence beside them), else the tinted prototype grid -- **never the source game's textures**. `textures/stock/substitutes.json` maps material names (globs, first match wins) to a stand-in, `units` (tile width in Source units, 128), `aspect` (Kenney's walls are 64x128; drawn square their brick courses read as planks) and `mean` (the stand-in's average colour). `none` entries keep dev/tool textures, flat black/white, metal, concrete, lights and the arcade cabinets on the grid. `G2GStockSubstitutes` reads it; **`G2GBspMap._material_for` applies it when a map is built, not the importer**, so packs already on the CDN get it from the game pack with no republish (prototype surfaces carry world UVs and the measured colour already). The tint pulls the stand-in 60% toward the mapper's measured colour (`TINT_PULL`); pixel art is sampled nearest (`pixel_tex` in `g2g_bsp_lightmapped.gdshader`). Chosen by looking at private reference copies on `/extra/g2g-ref/` beside the Kenney sheet; **nothing from `/extra` may enter a repository or a pack**, and `tools/publish_maps.gd` refuses a map containing a file whose hash matches one there or a link into `/extra` (armed: a copied reference PNG was refused). Textured share (own + stand-in) measured by `headless_imported` per map, with floors in `STOCK_DRAWN` for the maps looked at: bhop_aztec 0% -> 62%, surf_beginner2 2.6% -> 75.5% (also buses_from_hell_fixed 0 -> 64%, bhop_interloper 50 -> 89%, bhop_monster_jam 2 -> 37%, not yet looked at along their routes). Frames: `~/stack/nightly/archive/screenshots/2026-10-04/g2gfast/stock_*`.

**Third batch (2026-10-10, nightly 61).** `/extra/g2g-ref/extract_refs.py` re-run over all 74 imported maps (521 of 1384 materials now have a private reference, 45% of the untextured triangles). 31 entries from that sheet: 17 by material (aztec `stonework05`, italy/dust/piranesi rubble walls -> `wall_stone`; cut-stone blocks -> sand or stone brick; nuke corrugated, `pi_rust`, `cs_italy/steel` -> brushed metal; `road01_cheap` -> dirt; tides flagstones -> stone pattern), 3 more `none` (`glass/*`, flat `cs_italy/yellow`, `de_dust/stonetrim05`) and 11 name rules (`*marble*` -> tan tiles; `*plaster*`, `*pavement*`, `*marketwall*`, `*sitebwall*`, havana/chateau `wll*`, `*/trimwall*`, `de_nuke/nukfloor*` -> concrete; `*stonewall*`; `*rust*`). Floors raised on seven maps (grave 74 -> 85%, 10x_final 58 -> 74%, mai_remix 60 -> 70%, exodus 75 -> 81%). Frames: `~/stack/nightly/archive/screenshots/2026-10-10/g2gfast/`. Still under 40%: surf_akai_final 0% and kz_bhop_yonkoma 11% (all `dev/`/flat colours, `none` on purpose), bhop_grove (`tony/forest_texture4`, mapper-custom, no reference), surf_matrix_v8, surf_greatriver_xdre4m.

## Hunters reach a connected client (2026-10-05)

Until now the hunters ran on the server and nothing sent them: a connected runner was swiped by something they could not see, and only an offline game showed one. `G2GNetBridge` watches the hunters' spawner on the server (`_watch_hunters`), gives each hunter a `G2GNpcNet` (dot-npc's `DotNpcNetSync` fields: position, yaw, health, state; interpolated, never predicted, because a hunter comes out of a brain and a course line no client could reproduce) and tells clients with `G2GEvents.Kind.NPC` / `NPC_GONE`, appended after CLOCK because a kind is its index on the wire. A joiner is told every hunter alive in `_admit`. **Every hunter is `always_relevant`**: a timer map is long and thin, and on the interest grid a hunter waiting forty metres ahead of the runner is out of range at exactly the moment it matters, so its mirror stood still where it was first seen. `headless_net`'s hunter section spawns one, asserts the client builds a mirror, draws it within a metre of the server's hunter and facing its yaw, and lets it go when the server's goes. On a client the mirror is a drawn body with no brain, no senses and no collision. The shell needs no rebuild for this (no new `class_name`); the g2gfast pack does.

## Every brush face was drawn inside out, a sloped pit was its box, and a ramp seam was a bump (2026-10-07, `[watch-extra-external-1]`)

Three faults in Christian's surf_mesa and surf_beginner2 footage (`/extra/external/video/26-10-07/`), all in `tools/bsp_import.py`, all invisible to every check that existed, and every one of the 42 maps re-imported with all three (g2gfast-maps).

- **Brush faces were wound backwards.** The ring was emitted `(0, k+1, k)` "because Source winds the other way" -- it does not: both engines draw a clockwise triangle and `to_godot` is a rotation, so nothing flips. Godot culled every brush face from the side its normal points to and drew it from behind (a one-triangle render confirmed which way Godot's front face is). Most surfaces hid it: a floor showed its slab's underside, a wall its far face. A surf ramp could not, because its underside is nodraw: from on top there was nothing behind the face, and the ramp a player rode was clear -- "the ramp side we surf on is clear-through" on surf_mesa, and surf_beginner2's spawn room drawn as open sky with walls floating in it. It was not glass: surf_mesa's first ramp has no glass in the .bsp (its only glass is the crystal room). Found by drawing one material flat magenta, double-sided and then single-sided (`PREVIEW_MARK=<material>`, `PREVIEW_MARK_CULL=1`, `PREVIEW_EYE=x,y,z`, `PREVIEW_YAW` in `tools/bsp_preview.gd`). Displacements and props have their own emit paths and were right. `headless_imported`'s *a floor is drawn from the side a player stands on* asks the winding of every PLATFORM surface (armed: the old surf_mesa import fails it with 14 surfaces, water included).
- **A sloped teleport brush became its bounding box.** surf_mesa's pit under the island descent is a sheet 24 units thick that climbs 4,240 along the course; its box reached over 158 ramp triangles and sent a rider back to the start mid-ramp (0:40 on the timer in the footage). `trim_to_hull` only ever cut a box back off an arrival. `hull_boxes` now cuts any trigger brush that is not its own box into slabs along whichever horizontal axis over-reaches less: each slab gets the vertical extent inside the brush at all four corner columns, solved from the brush's planes (a convex brush holds a box exactly when it holds its corners); a slab no box fits inside (a thin sheet) bounds the brush instead, and the slabs are narrow enough (`HULL_SLAB_RISE`) that it over-reaches by tens of units, never wider than `HULL_SLAB_MIN` so a 3500 u/s player cannot cross one between ticks. A slab is grown only DOWN, and sideways only across the cut, where it spans the whole brush. Ride points inside a pit the map does not have on surf_mesa: 343 -> 94 (what is left is ramp feet touching the mapper's own sheet). Zone counts grow (surf_stonework3 519 -> 2265); `DotTimerZoneIndex` is a grid, so a tick does not notice.
- **Every brush seam was a bump.** Each brush is its own convex shape, and a hull sliding from one onto the next meets the second's leading edge: on surf_mesa's first ramp, built as 500-unit segments, the real motor was kicked off the face at 36 u/s at the seam (y≈1412) and rose 1.5 units -- "the ramps are a bit bumpy". `merge_convex_brushes` merges world brushes that share a plane (opposed) when each one's corners are behind every other side of the other -- the classic compilers' merge test, exact, so the solid does not move and only the seam goes. surf_mesa 2411 brushes -> 1594 solids; after it the same ride holds within ±2.5 u/s of the face along its whole length. Bevel sides are left out of the test and contents must match.
- **surf_mesa has no water at its start.** Its only water is the secret island at the bottom of the map; there was nothing to remove. surf_beginner2's stage doors (each stage ends in a door-sized teleport that imported as a pit) are a `doorways` rule in its zones file, from the surf-beginner2 session.

`headless_imported` 1948 / 0 over 42 maps on the final imports; `headless_net`, `dedicated`, `headless_run` pass.

## The ramps were still jumpy, and it was one engine answer (2026-10-08, `[g2gfast-surf-mesa-1]`)

Christian's surf_mesa footage from a local Windows build (`/extra/external/video/26-10-08/`) has no dropped or repeated frames, so it was not the render-jitter class: it is single frames where the view jumps off the ramp and snaps back, about eight frames apart on a curved ramp. `tools/ramp_bump_probe.tscn -- <map> [rides] [entry u/s] [strafe 0|1]` rides ramp triangles with the real motor and counts ticks whose position step leaves its smooth line by more than a unit, by what corrected the hull that tick (`TRACE_RIDE=n` prints one ride). On surf_mesa 9.5% of ramp ticks did, a third of them by 17 to 20 units, which is `step_height`, the clamp on `DotFpsMotor._depenetrate`. Traced: a rider resting on the face read clear, then 57 units deep along the face's exact reverse with nothing moved between, was pushed a step into the ramp and back out the next tick. Godot's `get_rest_info` reverses a resting normal; it happens on a plain box too. Fixed in dot-player-controller (its CLAUDE.md, `[ramp-pop-1]`): bumps 9.5% -> 2.6% strafing and 8.4% -> 4.7% not, steps over 17 units 3,200 -> 10. The rest are 1 to 6 units with no correction behind them, most likely the ramp's own facets turning the velocity; not investigated. **bhop_grove's recording was re-recorded on the fixed motor** (133.81 s, against 133.82): the route bot had been shoved into a side wall four times by reversed wall normals, and with those gone `headless_imported`'s follower left the old line at 39%; the standalone `follow_replay` finished it either way, so the follow is marginal and the recording is the motor's. Re-recording found that `RIDE_SAVE_REPLAY` had saved nothing since dot-timer's records change, which drops `last_replay` the moment no store will keep the run; `stage_ride` takes it on `player_finished` now. Same motor on the server and in a client's prediction, so a server is affected the same way and fixed the same way; the shell carries dot-player-controller, so a browser or desktop client needs a shell rebuild to get it.

## What a full server costs (2026-10-07)

`tools/load_probe.tscn -- <map> <counts...>` is the real server half -- `G2GGame`, `DotNetManager`, `G2GNetBridge`, the socket replaced by a counter -- with N admitted players running and turning, timing every tick against the server's own budget (7.8 ms at 128). Nothing before it had put more than two players on a server. `LOAD_PHASES=1` breaks a snapshot into its steps. On surf_mesa, this machine, headless:

| players | tick mean | p99 | of which game | of which snapshots | snapshot bytes/s to one peer |
| --- | --- | --- | --- | --- | --- |
| 8 | 2.6 ms | 5.9 | 1.9 | 0.7 | 5,165 |
| 16 | 6.7 ms | 17.8 | 3.8 | 3.0 | 10,073 |
| 32 | 19.7 ms | 59.8 | 7.6 | 12.1 | 19,888 |
| 64 | 64.1 ms | 222 | 15.4 | 48.6 | 39,516 |

Before dot-net's per-snapshot caches the 32 row was 25.0 ms (snapshots 17.7). **`max_players: 32` at 128 ticks is not holdable**: the game alone is 0.24 ms per player per tick, so 32 runners fill the whole budget before a byte is sent, and snapshots grow with the square of the player count (every peer is sent every player, and the per-peer bookkeeping -- dirty sets, believed and pending values, bit packing -- is GDScript per property per peer). What would move it, in order: encode each entity's state once per snapshot and share the bytes between peers whose dirty set is the same (every non-owner, for a moving player); `sv_tickrate 64` on a big server (snapshots stay 32 Hz, the game's share halves); and the motor's per-player cost in dot-player-controller.

## Records, standings and the site (2026-10-08)

**A database is optional and reached by path.** `G2GConfig.records_database` (`sqlite`, `postgres`, `mysql`) makes `_build_timers` hand the timer manager a `DotTimerStoreSql` before it is in the tree (so the manager's configuration keeps it instead of building the file store), and `_ready` opens it before the first map. dot-sql is loaded as `res://addons/dot_sql/core/dot_sql.gd` and never named: this game ships as a pack and parses against whatever addons the host build carries. A database that will not open is an ERROR and a session on files, not a server that will not start. `records_database_token` is refused from the environment and argv (`sensitive_keys`).

**Three things that were wrong, none of which errored:**
- **Nothing reached the site.** Both leaderboard boards were defined with `publish` off, and the reporter skips an unpublished board, so `report_to_backbone` sent nothing. `publish` now follows `report_to_backbone`.
- **Points grew with every retry.** `_on_record_accepted` added each accepted record's whole points to a running `points` stat, so improving a map five times counted it five times. Points now come from the timer store's own total (re-scored when a record moves, weighted down the player's list) and are submitted to the `points` board in `_on_timer_filed`. The stat set keeps `completions` only.
- **The HUD never had a record or a best to compare against.** `DotTimerHud.set_comparisons` was called nowhere, so the split beside the clock never showed. `G2GGame.standing_changed` (`{pb, wr, rank, total}`, on every spawn, style change and filing) drives the HUD's new standing line; on a client it arrives as the `STANDING` event (appended to `G2GEvents.Kind`), because a client has no store.

**What a finish says** is `G2GGame.announced`: a new record to everybody (the `RECORD` event), a personal best or a miss to the finisher, and a refused run with the place it would have taken (`practice_finished`). The HUD's old "time — rank" notice is now only for a game without a store.

**The commands are phrasing only.** `!pb`, `!rank`, `!players`, `!rr`, `!profile`, `!mapsdone`, `!mapsleft`, `!wrcp`, `!prinfo`, `!tier`, `!end`, `!pause`, `!unpause`, `!autorestart`, `!restore`, and the admin `g2g_settier`, `g2g_rescore`, `g2g_deleterecord`, `g2g_wipeplayer` call dot-timer's manager and store; two games' `!rank` cannot disagree about what a rank is.

## What a map's brush entities do, a map list and a zone editor (2026-10-08, `[g2gfast-more-reviews-1]`)

From Christian's bhop_eazy and bhop_evolve footage (`/extra/external/video/26-10-08/`). What the footage showed, and the cause of each:

- **Every pit restarted the run.** The importer turned each leftover `trigger_teleport` into a RESPAWN zone and threw its destination away, and `G2GGame._on_effect_requested` answered every RESPAWN with `spawn_player` -- the track's spawn, run stopped. On a staged map that is "fell in section five, back to section one". A pit now carries the destination its trigger aims at (`G2GBspMap.SENDS_TO` in the payload) and the game teleports the player there with the run kept, as Source does. A pit whose target is not an `info_teleport_destination` still resolves: `Zoner.destinations` takes any point entity with that name (surf_greatriver_xdre4m aims at `info_target`s, surf_grave_reloaded at `info_landmark`s). **A destination inside another pit is followed, not dropped**: it is usually a speed-stopping hub (bhop_arcane_v2's `stage1_stop`, 239 of its 334 pits; surf_fruits 216), so the pit sends to where the chain ends, and only a real cycle falls back to the spawn. Teleports without the Clients flag are dropped (Source never fires them for a player).
- **bhop_eazy had no zones at all**, so the timer never started and every gate between sections was a pit back to the spawn. It has a zones file now: the spawn room is the start, the three gates' arrivals are stages, and `t2727` (a hub of menu teleports nothing in a section leads back to) is the finish. It left `headless_imported`'s `NOT_COURSES`.
- **Evolve's "water that is not water"** is a `func_illusionary` painted `watersource/river/river_clear` over section one. Water now comes from world WATER/SLIME brushes, `func_water_analog`/`func_water` (which were imported SOLID), and any brush entity in a water material. g2gfast registers dot-player-controller's `DotFpsSwimMode` on every player (200 u/s, and a new `idle_sink_speed` so a player who lets go sinks at 60 u/s the way the genre's water does; holding jump rises). **On evolve that particular river is also exactly the size of a teleport to `Zyp1_1`, so in Source you are teleported the moment you touch it, and here now too** -- to `Zyp1_1`, not to the start.
- **The "trigger_push that is an invisible wall" is not a push**: bhop_evolve has no `trigger_push` at all, and its only brush entities are non-solid, so its collision is exactly its world brushes, which Source collides with too. Whatever cut the speed is a player clip or a surface we do not draw. Not found; it needs a position from Christian (`getpos`-style) to look at.
- **Pushes, gravity, conveyors, lethal hurt and sinking blocks are run** (`tools/bsp_mechanics.py` -> manifest `mechanics` -> `G2GMapMechanics`, ticked from `G2GPlayer._on_simulated`). A push is the engine's base velocity: displaced through the motor's own sweep while inside, added to the velocity on leaving; its "last tick" is kept per TICK so a client's replay reads what the server did. A **block** (a touch-opened `func_door`/`func_button` moving down over a teleport plate) is timed per player: stand on it longer than the door would take to carry your feet into the plate and you are sent where the plate sends people (eazy: 8 units at 25 u/s, 0.32 s). Nobody can sink a block for somebody else because nothing is shared. A push or block behind a filter nobody can pass is left out (`inert_filters`: a class filter naming no class anybody is given, a name filter whose name no output assigns -- bhop_badges_mini's `upboost_filter` launched a player up a shaft for ever); teleports keep the old class-only rule, because bhop_tesquo_v2's renamed classes are checkpoint logic we do not run.
- **Ladders** (CONTENTS_LADDER brushes in 22 maps) are climbed: `G2GLadderMode`, the engine's own decomposition (the wish into the face becomes up the face). In the game, not the addon, so a delivered pack names no new class.
- `func_clip_vphysics`, "passable" doors, `Solidity 1` brushes and the like are no longer solid (`solid_for_players`).

**Maps that rotate are a file, and a map out of rotation is still installed.** `cfg/map_rotation(.yml|.yaml|.json|.txt|.cfg|.ini)` (`sv_map_rotation_file`, `G2GMapRotationFile`); unlisted maps get `enabled = false`, which the rotation's pool, dot-vote's ballot and nominations already read, and `meta.in_rotation` for the list. **Combat surf maps** (ten, `"kind": "arena"` in their zones files) are out of rotation unless named; game-arena loading them is `[arena-combat-surf-1]` on the nightly queue.

**M is the map list**, every map with "not in rotation" and "combat" marked, 1-7 or the mouse, 8/9 page, 0 closes (`G2GMapMenu`). Online it is the server's catalogue, sent (`Ask.MAPS` / `Kind.MAPS`, both appended) only to a session with the changemap flag (`G2GNetBridge.may_change_map_fn`), which is checked again on the change.

**Zones are drawn**, glowing (`G2GZoneOutlines`: one MultiMesh of edge boxes for the core and one additive halo, so it does not depend on the environment's bloom; setting `show_zones`). **Z is the zone editor** (`G2GZoneEditor`): aim-placed corners snapped to 16 units, live preview, height on PgUp/PgDn. Offline it edits the game's set and saves to `user://zones/<map>.json`; online it sends `/g2g_zone`, `/g2g_zone_mark x y z height` (new: explicit corners, no padding) and `/g2g_zone_save` in chat. **`user://zones/<map>.json` was written by `g2g_zone_save` and read by nothing**; `_on_map_changed` reads it now, in preference to the map's own zones. Online, zones a server admin draws do not reach other clients' outlines until they load the map with the file.

**Offline there is no map time limit** (`G2GConfig.offline_map_seconds`, 0).

`examples/headless_mechanics.tscn` puts a player on every imported map's pit destinations (lands, or rides a ramp, without falling freely or looping), through a pit with a run going (kept), on its blocks (stays: taken off; hops: not), in its pushes (pushed along) and in its water (swims, rises on jump). Each samples at most twelve per map.

## Chat, spectating, R, themes and the timer's layout (2026-10-08, `[g2gfast-some-more-1]`)

**Typing in chat no longer moves the runner, and a suite now holds a key to prove it.** Offline, the player's own `DotFpsSampler` is the one that moves them, and until 096cec7 only the networked one was suspended, so W in the chat box walked an offline player off whatever they stood on. `_refresh_suspended` covers both now and also runs in `_adopt`, so a player made while the box is open (offline, a new player is a new sampler) starts still. Nothing caught it because no suite stood up `G2GClient`: `examples/headless_client.tscn` is the real offline client on `bhop_g2g_intro`, holding W with the box open and measuring (armed by putting the old suspend back: the runner moves 0.76 m).

**Spectating never reached a client, for two reasons, and both are fixed.** `G2GGame._build_layers` returned before it built `spectate` on any game that was not authoritative, so a client had no spectator manager and `_drive_spectator_camera` returned on its first line every frame. And nothing told a client anything: `!spec` changed the server's manager, the server replied "Watching Bea." in chat, and the camera stayed put. Now the client builds a mirror (`DotSpectatorManager.authoritative` follows the game's), and the bridge watches the server's manager (`view_changed` and `retargeted`) and sends **SPECTATE** (the target's key, mode and name) to the viewer, which `_apply_spectate` writes into the mirror with `apply_wire`; the camera follows from the poses the client already draws. A viewer left with nobody to watch is stopped rather than parked on an empty fixed camera. `Ask.SPECTATE` carries a click (`SPECTATE_NEXT`/`_PREVIOUS`/`_STOP`/`_BEST`): left click is the previous player, right click the next, both only while spectating. While spectating, the sampler is suspended (the body stays where it was) and the HUD's clock, speed and keys are the watched player's (`G2GHud.followed_id`); the standing line stays the owner's, because a client is only told its own. `!spec <name>` matches the whole name, then a prefix, then anywhere in a name. **And then the camera still did not move, for a third reason.** `_drive_spectator_camera` ran before the camera-shake line in `_process`, which sets the active camera's local position every frame, so a spectator's camera turned to the watched player's view and sat at the spectator's own eyes. The net suite asked the spectator manager where the camera should be, which was right. `headless_client`'s *a spectator sees through the watched player's eyes* asks the drawn camera (armed: the old order leaves it 3 m behind). In first person the watched body is not drawn (`_watched_from_inside`), because the camera is inside its head.

**Who is watching you is `sv_spec_list` (on), gated on the server.** **SPECTATORS** (a key and up to 32 names) goes to the watched player and to everybody watching them whenever that list changes; `sv_spec_list 0` sends every list empty once and then nothing, so a modified client cannot draw what was never sent. `show_spectators` hides it on a player's own screen. `headless_net`'s *spectating reaches the client* asserts the server's pick, the client's mirror and camera, the list, the gate both ways, R ending it, and R's modes over the link; armed by the old early return (the section aborts) and by removing the gate (two checks fire).

**R once is the stage, R twice is the start.** `G2GGame.restart(id, mode)`, one place for the offline client and the server: `RESTART_STAGE` is `restart_stage` (the genre's `!rs`, which stops the run) when a run is past its first stage line on a staged track, and the track's start otherwise, so a bonus's R is the bonus start; `RESTART_MAIN` puts the player on the main track's start zone from anywhere. Both stop spectating. The client acts on the first press at once and widens it if a second lands within `DOUBLE_TAP_MSEC` (350), because waiting to see would put a third of a second of nothing in front of the most-pressed key; a double tap is spent, so a third press starts again. `Ask.RESTART` carries the mode as its body, and an empty body (every client before it) reads as `RESTART_TRACK`, which is what that R meant. `headless_run`'s last section covers the game half, on its own map load: **placed between the stage and bhop sections it made the stages map's surf bonus fail** (1874 of 3200 u), which is `[bank-hang-1]`'s order sensitivity again, not anything R does.

**Themes are a palette, switched while the menus are open.** `G2GUi`'s colours are `static var`s under the constants' old names, so no call site changed; `G2GUi.THEMES` holds six whole palettes (Midnight, the old one and the default; Ember, Violet, Classic, Paper, High contrast) with a HUD half (the clock's plate, text and split colours). `ui_theme` (ACCOUNT) picks one, P (`g2g_theme_next`) cycles, and `G2GClient.apply_theme` rebuilds every screen through its `restyle()` only when the palette actually changed. Rebuilt rather than recoloured, because every box is an override set once at build and a second walk to find them all again drifts from the first. The light theme found two hard-coded whites (theme lines, the switch track) that had to become palette-relative, and a dark select well that read as disabled on a light card; text on the accent is `ink_on`, black or white by luminance, because one theme's accent is dark teal and another's is bright yellow.

**The timer's layout is the player's.** Every line of the clock's block is one of `DotTimerHud`'s own fields (time, style and track, stage, statistics, standing, the comparison, compact, size), so a line switched off closes the block up rather than leaving a gap, and nothing in dot-timer changed, which matters because the shell carries it. `timer_position` is a corner placement; "Move HUD elements" (Esc → HUD & theme) opens `G2GHudEditor`, where the timer, the keys, the status line and the spectator list are dragged and right-clicked back, saved as `hud_positions`: each piece's CENTRE as a fraction of the window, so a layout made on a laptop lands in the same place on a large screen, and anything unknown or off-screen in the text is dropped or clamped back on. The keys follow the clock wherever it goes. Four presets (`G2GClient.LAYOUT_PRESETS`) write settings rather than being one, so changing one thing after a preset is the player's own layout. A clock with nothing on it (no run) still has a size to grab and to place, the same one for both, or a dragged empty clock would sit away from where it was dropped. `headless_presentation` has two sections for this (171 checks).

`tools/screenshot_menus.sh` renders the HUD page, the same page in Paper, and the editor after a drag (`menus_hud`, `menus_hud_paper`, `menus_hud_editor`). **It now keeps its settings in memory**: a client run writes `user://g2g_settings` on every change, so a tool that flips the theme would otherwise change the player's own game — which is exactly what the first render of this work did to the local settings file before it was put back.

**Review, the same day.** Four faults in the above, fixed: **ladders did not climb** -- `G2GLadderMode` called the motor's `categorise_ground` every tick, which writes AIR for anybody rising who was not grounded, so every climber was dropped each tick and bounced up at a quarter of the climb speed (`headless_mechanics`' *ladders* section now; armed: 58 units in half a second against 100); a **client** read its own `user://zones/<map>.json` over the server's zones (authoritative only now); a **teleport** kept the push memory, so a booster into a gate added its speed at the far end (`G2GPlayer.teleport` resets the rider); and the rotation file overrode a catalogue file's `"enabled": false` (`meta.catalogue_enabled` keeps it). And a ladder now wins over water, as in the engine these maps come from: surf_life_of_duck's climb-out pit is four ladder walls over water, and the swim mode took every climber back. Still open: the online zone editor sends three chat commands per zone and nothing has driven that path end to end; a "once" push re-fires on every entry (Source removes the trigger after its first use, for everybody, which is shared state this game avoids).

**The other maps, reviewed (2026-10-08).** Three things, from data rather than footage:

- **Standing still cost nothing on six bhop maps.** Their blocks are not doors: a `trigger_multiple` on each block renames whoever touches it after a delay (`!activator,AddOutput,targetname activator,0.09`) and a teleport on the block fires only for that name. `conditional_teleports` dropped those teleports because this game does not run the logic, and nothing replaced them. `bsp_mechanics.trap_blocks` turns each into a per-player block (`"touch": true`: the teleport's own volume, asked of a grounded hull) with the map's own delay: bhop_badges 481, bhop_tesquo_v2 543, bhop_mario_fxd 258, bhop_badges_mini 252, bhop_lego2 239, bhop_grove 112, all 0.09 s. A name given with no delay (surf_kitsune's `TealF` windows) is a gate, not a trap, and stays dropped; ananas, interloper and arcane assign their trap names nowhere (or through `filter_multi`), so in Source their traps never fire either. `headless_imported`'s route and recording sections turn blocks off: the route bot lands and runs to the lip, which is exactly what a trap punishes, and they test the collision line.
- **bhop_badges has stages now**: its `N.1` destinations are section starts, each reached through a gate from the section before (12 of 12), so a box round each is crossed on arrival.
- **Stages around a destination only work where a gate leads there.** Every surf map's do (a door far from the stage start, measured). bhop_evolve's 3, 4, 6 and 7 are walked into, and fur, badges_mini, aztec, mario_fxd and arcane_v2 have named sections that are walked into too; those want stage lines drawn on the route (`[evolve-stages-1]`).


## Eight more maps, a lost output and a round this game does not run (2026-10-09, `[gb-maps-1]`)

- **Imported:** `bhop_japan`, `bhop_exodus`, `kz_bhop_badg3s`, `surf_omnibus`, `surf_lore`, `surf_eclipse` (courses, each timed from the map's own spawn and finish), `kz_bhop_yonkoma` (a spawn and no finish: an adventure climb map whose end nothing marks) and `surf_legends` (combat, credit only). Each zones file says what was read and why. bhop_japan's players spawn in a dark drop box that teleports them to the map's `spawn`, so the run starts there; a START round the box would have left every player standing in the dark, because the importer clears pits round the spawn.
- **The entity parser kept only the first of a repeated key.** A trigger that does two things on touch has two `OnTrigger` keys, and `parse_entities` used `setdefault`. The anti-standing traps on bhop_japan, bhop_interloper and bhop_arcane_v2 rename the toucher `default` and then `activator` 0.09 s later, so the delay `trap_blocks` needs was in the dropped second output and 0, 0 and 0 blocks imported where 252, 538 and 379 belong. Repeats of an `On*` key are now joined with newlines, which both readers of outputs scan with a regex. The same change made the boost names on bhop_badges and badges_mini assignable, so 43 and 15 more of their pushes are live. `headless_mechanics`' `TRAP_BLOCK_FLOORS` holds the three maps' counts; armed by putting `setdefault` back.
- **A race surf map's round teleports were pits.** Reaching the end of surf_omnibus enables a `youlose<n>` teleport to the jail over every section; every one starts disabled, and this importer runs no outputs, so each was a pit that jailed a runner on entering a section. `round_teleports` in a zones file drops start-disabled teleports by name. It is opt-in, because sixteen of the held maps have start-disabled teleports and surf_mesa, surf_kitsune, surf_summit and surf_year3000 were zoned against the old behaviour. Not changed there.

## surf_kitsune against its own engines: a hidden rainbow and stages facing the wall (2026-10-09, `[ref-1]`)

Two reference runs (CS:GO and CS2, `/extra/external/video/reference/`) agree that kitsune is neon wireframe on black. Ours had a rainbow wall behind every section and every `!s<n>` facing a wall side-on. Both were the importer:

- **Twelve `func_brush`es named `kitsune` are transparent until a button fades them in.** `rendermode 4` (alpha from `renderamt`) at `renderamt 0`; a `func_button` in the map sends `kitsune,Alpha,75` on press and `0` on release. `drawn_faces` hid only `rendermode 10`, so 29,000-unit rainbowscroll tunnels were drawn at full strength. `invisible_by_alpha` hides any brush entity in an alpha render mode at `renderamt 0`; across the imported set only kitsune's twelve match.
- **A stage built `around` a destination faced yaw 0.** The box's floor took the zones file's `destination_yaw` or nothing, never the named point's own, so `!s<n>`, a stage restart and single-R faced every kitsune stage 90 degrees from the door into it (and two of surf_year3000's). `around_yaw` takes the points' yaw when they agree. `headless_imported`'s destinations section asserts a stage faces the way one of the map's own doors into it does (armed: the old import fails on all nine of kitsune's).

## surf_year3000's spawn was a sealed void, and a zones file can now cut geometry (2026-10-09, `[g2gfast-surf-year-1]`)

The SPAWN its zones file hand-placed "between the two platforms" stood in a 240 x 128 unit chamber walled, floored and roofed on every side: the dead space between the middle building's two arrival booths. Every check passed, because the player stood on a floor inside the start zone. Christian asked for the middle taken away, so `bsp_import.py` gained `remove_geometry` (zones key `"remove"`, see maps/zones/README.md): world brushes whose hull is inside a box, and the faces that belong only to them, are filtered out of `Bsp.model_brushes(0)` / `model_faces(0)`, which every consumer reads. 106 brushes and 287 faces went; the floor, the pushes and the arrival points stayed. The baked lightmap still shows the building's shadow. `headless_imported`'s collision section now asks whether the player is shut in where it rests (16 rays at waist height, one must run 5 m; the void's longest was 3.2 m, the smallest real start rooms 6.9 and 7.4 m), armed by re-importing without the key.

## Water draws as water (2026-10-09)

The source game's water materials are never inside a map, so every pool, canal and river on the imported maps was the opaque prototype grid: a floor a player could not see into and then sank through. `G2GBspMap.is_water_material` (a material whose file name says `water` and not `waterfall`; about 190 surfaces over the 51 held maps, none with a shipped texture) now gets `g2g_bsp_water.gdshader`: translucent, `cull_disabled` because a swimmer looks up at the `_beneath` faces, a slow swell and a finer chop in world metres, lit by the lightmap, in the map's measured colour unless that is grey. In `_material_for` rather than the importer, so published packs get it. A map that shipped its own water texture keeps it. `headless_imported` asserts per map that every such surface carries the water material (armed: 0 of 4 on surf_10x_reloaded_fixed). game-arena keeps a copy of the shader and the rule; keep the two in step.

## A sky the map packed is the sky drawn (2026-10-09, `[ref-2]`)

36 of the 75 held maps carry their own six sky faces in their pakfile (`materials/skybox/<skyname><rt|bk|lf|ft|up|dn>`), and every one was drawn as dot-lighting's procedural sky in a colour looked up by sky name: surf_beginner2's `sky47` is a sunset over the sea and it rendered as a clear blue noon against the reference footage. `bsp_import.packed_sky_faces` decodes all six (all or none: a missing face is a hole in the horizon) into `textures/sky_<suffix>.png` and lists them in the manifest's `lighting.sky_faces`; `G2GBspMap._apply_packed_sky` puts them on `g2g_sky.gdshader` over the procedural sky `G2GLighting` built. The face layout is Quake's, which the format kept; the shader's header has the table, and a wrong one shows as a horizon broken at the seams (checked by looking round surf_beginner2's spawn). A map without the faces, or a pack published before them, keeps the procedural sky. The 36 were given their faces without a full re-import (the importer's function run against each map's .bsp). `headless_imported`'s *a sky it packed is the sky drawn* asserts all six faces are bound. bhop_lego2's spawn renders black in `bsp_preview`, with and without this change; not looked into.


## Three of the new maps failed `headless_mechanics`, and two were the suite (2026-10-09)

- **surf_29_12_06: a teleport aimed at a brush entity.** All 13 of its live teleports target other teleports' brushes (`g1`..`b4`, `a`, `b`, `jail`), which the engine resolves to that entity's origin. `Zoner.destinations` took point entities only, so every one became a pit to the spawn. Brush entities are now the last fallback. Its other 13 teleports have no target at all and do nothing in the source engine; they are still pits to the spawn here, as on bhop_pandora2_fix, surf_eclipse and surf_omnibus, which is left alone because those maps were zoned against it.
- **surf_the_gloaming: the scout round.** Four start-disabled teleports over the spawn room, enabled by a round this game does not run, imported as pits whose destination chain ends in a cycle, so they sent a spawning player to the spawn inside them. Dropped by `round_teleports` in its zones file. The suite's "loops" was a separate false alarm: a pit cut into slabs is several overlapping zones, and a player in three of them is sent three times on one tick; it counts distinct ticks now.
- **surf_greatriver_v4: a ladder with a ledge over one side.** The suite put the climber on whichever side had room at the foot, which here runs under a ledge 11 units up. It asks for room 96 units up the ladder as well.
