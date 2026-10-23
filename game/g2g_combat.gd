extends Node

const G2GArsenal := preload("g2g_arsenal.gd")
const G2GGame := preload("g2g_game.gd")
const G2GPlayer := preload("g2g_player.gd")
const G2GStats := preload("g2g_stats.gd")

## The deathmatch half: dot-combat, dot-loadout and dot-match on a movement server.
##
## [b]Off unless `sv_deathmatch` is on, and while it is on the timer keeps running.[/b]
## That is the whole design decision and it is not a compromise: a surf server with
## deathmatch is a server where some people are running and some people are shooting,
## and the ones running must not be stopped by the ones shooting. So this layer adds
## hitboxes, health, an arsenal and a scoreboard, and takes nothing away — a player who
## never presses fire plays exactly the game they played before.
##
## [b]Entity ids come from [DotEntityTable] and are not derived from anything.[/b] They
## used to be the player's own id with the `u` taken off, which worked and taught the
## family why it should not: a derived id means a formula, a formula has an inverse, and
## the two ends of one serialisation are exactly as capable of never meeting as the two
## ends of a wire. The comment that used to sit on that inverse said so. Now the game
## opens an entity keyed on the player id and asks the table in both directions, which
## is also how [method player_id_for] stopped being a linear scan.
##
## [b]What the `u` still comes off for is the userid[/b], which is a different thing
## that happened to share the function: a loadout's storage key and
## `DotServer.session_by_userid` both want the account number, and neither wants a
## runtime handle. That is [method userid_of], and it is unchanged on disk.
##
## The ghost is deliberately excluded: it is a replay, it cannot be hurt, and
## registering it would put a bot on the scoreboard that never dies and never leaves.
##
## [codeblock]
## var combat := G2GCombat.new()
## manager.game = game
## add_child(combat)
## manager.setup()
## manager.enabled = true
## [/codeblock]

const CHANNEL := "g2g.combat"

## A player was killed. After the scoreboard has seen it, and after the server has picked how
## their body falls ([member G2GPlayer.death]). A hunter's kill comes through here too: it
## is world damage through the same manager.
signal player_killed(entry: DotKillFeed.Entry)

## A dead player is alive again, back at a start. A client shows the figure it hid.
signal player_respawned(player_id: StringName)

## A player's shot took health off somebody: the shooter's hit marker and damage number.
## Only what the authority applied, never a client's prediction, and never a refused hit,
## a hit that took nothing (a body, spawn protection) or one on yourself.
signal hit_landed(by: StringName, victim: int, amount: float, point: Vector3, killed: bool, headshot: bool)

@export_group("Rules")

## Whether anybody can be shot at all.
##
## Off. This is a timer server; deathmatch is a mode an operator turns on.
@export var enabled: bool = false

@export_range(0, 500, 1) var score_limit: int = 40

var game: G2GGame = null

## The dot-combat manager.
##
## Named `manager` rather than `combat` because this node is what a game calls
## `combat`, and `game.manager.combat` is a line nobody should have to read twice.
var manager: DotCombatManager = null
var loadouts: DotLoadoutManager = null
var match_node: DotMatch = null

## player id -> the components this layer hung off their node.
var _kit: Dictionary = {}

## The weapon definitions by id, for the death reaction a weapon asks for. Built on first use.
var _weapon_defs: Dictionary = {}

var _started: bool = false


func setup() -> DotResult:
	if game == null:
		return DotResult.fail(DotError.CODE_STATE, "Combat needs a game.")

	var built := _build_combat()

	if not built.ok:
		return built

	var matched := _build_match()

	if not matched.ok:
		return matched

	_build_loadouts()

	game.player_added.connect(_on_player_added)
	game.player_removed.connect(_on_player_removed)
	game.map_ready.connect(_on_map_ready)

	# Everybody already here. `setup` runs after the module has loaded and a listen
	# server may already have players, so a layer that only watched `player_added`
	# would arm nobody who was standing there when it was switched on.
	for id in game.players.keys():
		_arm(game.players[id])

	_started = true
	return DotResult.success(self)


