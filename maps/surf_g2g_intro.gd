extends "../game/g2g_map.gd"

const G2GGeometry := preload("../game/g2g_geometry.gd")

## `surf_g2g_intro` — two ramps meeting in a valley, descending, with three bonuses.
##
## Surf ramps are built at angles a player cannot stand on — the standable
## limit is a normal of 0.7, about 45.6° — and this one is 60°. The player drops off
## the start platform onto a face too steep to stand on, slides under gravity, and
## strafes to keep and gain speed. The seam between the two ramps is the geometry
## dot-player-controller's crease resolution exists for.
##
## Everything in genre units. The valley falls 3072 units over 8192.
##
## [b]The ramps above are level along their length and the descent is the floor's.[/b]
## That is measured rather than suspected — `headless_run` prints how much of the route
## a bot actually rides — and `the fall line`, bonus 3, is the route on this map where
## the answer is the ramp. See the constants below it.
##
## [b]It declares no course (`G2GMap.add_course`), and that is an answer rather than an
## omission.[/b] Every way from one surface to the next here is a drop onto something
## below — a pad onto a bank, a bank onto a bank, a bank's end onto a finish — and the
## question a drop asks is whether the thing below is there, which only riding it
## answers. `headless_run` drives a bot down all four, and two of them to the finish.

const START_Z := 0.0
const END_Z := -8192.0
const START_Y := 2048.0
const END_Y := -1024.0
const VALLEY_HALF_WIDTH := 96.0
const RAMP_WIDTH := 1024.0
const RAMP_ANGLE := 60.0
const RAMP_THICKNESS := 32.0

# --- Bonus 1: the single bank ----------------------------------------------
#
# Named rather than written into `_build`, and every value is the one the bonus has
# always had: `headless_run` drives a bot down it and reads its line off these, so moving
# the bank moves the bot with it.
const BONUS_X := 1536.0                       ## the pad's centre, and the finish pad's
const BONUS_BANK_X := BONUS_X + 256.0
const BONUS_BANK_Y := START_Y - 200.0
const BONUS_BANK_Z := START_Z - 800.0
const BONUS_BANK_WIDTH := 768.0
const BONUS_BANK_LENGTH := 2048.0
const BONUS_FINISH_Y := START_Y - 1200.0
const BONUS_FINISH_SIZE := 512.0              ## across (X)
## Along the run (Z). [b]Was 512, the same as across[/b], and only a rider leaving the
## bank under about 450 u/s came down on it: one that strafed properly left at 866 u/s
## and fell into the pit 1,578 units past it (`[surf-finish-1]`). The near edge is where
## it always was, so every landing the old pad caught it still catches and old times
## stay comparable; the far edge takes a rider leaving at 1,100 u/s from anywhere on the
## strip over the pad (measured: 900 u/s lands at -3,050 to -3,245, 1,100 at -3,560).
const BONUS_FINISH_LENGTH := 1792.0
const BONUS_FINISH_NEAR_Z := START_Z - 1944.0
const BONUS_FINISH_Z := BONUS_FINISH_NEAR_Z - BONUS_FINISH_LENGTH * 0.5  ## its centre


## X of the bank's low lip. `-RAMP_ANGLE` about `Vector3.FORWARD` is a positive turn
## about +Z, so its +X edge is the high one and a rider is thrown toward -X: off this
## edge. Only the strip of bank between here and the finish pad's far edge lies over
## the pad, and a rider who leaves the bank higher up than that misses the finish.
static func bonus_bank_lip_x() -> float:
	return BONUS_BANK_X - cos(deg_to_rad(RAMP_ANGLE)) * BONUS_BANK_WIDTH * 0.5


## Z of the bank's far end, where a rider leaves it for the finish pad.
static func bonus_bank_end_z() -> float:
	return BONUS_BANK_Z - BONUS_BANK_LENGTH * 0.5


