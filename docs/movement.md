# Movement, units and the motor

The movement is the product. Everything here is about keeping a run set on this server comparable with one set on another, at another tick rate, by a player whose fingers learned the genre somewhere else.

## Everything the operator touches is in genre units

`sv_airaccelerate 1000`, `sv_gravity 800`, a run speed of 250 u/s, a surf ramp "1024 wide at 60°". A bhop server operator knows what those mean and nobody knows what 19.05 m/s² is. So every cvar, every config field, every HUD number and every map file speaks genre units, and **the conversion to the metres the simulation runs in happens at exactly one boundary, `G2GMovement.tunables_for`**, with `G2GUnits` as the only definition of the ratio. A conversion anywhere else is a second copy of the ratio, and two copies drift.

The ratio is **1 unit = 0.01905 m** (0.75 inch), the scale the genre's maps were built at, not the 1-inch figure sometimes quoted. It is what the 72-unit hull, the 64-unit eye and every map in the genre were built against; at the wrong scale a surf ramp is one the movement cannot hold. It is also why an imported `.bsp` needs no scale conversion at all (see [imported-maps.md](imported-maps.md#scale-and-axes)).

The jump is specified as a **launch velocity** (301.99 u/s) and converted to the height the tunables want with `h = v²/2g`: 57 units under 800, the number every bhop player knows. Specifying the velocity keeps it honest when an operator changes `sv_gravity`.

The client's configuration is layered like the server's (`G2GClient` calls `load_layered()`), so `--g2g-initial-map` works offline as well. It once built a bare `G2GConfig`, and no suite could see it because every suite sets `config.initial_map` directly. Only an authoritative instance chooses a map: `validate()` accepts an empty `initial_map` on a client, which the server decides.

## Auto-bhop is the server's, and the styles defer to it

`sv_autobunnyhopping` (`G2GConfig.auto_bhop`) is the setting this game exists to expose. It reaches every player through `G2GGame.apply_movement`, which rebuilds the tunables and hands them to everybody, **abandoning every run in progress**, because a run half on one movement and half on another is a run on neither. Same rule as a tick-rate change.

**The shipped `DotFpsStyle.defaults()` force auto-hop ON**, which is right for a game with no cvar and wrong here: left as shipped, `sv_autobunnyhopping 0` reached every player's tunables and was then silently undone by the style on top. `_build_styles` sets every style's `auto_hop` and `easy_bhop` to `INHERIT`, except `prebhop`, whose whole identity is "no auto-hop".

**A movement cvar is validated before the config is written**, through the console's own validator on a *copy* of the config. Writing first and validating after left the config invalid on a failure, after which every later cvar wrote its field, found the config still invalid because of the first, and quietly did nothing while the console reported them all as set.

With `sv_enablebunnyhopping 0` the landing cap trims every take-off to 275 u/s and neither hand-built bhop map's main route exists (see [routes.md](routes.md#what-a-jump-reaches)). An operator turning it off is turning those maps into their warm-up routes.

## A held jump from a standstill creeps at 30 u/s, and that is faithful

A player holding jump from a standstill creeps at exactly 30 u/s, the air cap, for ever. On the tick a jump fires the player is already airborne when acceleration runs, so a held key never gets a ground-acceleration tick. The genre's own movement does precisely this (the jump check runs before the walk move), which is why every real bhop run begins with a **prestrafe**. Every bot in the suites walks before it hops.

## A movement effect is a style, and a style you did not choose is a record you did not set

Everything in this game exists to make a run comparable with one somebody else set: sub-tick zone crossings, a rate taken from `sv_tickrate` rather than an export, styles paired between dot-player-controller and dot-timer by id. **An effect that quietly multiplies `max_speed` by 0.65 undoes all of it**, and the player has no way of knowing it happened. So `G2GEffects` splits effects, and enforces the split:

| | |
| --- | --- |
| **Combat effects** (a bleed, a burn) | Anybody, any time. They cannot change a time. |
| **Movement effects** (a maul, a haste) | **Refused** while a ranked run is live. |

