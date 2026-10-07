class_name RecipeGeneration
## Shared seeded recipe mechanisms; each generator keeps its own vocabulary
## and draw schedule. These functions consume no hidden random state.

static func forge_name(rng: RandomNumberGenerator, heads: Array, tails: Array) -> String:
	return heads[rng.randi_range(0, heads.size() - 1)] \
		+ tails[rng.randi_range(0, tails.size() - 1)]


static func put_shape(shapes: Dictionary, shape_name: String, value: float) -> void:
	if absf(value) < 0.03:
		return
	shapes[shape_name] = quantize(value)


static func quantize(value: float) -> float:
	return snappedf(value, 0.01)


## Consume exactly one suffix draw per collision, preserving the caller's forge
## schedule. The caller records the accepted name before attempting body build.
static func ensure_unique(forged: String, tails: Array, rng: RandomNumberGenerator,
		taken: PackedStringArray) -> String:
	while forged in taken:
		forged += tails[rng.randi_range(0, tails.size() - 1)]
	return forged