func _build_combat() -> DotResult:
	manager = DotCombatManager.new()
	manager.name = "Combat"
	manager.is_authority = game.authoritative
	manager.register_service = false

	# Physics, not analytic. This game's players collide against Godot's physics —
	# `G2GPlayer` uses the stock `DotFpsController`, whose `_make_body` is a physics
	# body — so a shot traced against anything else would be traced against a world
	# the movement does not agree with. game-arena is the other way round and says so
	# for the same reason.
	var trace := DotTracePhysics.new()
	manager.trace = trace

	var rules := DotDamageRules.new()
	rules.friendly_fire = true
	# Off. Rocket jumping is what self damage is for and there is nothing here that
	# rockets; what self damage would actually do on a surf map is kill people who
	# landed badly, which is the fall damage this game deliberately does not have.
	rules.self_damage = false
	rules.hit_groups = true
	rules.falloff = false
	rules.maximum = 400.0
	manager.rules = rules

	var config := DotCombatConfig.new()
	config.tick_rate = game.tick_rate
	config.lag_compensation = true
	config.max_origin_error = 3.0
	manager.config = config

	add_child(manager)

	# AFTER add_child: `DotCombatManager.setup` runs from `_ready` and that is what builds
	# the resolver, so assigning the hook beforehand writes to nothing. game-arena's
	# combat build carries the same warning for the same reason.
	#
	# [b]The spawn window, asked at the one point every hit goes through.[/b] `health`
	# already refuses inside its own window, and this is the gate that makes dot-spawn's
	# ledger mean something: it is granted per respawn in `_on_respawn_due`, drained by
	# `DotSpawnProtection.advance` every tick, and until this line nothing ever asked it a
	# question. A veto applied at the damage sites instead would be one applied at the
	# sites somebody remembered.
	manager.resolver.adjust = _adjust_damage

	for type in G2GArsenal.damage_types():
		manager.register_damage_type(type)

	manager.entity_killed.connect(_on_entity_killed)
	manager.damage_applied.connect(_on_damage_applied)

	return DotResult.success(manager)


## Turns dot-combat's applied damage into [signal hit_landed] for the player who fired.
func _on_damage_applied(damage: DotDamage) -> void:
	if not game.authoritative or damage.refused or damage.health_lost <= 0.0 \
			or damage.attacker == 0 or damage.attacker == damage.victim:
		return

	var by := player_id_for(damage.attacker)

	if by == &"" or not game.players.has(by):
		return

	hit_landed.emit(by, damage.victim, damage.health_lost, damage.point, damage.lethal,
		damage.hit_group == DotHitGroup.HEAD)


## Refuses a hit on somebody inside their spawn window.
##
## Self damage and world damage are not blocked, and neither decision is made here:
## [DotSpawnProtection.blocks] answers about the pair precisely so that a protected
## player who rocket-jumps or falls into a pit still takes it.
func _adjust_damage(damage: DotDamage) -> void:
	if damage == null or game.player_stack == null:
		return

	if game.player_stack.blocks_damage(
		str(damage.attacker), str(damage.victim), damage.tick, damage.is_world_damage()
	):
		damage.refuse("spawn protection")


func _build_match() -> DotResult:
	match_node = DotMatch.new()
	match_node.name = "Match"
	match_node.rules = G2GArsenal.match_rules(score_limit)
	apply_killcam_wait()
	match_node.register_service = false

	var config := DotMatchConfig.new()
	config.tick_rate = game.tick_rate
	config.auto_start = false
	config.balance_between_rounds = false
	match_node.config = config

	add_child(match_node)

	# Where everybody is, so the spawn selector can put a player away from a fight.
	match_node.position_fn = func(key: String) -> Vector3:
		var player := _player_for(key.to_int())
		return player.controller.state.position if player != null else Vector3.ZERO

	match_node.respawn_due.connect(_on_respawn_due)

	return DotResult.success(match_node)