## Height of the bank's riding surface at [param x], units: what a rider's feet are on.
static func bonus_bank_surface_y(x: float) -> float:
	var angle := deg_to_rad(RAMP_ANGLE)
	return BONUS_BANK_Y + (x - BONUS_BANK_X) * tan(angle) + RAMP_THICKNESS * 0.5 / cos(angle)


# --- Bonus 3: the fall line ------------------------------------------------
#
# [b]The route where the descent comes from the ramp.[/b] Every other surface on this
# map that is called a ramp is banked about the run axis and LEVEL along its length —
# `G2GGeometry.ramp` rotates about `Vector3.FORWARD`, which tilts a slab in X and Y and
# leaves its Z extent horizontal — so a player riding one is carried sideways into the
# valley and every metre they descend afterwards comes from the stepped floor. Driving
# it says so: a bot on the main track rides under 5% of a 156 m route, crosses neither
# split, and the 636 u/s the suite reads as "surf speed" is what falling into the pit is
# worth. See `[surf-ramp-1]`.
#
# This route is the same two banked faces PITCHED downhill, so the fall line runs along
# the route instead of across it. The bank is unchanged at 60° and still past anything a
# player can stand on, which is what makes it surf rather than a slide; the pitch is what
# makes the ramp, rather than the floor under it, the thing that makes a player fast.
#
# [b]It is a pitched BED with a bank either side, and it was a V first.[/b] The first
# draft made the whole route out of two banked faces meeting in a crease, on the theory
# that a V self-centres and is therefore drivable by a bot that cannot air-strafe. It
# does self-centre, and it is not surf: two faces banked the same amount opposite ways
# resolve to a normal pointing straight UP, so the crease of a V built out of two
# surfaces nobody can stand on is a surface everybody can stand on. Driven, the bot
# rode 18 m, came to rest in the crease and sat there for the remaining 1,200 ticks.
#
# So the thing carrying the player is a single face pitched past the standable limit,
# the way `the plunge` is in game-playlot — the bot holds forward and nothing else —
# and the two 60° banks are at the EDGES, where a drifting player is thrown back to the
# middle instead of off the route. That is the arrangement a surf map's own tube
# sections use, and it is the one that survives being driven.
const FALL_X := 3300.0
const FALL_PITCH := 50.0          ## downhill along the run. The whole point of the route
const FALL_BANK := 60.0           ## the two side faces, same as the main ramps: unstandable
const FALL_BED := 512.0           ## width of the pitched bed the route is actually ridden on
const FALL_FACE := 768.0          ## each side face's width, before banking
const FALL_TOP_Y := START_Y - 96.0
const FALL_TOP_Z := START_Z - 64.0
const FALL_RUN := 2816.0          ## horizontal Z the chute covers
const FALL_SPLITS := [1, 2]


## How far the fall line drops over its run. Derived, so moving the pitch moves the
## finish pad, the stage lines and the zone bounds with it rather than leaving three
## numbers to be updated by hand.
static func fall_drop() -> float:
	return FALL_RUN * tan(deg_to_rad(FALL_PITCH))


## The centre of the trough at a fraction along its run.
static func fall_point(t: float) -> Vector3:
	return Vector3(FALL_X, FALL_TOP_Y - fall_drop() * t, FALL_TOP_Z - FALL_RUN * t)



