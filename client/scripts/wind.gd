class_name Wind
## The one wind crossing Ashfall Reach, as GDScript can see it.
##
## The wind was born in [code]shaders/foliage.gdshader[/code], where it moves
## the scrub, and its facts lived only there — as uniform defaults no GDScript
## could read. That was fine while vegetation was the only thing that moved.
## The moment a second system had to blow on the SAME wind (#233's drifting ash),
## the choice was to copy the numbers or to name them once. Copied constants
## drift silently: nothing would have failed if the shader's direction changed
## and the ash kept blowing the old way — the world would just have quietly
## stopped agreeing with itself.
##
## So this class is the GDScript-side statement of those facts, and
## [code]tests/wind_parity_test.gd[/code] pins it to the shader's own source
## text. Neither side is free to move alone.
##
## PURE and RNG-FREE: every value here is a constant and every function is a
## closed-form expression of position and time. It draws from no random stream,
## so it cannot perturb the draw order the worldgen and foliage goldens pin
## (the #109 oracle lesson).

## The wind's direction in WORLD space, shared by everything it moves.
##
## Not normalised — this is the authored value, matching the shader's
## [code]uniform vec3 wind_dir[/code] literally so the parity test can compare
## source text. Use [method axis] for the unit vector.
const DIR := Vector3(1.0, 0.0, 0.35)

## Metres per radian of gust phase for the scrub — how long a gust is as it
## crosses the Reach. Leaf-scale: this is the wavelength that makes a clump of
## grass and its neighbour move together while the far side of the field is
## doing something else.
##
## Heavier things ride the same wind on their OWN wavelength (see
## [constant HollowFog.DRIFT_WAVELENGTH]); what makes it one wind is the shared
## [constant DIR] and the shared gust shape, not one number for every scale.
const WAVELENGTH := 9.0

## The gust curve, as bias + swing. Biased so the scrub's sway is always
## DOWNWIND: a gust varies how hard it leans, never which way. A symmetric
## oscillation would have the field spending half its time bending into the
## wind.
##
## The bias is what makes this curve directional, so it belongs to things that
## are PUSHED. A quantity that merely thickens and thins around a resting value
## (ash density) wants a symmetric swing about 1.0 instead — see
## [method HollowFog.drift_density]. Both are still this wind, read through the
## same phase.
const GUST_BIAS := 0.62
## Half-amplitude of the gust curve. GUST_BIAS - GUST_SWING must stay >= 0 or a
## gust would invert the thing it blows on.
const GUST_SWING := 0.38


## The wind's direction as a unit vector.
static func axis() -> Vector3:
	return DIR.normalized()


## Gust phase at [param world_pos], in radians.
##
## Phase comes from POSITION ALONG THE WIND, so a gust travels across the Reach
## and neighbours move together. Deriving it per-object instead makes everything
## independent: at any instant half the world leans one way and half the other,
## which reads as twitching rather than as weather.
##
## [param wavelength] is metres per radian (the scale of the thing being moved)
## and [param speed] is radians per second. Note the MINUS on the time term:
## with a plus, points of constant phase travel against [constant DIR] and the
## gusts visibly roll upwind.
static func phase(world_pos: Vector3, wavelength: float, speed: float, time: float) -> float:
	return world_pos.dot(axis()) / maxf(wavelength, 0.001) - time * speed


## The gust curve at [param at_phase], in [GUST_BIAS - GUST_SWING,
## GUST_BIAS + GUST_SWING]. Always non-negative, so it scales without inverting.
static func gust(at_phase: float) -> float:
	return GUST_BIAS + GUST_SWING * sin(at_phase)