## The final killcam plays inside the match's end, so the end waits that much longer.
func apply_killcam_wait() -> void:
	if match_node != null:
		match_node.rules.match_end_sec = G2GArsenal.match_rules(score_limit).match_end_sec \
			+ maxf(game.config.killcam_seconds, 0.0)


## The top of the board for the winner reveal: `{name, kills, deaths}`, best first.
func podium_rows() -> Array:
	var rows: Array = []
	if match_node == null or match_node.scoreboard == null:
		return rows
	for row: DotPlayerScore in match_node.scoreboard.ranked().slice(0, 3):
		rows.append({"name": row.display_name, "kills": row.kills, "deaths": row.deaths})
	return rows


## The two weapons everybody starts with.
static func _give_default(arsenal: DotWeaponArsenal) -> void:
	arsenal.clear()
	arsenal.give(G2GArsenal.ITEM_KNIFE)
	arsenal.give(G2GArsenal.ITEM_DEAGLE)


## The shared weapon table, built and validated once for the whole process.
static var _shared_catalogue: DotWeaponCatalogue = null


static func catalogue() -> DotWeaponCatalogue:
	if _shared_catalogue == null:
		_shared_catalogue = G2GArsenal.weapon_catalogue()
		var res := _shared_catalogue.validate()
		if not res.ok:
			push_error(res.error.message)
	return _shared_catalogue


## Gives a player the weapons their saved loadout names.
##
## [b]This is the entire dot-loadout seam, and without it the manager was a manager of
## nothing.[/b] dot-loadout has never heard of a weapon and dot-weapon has never heard
## of a `DotItem`; the catalogue's ids and the item ids are the same strings here, and
## this loop is the whole of the join. The manager was built, configured with a
## schema and a store, and asked for nothing until the family's own detector found
## `weapon_table()` occurring once.
##
## Falls back to the default on ANY failure, for the reason above.
func _apply_loadout(player_id: StringName) -> void:
	var kit: Dictionary = _kit.get(player_id, {})

	if kit.is_empty():
		return

	var arsenal: DotWeaponArsenal = kit["arsenal"]
	var res: DotResult = await loadouts.active_for(_loadout_key(player_id))

	if not res.ok:
		DotLog.debug(CHANNEL, "loadout unavailable, using the default", {
			"player": String(player_id), "why": res.error.message
		})
		return

	var entries := loadouts.resolve(res.value)

	if entries.is_empty():
		return

	arsenal.clear()

	var lowest := 0

	for entry in entries:
		var item: DotItem = entry["item"]

		if not arsenal.catalogue.has(item.id):
			continue

		if not arsenal.give(item.id).ok:
			continue

		var slot := arsenal.catalogue.get_def(item.id).slot

		if lowest == 0 or slot > lowest:
			lowest = slot

	if arsenal.slots().is_empty():
		# A loadout that resolved to nothing this game can build. Better a knife than
		# an empty pair of hands.
		_give_default(arsenal)
		lowest = 2

	arsenal.select(maxi(lowest, 1), game.current_tick())


## A storage key that is usable as a filename.
##
## `DotLoadoutKey.is_usable` has a minimum length, so a bare `u7` is refused before any
## store sees it — and the check exists so a malformed key can never reach a filesystem
## path. Padding is right; loosening the check is not.
##
## [b]The userid, never the entity id.[/b] It used to call the function that produced
## both, which was the same number then and would not be now — and a key on disk that
## follows a runtime handle is every saved loadout on the server orphaned the day the
## handle changes. A persistent key is derived from a persistent thing.
static func _loadout_key(player_id: StringName) -> String:
	return "g2g-player-%08d" % userid_of(player_id)


