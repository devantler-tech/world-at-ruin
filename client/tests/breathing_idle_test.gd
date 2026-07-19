extends Node
## Regression test for the wanderer's breathing idle (#243, second slice of
## #224, part of #123).
##
## The idle is motion laid on top of a pose, and motion is easy to test badly:
## a test that samples one instant proves the body moved, not that it moves
## WELL, and a test that checks amplitudes proves the numbers are small, not
## that the stance underneath survived them. Both blind spots have shipped in
## this repo before — #237's own laws asserted `absf(asymmetry)` and were
## therefore blind to an exactly inverted stance.
##
## So the laws here are mostly about the WHOLE LOOP rather than a moment:
##
##  1. THE RIG HAS EVERY BONE THE IDLE DRIVES — a missing bone would make the
##     idle a partial, silent no-op, which is the failure mode hardest to see
##     in a rendered frame.
##  2. BOUNDED — no channel exceeds its declared amplitude anywhere in the loop.
##  3. NOT VACUOUS — and every channel actually MOVES. Law 2 alone is passed
##     perfectly by an idle that returns zero forever, which is exactly the
##     shape a broken idle takes.
##  4. SEAMLESS — each channel returns to itself after its own period, so the
##     loop has no visible jump. Sinusoids make this true by construction; the
##     law exists so a future "more interesting" waveform cannot quietly break
##     it.
##  5. 🔑 THE STANCE SURVIVES EVERY PHASE. The load-bearing law. The idle rocks
##     the pelvis and the stance's entire premise is that the ENGAGED hip rides
##     high — so an over-eager weight shift would invert the stance at some
##     phase of a slow loop, and a single-instant test would very likely sample
##     a phase where it still looked right. Every stance direction law is
##     therefore re-asserted at many phases across the full loop.
##  5b. 🔑 AN INHALE OPENS THE CHEST. Every other law here passes an exactly
##     INVERTED breath — one that folds the body forward and drops its
##     shoulders as it breathes in is still bounded, moving, seamless and
##     stance-preserving. That is what the first draft of this shipped, so the
##     direction is now asserted per side against the two extremes.
##  6. THE IDLE CANNOT MOVE A CHARACTER'S IDENTITY. `CharacterFactory.
##     fingerprint` hashes REST and mesh vertices, and the idle writes POSES —
##     so a fingerprint must be byte-identical before and after an arbitrary
##     amount of breathing. This is what makes the idle safe to attach to every
##     character without touching a golden.
##  7. DETERMINISTIC PHASE — the same recipe breathes identically on every
##     boot, and different people are out of step with each other.
##
## Run: godot --headless --path client res://tests/breathing_idle_test.tscn

const GOLDEN := "res://tests/data/golden_recipe_v1.json"

## How many phases across the loop the stance laws are re-checked at. The two
## channels beat against each other over `SHIFT_PERIOD`, so the sweep covers a
## full slow period rather than a full breath.
const PHASE_SAMPLES := 96

## Minimum peak-to-peak travel, in degrees, before a channel counts as moving.
## Comfortably under every declared amplitude and comfortably over zero.
const MIN_CHANNEL_TRAVEL := 0.2

## Tolerance for a channel returning to itself after exactly one period.
const LOOP_EPSILON := 1e-5

## The stance thresholds, matching rest_stance_test — these are the same laws,
## re-asserted under motion rather than new ones.
const MIN_HIP_TILT := 0.004
const MIN_SHOULDER_TILT := 0.004

## Minimum shoulder lift across one breath, in metres. Set from a measurement
## of the rig rather than by feel — a clavicle moves its shoulder joint about
## 7.8 mm per 3 degrees, and this floor is what stops the amplitude being
## quietly tuned down to something a test can prove and an eye cannot see.
const MIN_SHOULDER_RISE := 0.003

## Minimum front-to-back travel of the head across one breath, in metres.
const MIN_CHEST_TRAVEL := 0.003

var _failed := false


