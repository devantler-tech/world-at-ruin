class_name CreatureGen
## Deterministic, name-keyed creature recipe generator (creature system pilot,
## issue #24): the seed IS the name, so "Ashfang" is the same hound on every
## machine, every boot, forever — no wall-clock, no unseeded randomness
## (determinism law). The creature parallel to NpcGen.
##
## Every emitted recipe is a plain CreatureFactory v1 recipe that passes
## validation: only shipped morph/bone/tint names, values inside proven-safe
## ranges, quantized to 0.01 so recipes are stable under float printing and
## cache-friendly.
##
## GENERATOR_VERSION participates in the seed: bumping it deliberately re-rolls
## every generated creature (they are scenery, not player state — the no-resets
## law protects the SAVED recipe format, which this emits).

const GENERATOR_VERSION := 1

const TINTS := ["ash", "dust", "char", "bone"]

## Name forge syllables — feral, guttural, no lore claims.
const NAME_HEADS := [
	"Ash", "Grim", "Vor", "Snar", "Kur", "Dre", "Fen", "Rax",
	"Mor", "Gna", "Thul", "Ska", "Bry", "Ozk", "Hru", "Vex",
]
const NAME_TAILS := [
	"fang", "maw", "claw", "hide", "growl", "snout", "husk", "gore",
	"rend", "shard", "bane", "ash", "rot", "gnash", "fell", "mane",
]


static func forge_name(rng: RandomNumberGenerator) -> String:
	return NAME_HEADS[rng.randi_range(0, NAME_HEADS.size() - 1)] \
		+ NAME_TAILS[rng.randi_range(0, NAME_TAILS.size() - 1)]


## The whole hound, from a name: build, proportions, snout/ears/tail, tint.
static func recipe_for(creature_name: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(creature_name) ^ (GENERATOR_VERSION * 2654435761)

	var shapes := {}
	var recipe := { "version": 1, "shapes": shapes }

	# Build: heavy / gaunt / neither — never both (they oppose).
	var build := rng.randf()
	if build < 0.4:
		_put(shapes, "body_heavy", rng.randf_range(0.3, 0.9))
	elif build < 0.75:
		_put(shapes, "body_gaunt", rng.randf_range(0.3, 0.85))

	if rng.randf() < 0.5:
		_put(shapes, "legs_long", rng.randf_range(0.25, 0.85))
	if rng.randf() < 0.5:
		_put(shapes, "snout_long", rng.randf_range(0.3, 1.0))
	if rng.randf() < 0.6:
		_put(shapes, "ears_alert", rng.randf_range(0.3, 1.0))
	if rng.randf() < 0.5:
		_put(shapes, "tail_high", rng.randf_range(0.3, 1.0))

	# Size and feature scale: whole-animal size is the strongest variety lever.
	var bone_scale := { "root": _q(rng.randf_range(0.82, 1.18)) }
	if rng.randf() < 0.5:
		bone_scale["head"] = _q(rng.randf_range(0.9, 1.15))
	if rng.randf() < 0.4:
		bone_scale["tail_01"] = _q(rng.randf_range(0.85, 1.3))
	recipe["bone_scale"] = bone_scale

	recipe["tint"] = TINTS[rng.randi_range(0, TINTS.size() - 1)]
	return recipe


## Quantized store: near-zero weights are omitted (creator convention), the
## rest rounded to 0.01.
static func _put(shapes: Dictionary, shape_name: String, value: float) -> void:
	if absf(value) < 0.03:
		return
	shapes[shape_name] = _q(value)


static func _q(value: float) -> float:
	return snappedf(value, 0.01)