func _build_loadouts() -> void:
	loadouts = DotLoadoutManager.new()
	loadouts.name = "Loadouts"
	loadouts.schema = G2GArsenal.loadout_schema()
	loadouts.register_service = false

	var config := DotLoadoutConfig.new()
	config.backend = "memory"
	config.allow_default_loadout = true
	config.conform_on_load = true
	loadouts.config = config
	loadouts.store = DotLoadoutStoreMemory.new()

	add_child(loadouts)


## Rebuilds the spawn points from the map that just loaded.
##
## [b]A timer map has no deathmatch spawns and does not need any.[/b] The start pads
## are where the map puts people, so they are what a respawn uses — which also means a
## player killed mid-run is put back where a `!r` would put them, and that is the right
## answer on a server where the run is the point.
##
## [b]The old points are freed here and forgotten by `DotMatch.clear_spawn_points()`.[/b]
## This once called a `remove_spawn_point` that did not exist yet: the first map has no
## points to remove, so it only ran on the SECOND map change with the combat layer built —
## a script error that aborted this function before it added the new map's points, leaving
## the deathmatch respawning players at the previous map's pads. Nothing ran a second map
## change on a server with combat until `dedicated`'s unload section did. For a while it
## then cleared the array `spawn_points()` hands back, by reference, which worked only
## because that is the match's own list; dot-match has had `clear_spawn_points` and
## `remove_spawn_point` since 2026-09-25, and the list is now the match's to empty.
func _on_map_ready(_map: DotMapDef) -> void:
	for point in match_node.spawn_points():
		point.queue_free()
	match_node.clear_spawn_points()

	var world := game.current_map_node()

	if world == null:
		return

	# The main track and the first bonus. `DotTimerTrack` numbers bonuses from
	# BONUS_FIRST, and two spawn points is enough for the selector to have a choice —
	# which is all a deathmatch on a course needs, because the course is the map.
	for track in [DotTimerTrack.MAIN, DotTimerTrack.BONUS_FIRST]:
		var at := world.spawn_for(track)
		var point := DotSpawnPoint.new()
		point.name = "Spawn%d" % track
		point.position = at
		point.cooldown_ticks = int(2.0 * float(game.tick_rate))
		add_child(point)
		match_node.add_spawn_point(point)

	if enabled:
		match_node.start(game.current_tick())


# --- Players ---------------------------------------------------------------

func _on_player_added(player: G2GPlayer) -> void:
	_arm(player)


func _on_player_removed(player_id: StringName) -> void:
	_disarm(player_id)