func _ready() -> void:
	var recipe = CharacterFactory.load_recipe(GOLDEN)
	if not (recipe is Dictionary):
		_fail("could not load %s" % GOLDEN)
		return
	var instance := CharacterFactory.build(recipe)
	if instance == null:
		_fail("CharacterFactory.build returned null for the golden recipe")
		return
	add_child(instance)
	var skeleton := CharacterFactory.find_skeleton(instance)
	if skeleton == null:
		_fail("built character has no skeleton")
		return

	if not _check_rig_has_every_driven_bone(skeleton):
		return
	if not _check_bounded_and_moving():
		return
	if not _check_loop_is_seamless():
		return
	if not _check_stance_survives_every_phase(skeleton):
		return
	if not _check_inhale_opens_the_chest(skeleton):
		return
	if not _check_idle_cannot_move_a_fingerprint(instance, skeleton):
		return
	if not _check_phase_is_deterministic_per_recipe(recipe):
		return

	print("TEST PASS — breathing idle: %d bones driven, bounded and moving, seamless loop, stance holds at %d phases, fingerprint pose-invariant" % [
		BreathingIdle.IDLE_AXES.size(), PHASE_SAMPLES])
	get_tree().quit(0)


## 1. Every bone the idle drives exists on the shipped rig.
##
## `apply_at` pushes an error and skips a missing bone rather than crashing, so
## without this law a rename in the kit would degrade the idle silently — half
## the body breathing, no test red, nothing obviously wrong in a still frame.
func _check_rig_has_every_driven_bone(skeleton: Skeleton3D) -> bool:
	var missing := BreathingIdle.missing_bones(skeleton)
	if not missing.is_empty():
		_fail("the rig has no bone(s) %s — the idle would apply only partially, and silently" % ", ".join(missing))
		return false
	return true


## 2 + 3. Bounded, and every channel genuinely moves.
##
## Kept in one pass because they are two halves of the same question: an idle
## that is out of bounds is broken, and an idle that never leaves zero is
## broken in the opposite direction while passing every bound.
func _check_bounded_and_moving() -> bool:
	var limits := {
		"spine_02": BreathingIdle.CHEST_RISE_DEG,
		"spine_03": BreathingIdle.CHEST_RISE_DEG * BreathingIdle.UPPER_CHEST_SHARE,
		"clavicle_l": BreathingIdle.SHOULDER_RISE_DEG,
		"clavicle_r": BreathingIdle.SHOULDER_RISE_DEG,
		"pelvis": BreathingIdle.WEIGHT_SHIFT_DEG,
	}
	var lowest := {}
	var highest := {}
	for i in PHASE_SAMPLES:
		var t := BreathingIdle.SHIFT_PERIOD * float(i) / float(PHASE_SAMPLES)
		var now := BreathingIdle.angles(t)
		for bone_name: String in limits:
			if not now.has(bone_name):
				_fail("angles(%.3f) omits the driven bone %s" % [t, bone_name])
				return false
			var value: float = now[bone_name]
			var limit: float = limits[bone_name]
			# A hair of float slack: a sinusoid touches its amplitude exactly.
			if absf(value) > limit + 1e-6:
				_fail("%s reaches %.4f deg at t=%.3f, over its declared %.4f deg" % [bone_name, value, t, limit])
				return false
			lowest[bone_name] = minf(lowest.get(bone_name, value), value)
			highest[bone_name] = maxf(highest.get(bone_name, value), value)

	for bone_name: String in limits:
		var travel: float = highest[bone_name] - lowest[bone_name]
		if travel < MIN_CHANNEL_TRAVEL:
			_fail("%s travels only %.4f deg across the whole loop — that channel is not breathing, and every bound above passes a motionless idle" % [bone_name, travel])
			return false
	return true


