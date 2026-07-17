class_name NpcGen
## Deterministic, name-keyed NPC recipe generator (character system stage 6,
## issue #24): the seed IS the name, so "Maren of the Reach" has the same
## face on every machine, every boot, forever — no wall-clock, no unseeded
## randomness (determinism law).
##
## Every emitted recipe is a plain CharacterFactory v3 recipe that passes
## validation: only shipped shape/bone/slot/piece/skin names, values inside
## the creator's proven-safe ranges, quantized to 0.01 so recipes are stable
## under float printing and cache-friendly.
##
## GENERATOR_VERSION participates in the seed: bumping it deliberately
## re-rolls every generated NPC (they are scenery, not player state — the
## no-resets law protects the SAVED recipe format, which this emits).

const GENERATOR_VERSION := 1

const ARCHETYPE_VILLAGER := "villager"
const ARCHETYPE_DRIFTER := "drifter"

## Name forge syllables — medieval-futuristic, pronounceable, no lore claims.
const NAME_HEADS := [
	"Mar", "Bren", "Tor", "Ash", "Vel", "Ru", "Kel", "Dag",
	"Ise", "Or", "Hal", "Sev", "Yor", "Ena", "Cor", "Wren",
]
const NAME_TAILS := [
	"a", "en", "ric", "wyn", "eth", "ok", "ila", "an",
	"is", "ma", "und", "ei", "os", "ette", "ur", "in",
]

const FEMALE_SKINS := ["skin_female_light", "skin_female_mid"]
const MALE_SKINS := ["skin_male_light", "skin_male_deep"]
const PHENOTYPES := ["phenotype_african", "phenotype_asian", "phenotype_caucasian"]
const FACE_SHAPES := [
	"head_round", "head_square", "head_heavy", "chin_prominent",
	"jaw_wide", "nose_strong", "nose_hump",
]

## First lines the Reach's people give the wanderer. Kept short, atmospheric,
## and true to the settled setting (medieval-futuristic world at rebirth — see
## docs/design/story-and-progression.md); they make no lore claims a later
## quest could not honour. Villagers are the settlement that rebuilds; drifters
## roam the open land. A FIRST bark only — real dialogue trees and the errands
## they carry arrive with Phase 6 (#13).
const VILLAGER_BARKS := [
	"The Ruin took the sky. It didn't take the harvest — help, or move along.",
	"You woke, then. Most who crawl out of that cave don't.",
	"Careful past the stones. The old lights still walk out there at night.",
	"We rebuild. It's all there is left to do.",
	"Bare hands and rags — the Ruin leaves everyone the same, at the start.",
	"Warm yourself at the shrine. The Wardens still keep the flame.",
]
const DRIFTER_BARKS := [
	"Keep moving, ashborn. Nothing that stays out here stays whole.",
	"I've seen the far zones green again. Easy to believe, hard to reach alive.",
	"Salvage's honest work. The old world left plenty worth carrying.",
	"Don't trust anything that hums. Not all the relics went quiet.",
	"The road's long and the Ruin's patient. Walk anyway.",
	"You've the look of someone just out of the dark. It fades, in time.",
]


static func forge_name(rng: RandomNumberGenerator) -> String:
	return NAME_HEADS[rng.randi_range(0, NAME_HEADS.size() - 1)] \
		+ NAME_TAILS[rng.randi_range(0, NAME_TAILS.size() - 1)]


## A short, seeded line for a person — deterministic per name (determinism
## law): Maren gives the same line on every machine, every boot. Seeded off the
## name with a distinct salt so it is independent of the body roll in
## recipe_for (two people with different faces can still share a line).
static func bark_for(npc_name: String, archetype: String) -> String:
	var pool: Array = VILLAGER_BARKS if archetype == ARCHETYPE_VILLAGER else DRIFTER_BARKS
	var idx := absi(hash(npc_name) ^ 0x5BD1E995) % pool.size()
	return pool[idx]


## The whole person, from a name: body, face, age, outfit, skin.
static func recipe_for(npc_name: String, archetype: String) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(npc_name) ^ (GENERATOR_VERSION * 2654435761)

	var shapes := {}
	var recipe := { "version": 3, "shapes": shapes }

	var female := rng.randf() < 0.5
	if female:
		_put(shapes, "body_female", rng.randf_range(0.85, 1.0))
	else:
		_put(shapes, "body_male", rng.randf_range(0.0, 0.35))

	_put(shapes, PHENOTYPES[rng.randi_range(0, PHENOTYPES.size() - 1)], rng.randf_range(0.6, 1.0))

	var aged := rng.randf() < (0.3 if archetype == ARCHETYPE_VILLAGER else 0.15)
	if aged:
		_put(shapes, "body_aged", rng.randf_range(0.5, 0.9))
		_put(shapes, "head_aged", rng.randf_range(0.3, 0.7))

	# Mass: one of heavy / slim / neither — never both.
	var mass := rng.randf()
	if mass < 0.3:
		_put(shapes, "body_heavy", rng.randf_range(0.15, 0.5))
		_put(shapes, "belly", rng.randf_range(0.0, 0.4))
	elif mass < 0.55:
		_put(shapes, "body_slim", rng.randf_range(0.15, 0.4))

	if archetype == ARCHETYPE_DRIFTER:
		_put(shapes, "torso_muscle", rng.randf_range(0.2, 0.6))
		_put(shapes, "arms_muscle", rng.randf_range(0.2, 0.6))
		_put(shapes, "legs_muscle", rng.randf_range(0.1, 0.5))

	# A few face shapes for identity beyond the macro axes.
	var face_pool := FACE_SHAPES.duplicate()
	for _i in 3:
		var face_shape: String = face_pool.pop_at(rng.randi_range(0, face_pool.size() - 1))
		_put(shapes, face_shape, rng.randf_range(0.15, 0.6))

	# Frame: sparse bone ops inside the creator's proven-safe ranges.
	if rng.randf() < 0.6:
		recipe["bone_scale"] = {
			"hand": _q(rng.randf_range(0.96, 1.12)),
			"foot": _q(rng.randf_range(0.96, 1.1)),
		}
	if rng.randf() < 0.5:
		recipe["bone_girth"] = {
			"lowerarm": _q(rng.randf_range(0.95, 1.1)),
			"calf": _q(rng.randf_range(0.95, 1.1)),
		}

	var equipment := {}
	var wear_shirt := archetype == ARCHETYPE_VILLAGER or rng.randf() < 0.85
	if wear_shirt:
		equipment["torso"] = "shirt_ragged"
	equipment["legs"] = "pants_wool"
	var feet := rng.randf()
	if archetype == ARCHETYPE_VILLAGER:
		equipment["feet"] = "boots_worn" if feet < 0.5 else "shoes_cloth"
	elif feet < 0.7:
		equipment["feet"] = "boots_worn"
	elif feet < 0.9:
		equipment["feet"] = "shoes_cloth"
	recipe["equipment"] = equipment

	if aged:
		recipe["skin"] = "skin_female_aged" if female else "skin_male_aged"
	elif female:
		recipe["skin"] = FEMALE_SKINS[rng.randi_range(0, FEMALE_SKINS.size() - 1)]
	else:
		recipe["skin"] = MALE_SKINS[rng.randi_range(0, MALE_SKINS.size() - 1)]

	return recipe


## Quantized store: near-zero weights are omitted (creator convention), the
## rest rounded to 0.01.
static func _put(shapes: Dictionary, shape_name: String, value: float) -> void:
	if absf(value) < 0.03:
		return
	shapes[shape_name] = _q(value)


static func _q(value: float) -> float:
	return snappedf(value, 0.01)