## Gives a player hitboxes, health and an arsenal, and puts them on the scoreboard.
##
## [b]The ghost gets none of it.[/b] It is a replay with a rig: it cannot press a
## trigger, it cannot be hurt in any way that means anything, and registering it would
## put a name on the scoreboard that never dies, never leaves and never scores.
func _arm(player: G2GPlayer) -> void:
	if player == null or player.player_id == G2GGame.GHOST_ID:
		return

	if _kit.has(player.player_id):
		return

	var opened := game.entities.open(
		DotEntity.KIND_PLAYER,
		player,
		&"",
		player.player_id,
		float(game.current_tick()) / float(maxi(game.tick_rate, 1))
	)

	if not opened.ok:
		# Every refusal here is a bug rather than a condition: this player is already
		# armed (guarded above), or their node is already an entity. Arming anyway
		# would register a second health record against a body that has one.
		DotLog.error(CHANNEL, "could not open an entity for a player", {
			"player": String(player.player_id),
			"why": opened.error.message,
		})
		return

	var entity: int = (opened.value as DotEntityHandle).id

	var health := DotHealth.new()
	health.name = "Health"
	health.max_health = 100.0
	health.max_armour = 100.0
	health.regen_per_second = 0.0
	health.set_tick_rate(game.tick_rate)
	player.add_child(health)

	var hitboxes := DotHitboxSet.new()
	hitboxes.name = "Hitboxes"
	hitboxes.bounds_offset = Vector3(0.0, 0.9, 0.0)
	hitboxes.bounds_radius = 1.6
	_add_hitboxes(hitboxes)
	player.add_child(hitboxes)
	hitboxes.refresh()

	var arsenal := DotWeaponArsenal.new()
	arsenal.name = "Arsenal"
	arsenal.tick_rate = game.tick_rate
	arsenal.max_slots = 2
	arsenal.authority = game.authoritative
	arsenal.catalogue = catalogue()
	player.add_child(arsenal)

	var armed := arsenal.setup()
	if not armed.ok:
		push_error(armed.error.message)

	hitboxes.register_with(manager, entity)
	manager.register_health(entity, health)
	manager.set_authoritative_origin(entity, player.eye_position())

	_kit[player.player_id] = {
		"entity": entity,
		"health": health,
		"hitboxes": hitboxes,
		"arsenal": arsenal,
	}

	# The default, immediately, and their saved loadout a frame later.
	#
	# [b]A loadout comes from a store and arming may not wait on one.[/b] The same
	# call game-arena makes about a respawn: the player is in the world with something
	# to shoot, and what they chose arrives when it arrives. An unreachable store is a
	# reason to hand somebody a knife, not a reason to leave them unarmed.
	_give_default(arsenal)
	_apply_loadout(player.player_id)

	match_node.add_player(str(entity), player.display_name, game.current_tick())

	if enabled and match_node.state == DotMatch.State.IDLE:
		match_node.start(game.current_tick())


static func _add_hitboxes(set_node: DotHitboxSet) -> void:
	var head := DotHitbox.new()
	head.name = "Head"
	head.group = DotHitGroup.HEAD
	head.shape = DotHitbox.Shape.SPHERE
	head.radius = 0.15
	head.position = Vector3(0.0, 1.62, 0.0)
	# Higher than the chest's, so the surface the two share resolves to the head every
	# time rather than about half the time.
	head.precedence = 10
	set_node.add_child(head)

	var chest := DotHitbox.new()
	chest.name = "Chest"
	chest.group = DotHitGroup.CHEST
	chest.shape = DotHitbox.Shape.CAPSULE
	chest.radius = 0.30
	chest.height = 1.05
	chest.position = Vector3(0.0, 0.98, 0.0)
	set_node.add_child(chest)

	var legs := DotHitbox.new()
	legs.name = "Legs"
	legs.group = DotHitGroup.LEG
	legs.shape = DotHitbox.Shape.CAPSULE
	legs.radius = 0.24
	legs.height = 0.9
	legs.position = Vector3(0.0, 0.45, 0.0)
	set_node.add_child(legs)


## A player's arsenal, or null when they are not armed. For the admin tools' give and
## strip; [method health_of] and [method entity_for] already answer the rest.
func arsenal_of(player_id: StringName) -> DotWeaponArsenal:
	return (_kit.get(player_id, {}) as Dictionary).get("arsenal") as DotWeaponArsenal


func _disarm(player_id: StringName) -> void:
	if not _kit.has(player_id):
		return

	var kit: Dictionary = _kit[player_id]

	var player: G2GPlayer = game.players.get(player_id)
	if player != null:
		player.held_weapon = &""

	if manager != null and is_instance_valid(manager):
		manager.forget(int(kit["entity"]))

	if match_node != null and is_instance_valid(match_node):
		match_node.remove_player(str(kit["entity"]))

	# After the two forgets, not before: both are keyed on the entity id, and closing
	# first would leave this reading the id out of the kit anyway while the table had
	# already stopped agreeing that it meant anything.
	game.entities.close(int(kit["entity"]), DotEntityTable.REASON_DESPAWN)

	_kit.erase(player_id)


# --- The tick --------------------------------------------------------------