`G2GEffects.is_movement()` asks the *definition* whether it changes `move_speed_scale` or `jump_scale`, rather than consulting a list of ids, so an effect added later is classified by what it does. A server that wants hunted runs to count anyway sets `allow_movement_during_runs`, and every such run is **tainted** (see [timer.md](timer.md#what-taints-a-run)).

## The player layer

`G2GPlayerStack` joins dot-spawn, dot-player and the rest to the controller.

- **The spawn director chooses the start, and the map is the fallback.** What it adds over the map is the per-site cooldown, the occupancy check and, with `sv_deathmatch` on, the protection window, which `DotSpawnProtection.grant` only ever opens from inside `DotSpawnDirector.choose`.
- **A start is per TRACK.** `DotSpawnConditions.MetaMatchesRequest` (added to dot-spawn for this game) compares a site against the *request*, and `DotSpawnRequest.make` carries an `extra` dictionary for it. `MetaEquals` compares against a constant, which would have meant one director per track.
- **The sites are checked against the loaded map rather than trusted to arrive in order.** `map_ready` and the respawn that follows a map change are not ordered, and losing that race means answering confidently from the previous map (family [bugs-found.md](../../../docs/bugs-found.md)).
- **`sv_deathmatch` is what opens the protection window**, and it is shut on a pure timer server: a window with no attacker is a rule with no purpose. The duration is `G2GArsenal`'s own match rule rather than a second copy.

## Third person is cosmetic, and stays `G2GCamera`'s

`G2GCamera` flips between two cameras over **one motor**, so a run set in third person is comparable with one set in first. game-playground runs dot-player-controller's third-person controller over a `DotPlayerControllerSwitch`; **this game deliberately does not.** `DotTpsController` is a different motor (camera-relative input, its own acceleration, coyote time, a jump buffer), and a player who could switch to it mid-run would be setting a time on movement nobody else was using. `sv_allow_thirdperson 0` is server-side because third person sees over ledges first person cannot, and it puts anybody already in it back. It now writes the family's `mp_forceview` (dot-player-controller's `DotPlayerViewRules`: 0 the player's choice, 1 first person only, 2 third person only), which `G2GGame` keeps every camera under (`G2GCamera.follow_view_rules`) and which is bound REPLICATED and followed through the link, on top of RULES' `thirdperson` for an older server.

The third-person camera hangs on dot-core's `DotCameraBoom` (it was a `SpringArm3D`, which cast a ray and snapped); a `DotCameraFade` on each camera is handed the other players, hiding one at the lens and fading one between the third-person camera and you. `tools/camera_check.gd` flies the camera round the start map's walls (armed) and checks the rule both ways; under xvfb it draws both views.

## Ladders and water

- **Ladders** (`CONTENTS_LADDER` brushes in imported maps) are climbed through `G2GLadderMode`, a `DotFpsMoveMode` using the engine's own decomposition (the wish into the face becomes up the face). It lives in the game, not the addon, so a delivered pack names no new class. It must not call the motor's `categorise_ground` every tick: that writes AIR for anybody rising who was not grounded, and every climber was dropped each tick and bounced up at a quarter speed. **A ladder wins over water**, as in the engine these maps come from: a climb-out pit of ladder walls over water otherwise hands every climber back to the swim mode.
- **Water** registers dot-player-controller's `DotFpsSwimMode` on every player (200 u/s, with `idle_sink_speed` so a player who lets go sinks at 60 u/s the way the genre's water does; holding jump rises). Which volumes are water is the importer's (see [imported-maps.md](imported-maps.md#what-a-maps-brush-entities-do)).

## Ramps and the motor

A surf ramp is ridden, not stood on, and only the second question is what a surf map is. `tools/surf_probe.gd` sweeps the hull down the steepest line of every RAMP triangle and `tools/surf_run.gd` and `tools/ramp_bump_probe.tscn` run the real `DotFpsMotor` along them. A run that dies halfway down a ramp is invisible to every assertion here: the ramp is solid, the spawn is fine and the map is right in a screenshot.

What the probes established, and what is still open:

- **The slope rule is not the problem.** No simulated tick reports grounded on a face steeper than `max_slope`, so friction is never applied to a ride.
- **Genuine wedges (slide iterations exhausted) are almost nil.** What fires is the **duplicate-plane early-out**: `_remember_plane` treats normals within 2.56° as one plane, which is right for one long ramp and is the exact shape of an imported one, because **a curved ramp is a fan of convex hulls a degree apart**. The move breaks with most of the tick unspent, keeping the velocity: a player holding 900 u/s on the HUD and crawling. `DotFpsMotor.stuck_ticks` counts that intended early-out too; read `ran_out` and `stopped_on_duplicate`, which are separate.
- **Two maps fail for different reasons.** On surf_mesa most of the early-outs are the displacement trimesh (a hull sliding over loose triangles catches on interior edges); on surf_beginner2 all of them are brush hulls.
- **Tried and not kept:** the classic 1.001 overbounce (`_resolve_planes` clips with an exact `Vector3.slide`), which moved the count the wrong way; clipping and continuing instead of breaking, which helped little. Both are changes to collide-and-slide in an addon five games share and the netcode predicts against; neither earned that. The decision is dot-player-controller's.
- **Fixed in dot-player-controller (`[ramp-pop-1]`):** Godot's `get_rest_info` reverses a resting normal (on a plain box too), so a rider resting on a face read 57 units deep along its reverse and was depenetrated a whole `step_height` into the ramp and back out the next tick. That was the "ramps are jumpy" report.
- **Fixed in the importer:** every brush seam was a bump until coplanar brushes were merged (see [imported-maps.md](imported-maps.md#the-solid-is-the-brushes)).
- **Fixed in dot-player-controller (`[bank-hang-1]`):** a surfer stopped dead on a bank when `sweep` answered a contact it could not name with the reverse of the motion.
- **Open (the crease hang, dot-player-controller's):** a rider pressed into one slab with another underneath can be pinned by the duplicate-plane early-out, losing all forward speed and hanging ungrounded. It is order-sensitive in `headless_run` (whether the bot reaches a crease still pressing depends on which sections ran before), which is why the stages map's surf bonus bot lets go of the face at `CREASE_RELEASE`.

**Every before-and-after in a tool that samples has to sample the same things.** `Array.shuffle()` uses the global RNG; both probes seed now. A tool that does not will produce a trend on request.

## Numbers that explain the hull

The survey and the reach use the tunables' own numbers in units: hull `2 × radius` = **32 u**, crouched headroom 54, step 18, slope limit 45.57°. A surface steeper than that is a ramp; a 45° slab is a floor, which is why the stages map's surf bonus faces are 50° (`BONUS_RAMP_PITCH`, map data; the box turns by 90 minus it, because the builder's angle is the box's turn, not the face's).
