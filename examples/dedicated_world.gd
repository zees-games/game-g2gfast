extends RefCounted

const G2GGame := preload("../game/g2g_game.gd")
const G2GProps := preload("../game/g2g_props.gd")

## The hunter and placed-block sections of `dedicated.gd`'s modes test, run against the suite's own game.

var s: DotGameCheckSuite
var game: G2GGame


func _init(suite: DotGameCheckSuite, g: G2GGame) -> void:
	s = suite
	game = g


func run() -> void:
	if game.hunters != null:
		# A timer map is a critical path — start pad, stage lines, end zone — and
		# `DotNpcDirectorFlow` is exactly that as a thing a position can be measured
		# along. So there is no navigation graph and the route is the map's zones.
		s._check(
			game.hunters.flow != null and game.hunters.flow.has_route(),
			"the hunt route was built from the map's own zones"
		)
		s._check(
			game.hunters.flow != null and game.hunters.flow.length() > 1.0,
			"and it has a length",
			"%.1f m" % (game.hunters.flow.length() if game.hunters.flow != null else 0.0)
		)

		var somewhere := game.hunters.patrol_point(0.5)
		s._check(
			somewhere != Vector3.ZERO,
			"and a hunter with nothing to chase has somewhere on it to walk to"
		)

		_senses_hooks()

		s._run_command("sv_hunters 0")
		s._check(not game.hunters.enabled, "sv_hunters 0 turns the hunt off")
		s._check(game.hunters.count() == 0, "and takes the hunters away now")

		s._run_command("sv_hunters 1")
		s._check(game.hunters.enabled, "and back on again")

	if game.props != null:
		var placed := game.props.place(
			&"u1", G2GProps.BLOCK, Vector3(0.0, 2.0, 0.0), true
		)
		s._check(placed != null, "an admin can place a block")
		s._check(game.props.count() == 1, "and it is in the world")

		if placed != null:
			# The catalogue's mass, on the body. dot-props puts it there at spawn
			# rather than leaving it to whatever the scene was saved with.
			var body := placed.body()
			s._check(
				body != null and absf(body.mass - 200.0) < 0.01,
				"with the catalogue's mass rather than the scene's",
				"%.0f kg" % (body.mass if body != null else -1.0)
			)
			# Frozen, which is the opposite default from a sandbox's: a practice
			# block that rolls away is not a practice block.
			s._check(
				body != null and body.freeze,
				"and frozen where it was put"
			)

		# The rule that makes the feature safe to ship: a board with one time set
		# over a placed block is a board nobody trusts.
		s._check(
			game.props.taints_records(),
			"and a run made while anything is placed cannot be ranked"
		)

		s._check(game.props.undo(&"u1"), "undo takes it back")
		s._check(
			not game.props.taints_records(),
			"and records are rankable again once the course is clear"
		)


## The sight hooks a smoke or flash source calls: a blinded hunter, or one behind a cloud, does not see a player in view.
func _senses_hooks() -> void:
	if DotAddonApi.build_level("dot_npc") < 6:
		return

	var hunters = game.hunters
	var origin := Vector3(0.0, 800.0, 0.0)
	var why: Array = []
	hunters.spawner.refused.connect(func(_o, _n, r: String) -> void: why.append(r))
	var npc: DotNpcInstance = hunters.spawner.spawn(&"g2g_stalker", hunters.patrol_point(0.5), &"sight_hooks")
	if npc != null:
		(npc.node as Node3D).global_position = origin
	s._check(npc != null, "a hunter spawns for the sight hooks", str(why))

	if npc == null:
		return

	var senses: DotNpcSenses = hunters.senses
	var cand := DotNpcSenses.Candidate.new(&"u1", origin + npc.facing() * 12.0, &"runner", 0.0)
	senses.now = 100.0
	s._check(senses.perceives(npc, cand), "a hunter sees a player in view")

	s._check(hunters.flash(origin + npc.facing() * 3.0, 20.0, 5.0) == 1, "a flash blinds the hunter in radius")
	s._check(not senses.perceives(npc, cand), "and a blinded hunter does not see that player")
	senses.now = 106.0
	s._check(senses.perceives(npc, cand), "and sees again when the flash wears off")

	var id: int = hunters.block_sight(origin + npc.facing() * 6.0 - Vector3.UP, 2.0, 5.0)
	s._check(id > 0 and not senses.perceives(npc, cand), "a cloud between them stops perception")
	senses.now = 112.0
	s._check(senses.perceives(npc, cand), "and the cloud ends on time")

	hunters.spawner.remove(npc.instance_id, DotNpcSpawner.REASON_ADMIN)
	s._check(hunters.flash(origin, 20.0, 5.0) == 0, "a flash with no hunter in reach blinds none")