## Simulates every armed player's weapon and resolves what they fired.
##
## [b]After the movement, and the order is the same argument this family makes
## everywhere.[/b] Half a tick of movement at surf speeds is thirty centimetres at 128
## Hz and two metres at the speeds a good player reaches — so a shot resolved before
## the move leaves from somewhere the player is not, and at those speeds that is not a
## rounding error, it is a different part of the map.
func tick(delta: float) -> void:
	if not _started:
		return

	_note_held()

	if not enabled:
		return

	var shots: Array[DotShot] = []

	for id in _kit.keys():
		var player: G2GPlayer = game.players.get(id)
		var kit: Dictionary = _kit[id]
		var health: DotHealth = kit["health"]

		if player == null or not health.alive:
			continue

		var arsenal: DotWeaponArsenal = kit["arsenal"]
		var state := player.controller.state

		health.tick(game.current_tick(), delta)
		manager.set_authoritative_origin(int(kit["entity"]), player.eye_position())

		# [b]`has_meta` first, never `get_meta(key, null)`.[/b] A null default is the
		# engine's "no default", so a missing key is an ERROR with a backtrace rather
		# than a null — once a tick for every armed player who has not sent a command
		# yet, which was 1,146 of them in one `dedicated` run.
		#
		# [b]And consumed, so a tick with no fresh input does not fire.[/b] dot-net
		# skips `_net_apply_input` for a tick whose packet never arrived, so a command
		# left in place is the last trigger replayed until the next packet — which is
		# exactly the held trigger surviving a dropped packet that `G2GPlayerNet`
		# promises it does not. `previous` is left alone on such a tick, so a trigger
		# that really was held across the gap is not read as a fresh press either.
		if not player.has_meta("g2g_fire"):
			continue

		var command: DotWeaponCommand = player.get_meta("g2g_fire")
		player.remove_meta("g2g_fire")

		if command == null:
			continue

		command.yaw = state.yaw
		command.pitch = state.pitch

		# Pushed in from the simulated state, never read out of a rendered one: an
		# interpolated position differs between client and server by design, and
		# feeding it to the spread makes the spread differ too.
		var ctx := DotWeaponContext.make(
			int(kit["entity"]),
			game.current_tick(),
			player.eye_position(),
			command.aim_direction()
		)
		ctx.speed = state.horizontal_speed()
		ctx.airborne = not state.is_grounded()
		ctx.crouched = state.is_crouched()
		ctx.authority = game.authoritative

		var previous: DotWeaponCommand = player.get_meta("g2g_fire_previous") \
			if player.has_meta("g2g_fire_previous") else null
		var outcome := arsenal.simulate_tick(command, ctx, previous)
		player.set_meta("g2g_fire_previous", command.duplicate_command())

		shots.append_array(outcome.shots)

		# Heard by the hunters: a gunfight on a course brings them.
		if not outcome.shots.is_empty() and game.hunters != null:
			game.hunters.note_fire(id, player.eye_position())

	if game.authoritative:
		for shot in shots:
			manager.resolve_shot(shot)

	match_node.tick(game.current_tick())


## Writes each armed player's weapon in hand onto [member G2GPlayer.held_weapon], for
## the HUD offline and for `G2GPlayerNet` to send its owner. Empty with deathmatch off: the
## arsenal stays armed under `sv_deathmatch 0`, but nobody can use it, and a counter naming
## a weapon nobody may fire is a lie on the screen. The tick's start, so it is last tick's
## pick: one tick late on a counter is invisible, and it keeps one line out of the loop
## that `continue`s past players with no fresh command.
func _note_held() -> void:
	for id in _kit.keys():
		var player: G2GPlayer = game.players.get(id)
		if player == null:
			continue
		var def := (_kit[id]["arsenal"] as DotWeaponArsenal).current_def() if enabled else null
		player.held_weapon = def.id if def != null else &""