## 4. Each channel returns to itself after exactly one of ITS periods.
##
## Checked per channel rather than on the combined motion: the two periods are
## deliberately incommensurate, so the pair has no short common loop and
## asserting one would be asserting the wrong thing.
func _check_loop_is_seamless() -> bool:
	for i in 16:
		var t := BreathingIdle.BREATH_PERIOD * float(i) / 16.0
		var a := BreathingIdle.angles(t)
		var b := BreathingIdle.angles(t + BreathingIdle.BREATH_PERIOD)
		for bone_name in ["spine_02", "spine_03", "clavicle_l", "clavicle_r"]:
			if absf(float(a[bone_name]) - float(b[bone_name])) > LOOP_EPSILON:
				_fail("breath channel %s differs by %.8f across one BREATH_PERIOD — the loop would visibly jump" % [bone_name, absf(float(a[bone_name]) - float(b[bone_name]))])
				return false
		var c := BreathingIdle.angles(t)
		var d := BreathingIdle.angles(t + BreathingIdle.SHIFT_PERIOD)
		if absf(float(c["pelvis"]) - float(d["pelvis"])) > LOOP_EPSILON:
			_fail("the weight shift differs by %.8f across one SHIFT_PERIOD — the loop would visibly jump" % absf(float(c["pelvis"]) - float(d["pelvis"])))
			return false
	return true


## 5. 🔑 The stance direction laws hold at EVERY phase of the loop.
##
## This is the law the amplitude constants exist to satisfy, and asserting it
## here rather than eyeballing `WEIGHT_SHIFT_DEG < HIP_HIKE_DEG` is deliberate:
## the relationship that actually matters is between the resulting JOINT
## POSITIONS, and rotations conjugated down a bone chain do not compose the way
## the constants suggest they will (the lesson #237 paid for by deriving a neck
## angle arithmetically and being wrong by 2.7 degrees).
func _check_stance_survives_every_phase(skeleton: Skeleton3D) -> bool:
	for i in PHASE_SAMPLES:
		var t := BreathingIdle.SHIFT_PERIOD * float(i) / float(PHASE_SAMPLES)
		BreathingIdle.apply_at(skeleton, t)
		skeleton.force_update_all_bone_transforms()

		var hip_l := _posed(skeleton, "thigh_l")
		var hip_r := _posed(skeleton, "thigh_r")
		var hip_tilt := hip_l.y - hip_r.y
		if hip_tilt <= 0.0:
			_fail("at phase %.3f s the FREE hip rides %.5f m higher than the engaged one — the idle has inverted the stance it is decorating" % [t, -hip_tilt])
			return false
		if hip_tilt < MIN_HIP_TILT:
			_fail("at phase %.3f s the hips are level (%.5f m) — the weight shift has flattened the stance" % [t, hip_tilt])
			return false

		# The free foot must stay outside the engaged one for the whole loop.
		var pelvis_x := _posed(skeleton, "pelvis").x
		var foot_l := _posed(skeleton, "foot_l")
		var foot_r := _posed(skeleton, "foot_r")
		if absf(foot_r.x - pelvis_x) <= absf(foot_l.x - pelvis_x):
			_fail("at phase %.3f s the free foot has crossed to %.5f m from the midline against the engaged foot's %.5f m" % [t, absf(foot_r.x - pelvis_x), absf(foot_l.x - pelvis_x)])
			return false

		# Shoulders must keep OPPOSING the hips — the definition of
		# contrapposto, and the one thing a body-wide sway destroys.
		var sh_l := _posed(skeleton, "clavicle_l")
		var sh_r := _posed(skeleton, "clavicle_r")
		var shoulder_tilt := sh_l.y - sh_r.y
		if absf(shoulder_tilt) < MIN_SHOULDER_TILT:
			_fail("at phase %.3f s the shoulder line is level (%.5f m) — the opposition is gone" % [t, shoulder_tilt])
			return false
		if shoulder_tilt >= 0.0:
			_fail("at phase %.3f s the shoulders tilt WITH the hips (%.5f m) — the body is listing sideways, not standing in contrapposto" % [t, shoulder_tilt])
			return false
	return true