func _build() -> void:
	tier = 3
	G2GGeometry.sun(self)
	fallback_spawn_units = Vector3(0.0, START_Y + 8.0, START_Z + 256.0)

	# Start platform with a back wall.
	G2GGeometry.box(self, Vector3(0.0, START_Y - 16.0, START_Z + 256.0),
		Vector3(768.0, 32.0, 512.0), G2GGeometry.COLOUR_START)
	G2GGeometry.box(self, Vector3(0.0, START_Y + 64.0, START_Z + 520.0),
		Vector3(768.0, 160.0, 32.0), G2GGeometry.COLOUR_PLATFORM)

	var length := absf(END_Z - START_Z)
	var centre_z := (START_Z + END_Z) * 0.5
	var lift := sin(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5
	var out := cos(deg_to_rad(RAMP_ANGLE)) * RAMP_WIDTH * 0.5

	for side in [-1.0, 1.0]:
		G2GGeometry.ramp(
			self,
			Vector3(side * (VALLEY_HALF_WIDTH + out), (START_Y + END_Y) * 0.5 + lift, centre_z),
			Vector3(RAMP_WIDTH, RAMP_THICKNESS, length),
			-side * RAMP_ANGLE, Vector3.FORWARD
		)

	# The descending valley floor, in steps.
	var steps := 16
	for i in range(steps):
		var t := float(i) / float(steps - 1)
		G2GGeometry.box(
			self,
			Vector3(0.0, lerpf(START_Y - 256.0, END_Y, t) - 16.0, lerpf(START_Z - 256.0, END_Z + 256.0, t)),
			Vector3(VALLEY_HALF_WIDTH * 2.0, 32.0, length / float(steps) + 64.0),
			G2GGeometry.COLOUR_FLOOR
		)

	# Finish pad.
	G2GGeometry.box(self, Vector3(0.0, END_Y - 16.0, END_Z - 320.0),
		Vector3(768.0, 32.0, 640.0), G2GGeometry.COLOUR_END)

	# Bonus: a single short ramp beside the start.
	G2GGeometry.box(self, Vector3(BONUS_X, START_Y - 16.0, START_Z + 256.0),
		Vector3(384.0, 32.0, 384.0), G2GGeometry.COLOUR_BONUS)
	G2GGeometry.ramp(self, Vector3(BONUS_BANK_X, BONUS_BANK_Y, BONUS_BANK_Z),
		Vector3(BONUS_BANK_WIDTH, RAMP_THICKNESS, BONUS_BANK_LENGTH), -RAMP_ANGLE,
		Vector3.FORWARD, G2GGeometry.COLOUR_BONUS)
	G2GGeometry.box(self, Vector3(BONUS_X, BONUS_FINISH_Y - 16.0, BONUS_FINISH_Z),
		Vector3(BONUS_FINISH_SIZE, 32.0, BONUS_FINISH_LENGTH), G2GGeometry.COLOUR_END)

	# Bonus 2: the transfer, on the other side of the start.
	#
	# [b]A different skill from bonus 1, not a longer version of it.[/b] That one is a
	# single bank: get on it, hold it, ride it down. This is two banked the opposite
	# way with a gap between them, so the run ends at the moment the first ramp stops
	# and the player has to be airborne, pointed, and moving in the right direction to
	# catch the second. Which way a surface throws you is the whole of surf, and a map
	# with one ramp never asks the question twice.
	#
	# The direction each one throws is worth writing down, because it is the sign that
	# is wrong first: `G2GGeometry.ramp` rotates about +Z, so a POSITIVE angle lifts
	# the -X edge and the player slides toward +X. Bonus 1 uses the negative and runs
	# the other way, which is why these numbers are not its mirror.
	G2GGeometry.box(self, Vector3(-1536.0, START_Y - 16.0, START_Z + 256.0),
		Vector3(384.0, 32.0, 384.0), G2GGeometry.COLOUR_BONUS)

	# [b]A banked ramp is narrower in X than it is wide.[/b] At 60 degrees a 768-unit
	# ramp occupies 768 * cos(60) = 384 units of X, so its lip is 192 either side of
	# its centre and not 384 -- and its surface climbs 192 * tan(60) = 333 units over
	# that. Every number below is placed off those two, because the first draft put
	# the pad over a strip of X the ramp did not reach and the bot walked into the pit.
	#
	# Ramp one is centred UNDER the pad rather than beside it. The drop is 250 units
	# onto the middle of the bank, which is a landing rather than an edge catch.
	G2GGeometry.ramp(self, Vector3(-1536.0, START_Y - 250.0, START_Z - 600.0),
		Vector3(768.0, RAMP_THICKNESS, 1600.0), RAMP_ANGLE, Vector3.FORWARD,
		G2GGeometry.COLOUR_BONUS)

	# And back the other way. Its high side sits at x -1300, just past where the first
	# one's lip throws the player out at -1344, and 117 units below it -- so the
	# transfer is a short fall onto a surface banked the opposite way rather than a
	# gap that has to be jumped. The two meet in Z rather than leaving air between
	# them: the skill being asked for is reading which way a surface throws you, and
	# a hundred units of nothing in the middle of it turns that into a coin flip.
	#
	# [b]It runs the whole length of the first one, not the back half of it.[/b] A
	# banked ramp throws you off its lip wherever you happen to reach it, and the first
	# draft put the second ramp only under the last third of the first -- so a player
	# who came off early fell through the gap between them and out of the level. Which
	# is a route that works if you already know where the catch is, and is nothing if
	# you do not.
	G2GGeometry.ramp(self, Vector3(-1492.0, START_Y - 1033.0, START_Z - 1000.0),
		Vector3(768.0, RAMP_THICKNESS, 2800.0), -RAMP_ANGLE, Vector3.FORWARD,
		G2GGeometry.COLOUR_BONUS)

	# A floor under the whole thing, falling toward the finish in steps, the way the
	# main track's valley does. On a tier-3 map's bonus the punishment for losing the
	# bank is losing the time, not losing the run: the floor is slow, it is reachable,
	# and it ends at the same pad the ramps do.
	var bonus_steps := 8
	for i in range(bonus_steps):
		var t := float(i) / float(bonus_steps - 1)
		G2GGeometry.box(
			self,
			Vector3(-1500.0, lerpf(START_Y - 700.0, START_Y - 1500.0, t) - 16.0,
				lerpf(START_Z, START_Z - 3000.0, t)),
			Vector3(640.0, 32.0, 3000.0 / float(bonus_steps) + 64.0),
			G2GGeometry.COLOUR_FLOOR
		)

	G2GGeometry.box(self, Vector3(-1500.0, START_Y - 1560.0 - 16.0, START_Z - 3300.0),
		Vector3(768.0, 32.0, 640.0), G2GGeometry.COLOUR_END)

	_build_fall_line()


## Bonus 3 — the fall line. See the constants above for why it exists.
func _build_fall_line() -> void:
	# A pad that reaches the chute. The other three pads stop at `START_Z + 64` and
	# nothing is under the 128 units between there and this route's mouth, so this one
	# is 512 deep rather than 384 and its back edge IS `FALL_TOP_Z`. A pad that stops
	# short of the thing it feeds is a route that begins with a fall, and a fall is
	# what the rest of this map already does.
	G2GGeometry.box(self, Vector3(FALL_X, FALL_TOP_Y - 16.0, START_Z + 192.0),
		Vector3(384.0, 32.0, 512.0), G2GGeometry.COLOUR_BONUS)

	# [b]Rotating about +X by a NEGATIVE angle sends the -Z end down[/b], and -Z is the
	# direction every route on this map runs. `G2GGeometry.ramp` rotates about
	# `Vector3.FORWARD` instead, which tilts a slab in X and Y and leaves its Z extent
	# horizontal — which is why every other ramp on this map is level along its length.
	var pitch := Basis(Vector3.RIGHT, deg_to_rad(-FALL_PITCH))
	var centre := fall_point(0.5)

	# [b]A pitched slab has to be LONGER than the ground it covers[/b]: it spans
	# `FALL_RUN` of Z along a surface inclined at `FALL_PITCH`, so its own length is
	# that over the cosine. Getting this wrong shortens the route and leaves the finish
	# pad hanging in the air past the end of the ramp.
	var slab_length := FALL_RUN / cos(deg_to_rad(FALL_PITCH))

	# The bed. `fall_point` is its CENTRE, so the surface ridden on is half a thickness
	# above the line every zone below is placed off — which is inside the tolerance of
	# all of them and is why they are all written against one function.
	G2GGeometry.box(self, centre,
		Vector3(FALL_BED, RAMP_THICKNESS, slab_length),
		G2GGeometry.COLOUR_RAMP, pitch)

	var out := cos(deg_to_rad(FALL_BANK)) * FALL_FACE * 0.5
	var lift := sin(deg_to_rad(FALL_BANK)) * FALL_FACE * 0.5

	for side in [-1.0, 1.0]:
		# Each bank's low edge lands on the bed's own edge: a face banked this way has
		# its low edge `out` in and `lift` down from its centre, so centring it
		# `FALL_BED * 0.5 + out` out and `lift` up puts that edge exactly on the seam.
		# Then the whole offset is pitched with the slab, so the bank follows the bed
		# down rather than crossing it.
		var offset := pitch * Vector3(
			side * (FALL_BED * 0.5 + out), lift + RAMP_THICKNESS * 0.5, 0.0
		)
		G2GGeometry.box(
			self,
			centre + offset,
			Vector3(FALL_FACE, RAMP_THICKNESS, slab_length),
			G2GGeometry.COLOUR_BONUS,
			pitch * Basis(Vector3.FORWARD, deg_to_rad(-side * FALL_BANK))
		)

	# The run-out and the finish, level with the bed where it ends. Wide and long,
	# because a player arriving here is doing better than 1,500 u/s down a 50° face and
	# a pad they can overshoot is a route that ends in the pit for the one reason that
	# is not the player's fault.
	var bottom := fall_point(1.0)
	G2GGeometry.box(self, Vector3(FALL_X, bottom.y - 16.0, bottom.z - 768.0),
		Vector3(1024.0, 32.0, 1536.0), G2GGeometry.COLOUR_END)


func timer_zones() -> DotTimerZoneSet:
	return build_zones()


static func build_zones() -> DotTimerZoneSet:
	var zones := DotTimerZoneSet.new()
	zones.map_id = &"surf_g2g_intro"
	zones.meta["tier"] = 3
	zones.meta["author"] = "g2gfast"

	var main := DotTimerTrack.MAIN

	zones.add(zone_box(DotTimerZone.Kind.START, main,
		Vector3(-384.0, START_Y, START_Z), Vector3(384.0, START_Y + 256.0, START_Z + 512.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, main,
		Vector3(-384.0, END_Y, END_Z - 640.0), Vector3(384.0, END_Y + 512.0, END_Z - 128.0)))

	# Each stage line carries where `!s<n>` puts a player: above the ramp mouth at
	# that height, facing down the run. A surf stage restart is worth more than a bhop
	# one — the alternative is riding the whole descent again to reach the section
	# being learned — and it is the reason `restart_stage` exists at all.
	for i in range(1, 3):
		var t := float(i) / 3.0
		var z := lerpf(START_Z, END_Z, t)
		var y := lerpf(START_Y, END_Y, t)
		zones.add(zone_stage(
			main, i,
			Vector3(-1200.0, y - 900.0, z - 96.0),
			Vector3(1200.0, y + 900.0, z + 96.0),
			Vector3(0.0, y + 192.0, z + 64.0),
			# Facing down the course, which is yaw 0 (-Z) like the spawn zones. This was
			# 180, which faced a restarted player back at the start (`[stage-yaw-1]`).
			# A `!s` stops the run, so no record was ever set from here and none moves.
			0.0
		))

	zones.add(zone_box(DotTimerZone.Kind.RESPAWN, main,
		Vector3(-16384.0, END_Y - 4096.0, END_Z - 16384.0),
		Vector3(16384.0, END_Y - 1536.0, START_Z + 16384.0)))
	zones.add(zone_spawn(main, Vector3(0.0, START_Y + 8.0, START_Z + 320.0), 0.0))

	var bonus := DotTimerTrack.of_bonus(1)
	zones.add(zone_box(DotTimerZone.Kind.START, bonus,
		Vector3(1344.0, START_Y, START_Z + 64.0), Vector3(1728.0, START_Y + 256.0, START_Z + 448.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, bonus,
		Vector3(BONUS_X - BONUS_FINISH_SIZE * 0.5, START_Y - 1300.0, BONUS_FINISH_NEAR_Z - BONUS_FINISH_LENGTH),
		Vector3(BONUS_X + BONUS_FINISH_SIZE * 0.5, START_Y - 900.0, BONUS_FINISH_NEAR_Z)))
	zones.add(zone_spawn(bonus, Vector3(1536.0, START_Y + 8.0, START_Z + 300.0), 0.0))

	var transfer := DotTimerTrack.of_bonus(2)
	zones.add(zone_box(DotTimerZone.Kind.START, transfer,
		Vector3(-1728.0, START_Y, START_Z + 64.0), Vector3(-1344.0, START_Y + 256.0, START_Z + 448.0)))
	zones.add(zone_box(DotTimerZone.Kind.END, transfer,
		Vector3(-1884.0, START_Y - 1700.0, START_Z - 3620.0),
		Vector3(-1116.0, START_Y - 1180.0, START_Z - 2980.0)))
	zones.add(zone_spawn(transfer, Vector3(-1536.0, START_Y + 8.0, START_Z + 300.0), 0.0))

	# [b]A respawn zone per bonus, because a zone belongs to a track.[/b] The main
	# track has had one since the map was written and both bonuses had none, so a
	# player who missed a bonus ramp did not get put back -- they fell, and kept
	# falling, for as long as they were prepared to watch. It is the main track's own
	# bug from before `DotTimer.effect_requested` was connected, still live on two
	# tracks, and it stayed invisible because nothing had ever driven a bonus.
	# Bonus 3 — the fall line. Every bound below is read off `fall_point`, which is the
	# crease itself, so changing the pitch moves the geometry, the splits, the finish
	# and this zone set together. The map that this route was added to has four numbers
	# for its own finish pad written out by hand and they are the reason `[track-zone-1]`
	# exists.
	var fall := DotTimerTrack.of_bonus(3)
	var mouth := fall_point(0.0)
	var foot := fall_point(1.0)

	zones.add(zone_box(DotTimerZone.Kind.START, fall,
		Vector3(FALL_X - 192.0, FALL_TOP_Y, START_Z + 64.0),
		Vector3(FALL_X + 192.0, FALL_TOP_Y + 256.0, START_Z + 448.0)))
	zones.add(zone_spawn(fall, Vector3(FALL_X, FALL_TOP_Y + 8.0, START_Z + 300.0), 0.0))
	zones.add(zone_box(DotTimerZone.Kind.END, fall,
		Vector3(FALL_X - 512.0, foot.y, foot.z - 1536.0),
		Vector3(FALL_X + 512.0, foot.y + 512.0, foot.z)))

	# Yaw 0 is -Z, which is the direction every route on this map runs and what its
	# SPAWN zones already use. `headless_run` asserts every stage line faces the next.
	for i in FALL_SPLITS:
		var t := float(i) / float(FALL_SPLITS.size() + 1)
		var at := fall_point(t)
		zones.add(zone_stage(
			fall, i,
			Vector3(FALL_X - 640.0, at.y - 192.0, at.z - 96.0),
			Vector3(FALL_X + 640.0, at.y + 640.0, at.z + 96.0),
			# 128 units UPHILL of the line and 64 over the bed there. It was 64 over
			# the bed at the line itself, which 128 units uphill is 152 units under
			# the bed's surface: `!s1` and `!s2` put a player beneath the chute and
			# they fell into the pit. Found by `headless_maps`' survey (2026-09-27).
			fall_point(t - 128.0 / FALL_RUN) + Vector3(0.0, 64.0, 0.0),
			0.0
		))

	for track in [bonus, transfer, fall]:
		zones.add(zone_box(DotTimerZone.Kind.RESPAWN, track,
			Vector3(-16384.0, END_Y - 4096.0, END_Z - 16384.0),
			Vector3(16384.0, END_Y - 1536.0, START_Z + 16384.0)))

	return zones