## What a player is trying to do with their weapon this tick.
##
## Set by whatever drives the player — the client's sampler, the bridge's received
## command, or a test. Held as metadata rather than as a field on [G2GPlayer] because
## a player on a server with no deathmatch has no weapon and should carry no state
## about one.
##
## [b]One tick's input.[/b] [method tick] consumes it, so a caller sets it every tick —
## which the bridge does, from `_net_apply_input` — and a tick nobody set it for fires
## nothing.
func set_fire_command(player_id: StringName, command: DotWeaponCommand) -> void:
	var player: G2GPlayer = game.players.get(player_id)

	if player != null:
		player.set_meta("g2g_fire", command)


# --- Events ----------------------------------------------------------------

func _on_entity_killed(entity_id: int, damage: DotDamage) -> void:
	var kit := _kit_for_entity(entity_id)

	if kit.is_empty():
		# Not a player. Something else registered with the combat manager — a hunter,
		# a breakable — and the scoreboard must not get a row keyed on it.
		return

	(kit["health"] as DotHealth).alive = false
	(kit["hitboxes"] as DotHitboxSet).enabled = false
	(kit["arsenal"] as DotWeaponArsenal).disabled = true

	# An attacker of 0 is world damage, and dot-match reads an empty killer key as
	# exactly that. Passing "0" would create a scoreboard record for a player who does
	# not exist.
	var killer := "" if damage.attacker == 0 else str(damage.attacker)

	var entry := match_node.report_kill(
		killer,
		str(entity_id),
		damage.weapon_id if damage.weapon_id != &"" else damage.type.id,
		game.current_tick(),
		damage.is_headshot()
	)

	# How the body falls, picked once, here, and carried on DEATH to every client.
	var fallen: G2GPlayer = game.players.get(player_id_for(entity_id))
	if game.authoritative and fallen != null:
		fallen.death = decide_death(fallen, damage)

	if game.progress != null:
		var victim := player_id_for(entity_id)

		if victim != &"":
			game.progress.record(victim, G2GStats.DEATHS)

		if damage.attacker != 0 and damage.attacker != entity_id:
			var shooter := player_id_for(damage.attacker)

			if shooter != &"":
				game.progress.record(shooter, G2GStats.KILLS)

	player_killed.emit(entry)


func _on_respawn_due(key: String, spawn: DotSpawnPoint, tick: int) -> void:
	var kit := _kit_for_entity(key.to_int())

	if kit.is_empty():
		return

	var player_id := player_id_for(key.to_int())
	var player: G2GPlayer = game.players.get(player_id)

	if player == null:
		return

	(kit["hitboxes"] as DotHitboxSet).enabled = true
	(kit["arsenal"] as DotWeaponArsenal).disabled = false

	var health: DotHealth = kit["health"]
	health.spawn_protection_ticks = match_node.spawn_protection_ticks()

	# The class's numbers, before the reset — `reset` sets health to `max_health`, so
	# raising the maximum afterwards leaves a "full" player on the old class's number.
	if game.player_stack != null:
		game.player_stack.apply_class_numbers(
			key, health, player.controller.tunables, player.base_tunables
		)

	health.reset(tick)

	# Through the game's own respawn, not by writing a position: `spawn_player`
	# abandons the run, puts the player on the start pad and resets the timer, and a
	# death that left a run going would be a run with a gap in it.
	if spawn != null:
		# [b]The director among the same starts, and dot-match's point as the
		# fallback.[/b] Both read the map's own track starts — `_on_map_ready` above
		# registers them with dot-match and `G2GPlayerStack.refresh_spawns` copies them
		# into the director — so this is a better choice among one set rather than a
		# second set. It is also the only call that grants the protection window whose
		# ticks were written into `health` four lines up, because
		# `DotSpawnProtection.grant` runs inside `choose` and nowhere else.
		var at := spawn.spawn_transform().origin

		if game.player_stack != null:
			var track := player.timer.track if player.timer != null else DotTimerTrack.MAIN
			var chosen := game.player_stack.choose_start(player_id, track)

			if chosen.ok:
				at = (chosen.value as DotSpawnChoice).transform.origin

		player.teleport(at)
	else:
		game.spawn_player(player_id)

	player_respawned.emit(player_id)