## 5b. 🔑 AN INHALE OPENS THE CHEST — it does not fold the body over it.
##
## Every law above passes an EXACTLY INVERTED breath: a body that collapses
## forward and drops its shoulders as it breathes in is bounded, moving,
## seamless, and leaves the stance intact. It is also plainly wrong, and it is
## what this file shipped in its first draft — the chest channel's sign was
## reasoned from "positive raises" instead of measured, and rotating a spine
## bone about RIGHT moves the head FORWARD, not up.
##
## So the direction is asserted against the two extremes of the breath, and
## named per side, in the same spirit as the stance's own direction laws.
func _check_inhale_opens_the_chest(skeleton: Skeleton3D) -> bool:
	var pose_at := func(t: float) -> Dictionary:
		BreathingIdle.apply_at(skeleton, t)
		skeleton.force_update_all_bone_transforms()
		return {
			"shoulder_l": _posed(skeleton, "upperarm_l"),
			"shoulder_r": _posed(skeleton, "upperarm_r"),
			"head": _posed(skeleton, "head"),
		}
	# sin() troughs at 3/4 of a period and peaks at 1/4.
	var exhaled: Dictionary = pose_at.call(BreathingIdle.BREATH_PERIOD * 0.75)
	var inhaled: Dictionary = pose_at.call(BreathingIdle.BREATH_PERIOD * 0.25)

	for side in ["shoulder_l", "shoulder_r"]:
		var rise: float = (inhaled[side] as Vector3).y - (exhaled[side] as Vector3).y
		if rise <= 0.0:
			_fail("the %s DROPS %.5f m on the inhale — breathing in must lift the shoulders, not sink them (a mirrored clavicle sign does exactly this)" % [side, -rise])
			return false
		if rise < MIN_SHOULDER_RISE:
			_fail("the %s rises only %.5f m on the inhale — real, provable, and invisible to a player at any normal distance" % [side, rise])
			return false

	# The kit body faces +Z, so the head drifting +Z on an inhale is the chest
	# folding forward over the breath rather than opening.
	var drift: float = (inhaled["head"] as Vector3).z - (exhaled["head"] as Vector3).z
	if drift > 0.0:
		_fail("the head moves %.5f m FORWARD on the inhale — the chest is collapsing into the breath instead of opening" % drift)
		return false
	if absf(drift) < MIN_CHEST_TRAVEL:
		_fail("the chest opens by only %.5f m — the breath channel is not doing visible work" % absf(drift))
		return false
	return true


## 6. The idle writes poses, so it cannot move a character's identity.
##
## Without this, attaching the idle to every character would make each one's
## fingerprint a function of when it was sampled — and the fingerprint is what
## several suites use as a character's identity.
func _check_idle_cannot_move_a_fingerprint(instance: Node3D, skeleton: Skeleton3D) -> bool:
	skeleton.reset_bone_poses()
	skeleton.force_update_all_bone_transforms()
	var before := CharacterFactory.fingerprint(instance)
	# An arbitrary, deliberately un-round amount of breathing.
	for t in [0.37, 1.9, 4.25, 7.0, 10.6]:
		BreathingIdle.apply_at(skeleton, float(t))
		skeleton.force_update_all_bone_transforms()
	var after := CharacterFactory.fingerprint(instance)
	if before != after:
		_fail("breathing changed the character fingerprint:\n  before %s\n  after  %s\nthe idle must write POSES only — a rest-driven idle would move every character's identity every frame" % [before, after])
		return false
	return true


## 7. The phase is a stable function of the recipe.
func _check_phase_is_deterministic_per_recipe(recipe: Dictionary) -> bool:
	var a := CharacterFactory._idle_phase_for(recipe)
	var b := CharacterFactory._idle_phase_for(recipe.duplicate(true))
	if not is_equal_approx(a, b):
		_fail("the same recipe produced phases %.6f and %.6f — the same character must breathe identically on every boot" % [a, b])
		return false
	if a < 0.0 or a >= BreathingIdle.BREATH_PERIOD:
		_fail("phase %.6f is outside [0, BREATH_PERIOD)" % a)
		return false

	# Different people must not inhale in unison.
	var other := recipe.duplicate(true)
	other["skin"] = "%s-variant" % String(recipe.get("skin", "x"))
	if is_equal_approx(CharacterFactory._idle_phase_for(other), a):
		_fail("two different recipes share phase %.6f — a crowd would breathe in lockstep" % a)
		return false
	return true


## Global POSE origin of a named bone — pose, not rest, because the idle lives
## entirely in pose space and reading rest here would report the still stance
## and pass no matter what the idle did.
func _posed(skeleton: Skeleton3D, bone_name: String) -> Vector3:
	return skeleton.get_bone_global_pose(skeleton.find_bone(bone_name)).origin


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