## The fall a death gets: dot-player-char's reaction rule over the server's
## `sv_ragdoll_reactions`, seeded from the victim and the tick, with the killing weapon's def.
## The push goes the way the shot went, or away from the killer when the damage carries no
## direction (a hunter's swipe sets one; see [method G2GHunters.hunter_attack]).
func decide_death(player: G2GPlayer, damage: DotDamage) -> DotPlayerDeath:
	if _weapon_defs.is_empty():
		_weapon_defs = G2GArsenal.weapon_table()
	var direction := damage.direction
	if direction.length_squared() < 0.0001 and damage.attacker != 0 and damage.attacker != damage.victim:
		var attacker: G2GPlayer = game.players.get(player_id_for(damage.attacker))
		if attacker != null and attacker != player:
			direction = player.controller.state.position - attacker.controller.state.position
	direction.y = 0.0
	return DotPlayerDeath.decide(
		game.ragdoll_rules.reactions(), damage.is_headshot(), damage.amount, direction,
		DotPlayerDeath.seed_of(entity_for(player.player_id), game.current_tick()),
		_weapon_defs.get(damage.weapon_id)
	)


# --- Ids -------------------------------------------------------------------

## The account number inside a player id. `u123` becomes 123.
##
## [b]Not an entity id, and the rename is the point.[/b] This function used to be called
## `entity_id_for` and had three callers doing two different jobs: two wanted the
## account number — a loadout's filename and `DotServer.session_by_userid` — and one
## wanted the combat handle. They were the same number, so nothing was wrong, and
## nothing would have told anybody the day they stopped being.
static func userid_of(player_id: StringName) -> int:
	var text := String(player_id)
	return text.substr(1).to_int() if text.begins_with("u") else text.to_int()


## The combat entity id for a player, or 0 when they have no kit.
##
## Two id spaces meet here: this game keys players by [StringName] and dot-combat and
## dot-effects both key by int. A caller that hashed the name instead would produce a
## number that is stable, plausible and not the one the health, the hitboxes and the
## kill feed use — which is why [DotEntityTable] stores the key rather than deriving it.
func entity_for(player_id: StringName) -> int:
	return game.entities.id_for_key(player_id) if game != null else 0


## The other direction, and it is now a lookup rather than a scan.
##
## [b]Not `"u%d" % entity`.[/b] That would be a second spelling of one serialisation.
## It used to walk every kit comparing ints, which was correct and O(n) on a call that
## runs once per kill, once per respawn and once per hunter swipe; the table keeps the
## reverse index that makes it one dictionary read.
func player_id_for(entity_id: int) -> StringName:
	return game.entities.key_for_id(entity_id) if game != null else &""


func _kit_for_entity(entity_id: int) -> Dictionary:
	var id := player_id_for(entity_id)
	return _kit.get(id, {}) if id != &"" else {}


func _player_for(entity_id: int) -> G2GPlayer:
	var id := player_id_for(entity_id)
	return game.players.get(id) if id != &"" else null


func health_of(player_id: StringName) -> DotHealth:
	var kit: Dictionary = _kit.get(player_id, {})
	return kit.get("health") if not kit.is_empty() else null


func describe() -> Dictionary:
	return {
		"enabled": enabled,
		"armed": _kit.size(),
		"match": match_node.describe() if match_node != null else {},
	}


func describe_lines() -> PackedStringArray:
	var out := PackedStringArray()
	out.append("deathmatch   %s  %d armed" % ["on" if enabled else "off", _kit.size()])

	if enabled and match_node != null:
		out.append_array(match_node.describe_lines())

	return out
