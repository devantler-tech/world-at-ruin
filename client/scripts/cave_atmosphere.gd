class_name CaveAtmosphere
## Owns the Reach's downward ash pooling, so the weather stops gathering inside
## sealed rock.
##
## Shaped like [Volumetrics]: the module owns its slice of the [Environment] and
## both consumers hand that slice over to [method apply] rather than writing the
## properties themselves. That is what makes the pooling single-writer — the
## build-time grade is `apply(env, 0.0)`, the per-frame retune is
## `apply(env, blocked)`, and the set of properties that fade is stated by
## enumeration inside one function instead of by a comment somebody has to find.
##
## The Reach's air thickens downward: `Main._build_environment` sets
## `fog_height` with a `fog_height_density`, which is what makes ash gather in
## the hollows instead of hanging at one density everywhere (#211). That term is
## a property of the SKY — ash falls, settles low, and pools where the ground
## dips.
##
## Depth fog cannot see what is above it, so it pooled inside the starter cave
## too: a sealed chamber, far below the height the pooling begins at, filled with
## weather that has no way in. Measured on the committed seed with the torch
## flicker pinned (#321), two runs each and bit-identical:
##
## | environment | value range | darkest pixel | hue span |
## |---|---|---|---|
## | shipped | 12.5% | 0.117 | 6.0 deg |
## | height term removed | **22.7%** | **0.006** | 9.5 deg |
## | all depth fog removed | 22.8% | 0.000 | 15.0 deg |
## | sky ambient removed | 12.5% | 0.117 | 6.0 deg |
##
## Two of those readings are load-bearing. The height term alone accounts for
## the whole flattening — removing ALL depth fog buys a further 0.1pp, inside
## nothing — so the uniform term is not the problem and is left alone. And
## removing sky ambient changes the chamber by NOTHING, which is the negative
## control: SDFGI already keeps the sky out of the cave exactly as
## `Main._build_environment` claims, so the veil was never ambient leakage.
##
## **The test is sky overhead, not depth underground**, and the difference is
## not academic — a depth test was written first and measured as a complete
## no-op. The starter cave is carved inside a massif that STANDS ON the terrain
## rather than being dug beneath it, so at the two cave vantages the heightfield
## reads about 3.6 m BELOW the camera: by any depth-below-terrain measure the
## chamber is open air. `tools/frame_capture` already had the right idea in
## `_under_rock` — cast a ray up and see whether rock stands over you. This
## spreads that into a small cone so the answer is a fraction rather than a
## flip, which is what lets the ash fade in and out across a cave mouth instead
## of popping the moment the lip passes overhead.
##
## This touches neither the cave's palette nor its light. #238 first proposed
## widening the rock palette; that was built, measured and falsified — under a
## single 82%-saturated torch a surface can only reflect the hue the illuminant
## contains, so no albedo can widen the chamber's hue. What was actually too
## narrow was the VALUE axis, and what compressed it was weather indoors.
## `docs/art-direction/README.md` permits a scene to separate "by value, by hue,
## or by neither", so a torch-lit room may stay warm provided its light and its
## shadow separate — which is what clearing the veil restores.

## The height ash begins gathering below, and the density it reaches there.
## Both unchanged from what #211 shipped: under open sky [method apply] writes
## exactly the values that were there before, so the surface pools are untouched
## by any of this.
##
## Only these two fade. The uniform `fog_density`, `fog_aerial_perspective` and
## `fog_sky_affect` stay where `Main._build_environment` sets them, and that
## boundary is measured rather than assumed — with the height term gone the
## chamber reaches 22.7% of the value range, and removing every remaining depth
## fog term buys a further 0.1pp. Whatever is left indoors is not worth the
## complexity of a second fade. A new fog term joins this function only if it is
## a property of the sky.
const SURFACE_HEIGHT_DENSITY := 0.06
const POOL_START_HEIGHT := 6.0

## How far up a probe looks for rock. Matches the reach `frame_capture`'s own
## `_under_rock` uses, so the capture's enclosure guard and the weather agree
## about what "under rock" means rather than drifting apart.
const PROBE_HEIGHT := 60.0

## Horizontal spread of the outer probes, in metres.
##
## This sets how wide the mouth's transition is: the ash begins returning once
## the first probe clears the overhang and is fully back once all of them have.
## Six metres is a little wider than the mouth passage, so the change reads as a
## walk out into weather rather than a line crossed.
const PROBE_SPREAD := 6.0


## The probe pattern, as offsets from the eye — centre plus four spread around
## it. Deterministic and fixed: a randomised or time-varying pattern would make
## every captured cave frame photograph a different sky reading, which is the
## flicker mistake #321 already had to correct once. A `const` array rather than
## a builder so the per-frame path allocates nothing and Godot holds it
## read-only, which is that guarantee in the type rather than in this comment.
const PROBE_OFFSETS: Array[Vector3] = [
	Vector3.ZERO,
	Vector3(PROBE_SPREAD, 0.0, 0.0),
	Vector3(-PROBE_SPREAD, 0.0, 0.0),
	Vector3(0.0, 0.0, PROBE_SPREAD),
	Vector3(0.0, 0.0, -PROBE_SPREAD),
]

## How far each probe reaches, as the vector the query adds to its origin.
const PROBE_RISE := Vector3(0.0, PROBE_HEIGHT, 0.0)


## Writes the ash's downward pooling into `env` for a viewpoint with `blocked` of
## its sky cut off by rock: the shipped surface grade at 0.0, easing to no
## pooling at all under full cover.
##
## The single writer for these properties — `Main` and `TelegraphPreview` both
## build their environment through it, so the shipping grade cannot drift
## between the world and the rigs used to judge it.
static func apply(env: Environment, blocked: float) -> void:
	env.fog_height = POOL_START_HEIGHT
	env.fog_height_density = height_density(blocked)


## The `fog_height_density` alone, for callers that want the policy without the
## write — the tests, and anything reasoning about the grade.
##
## Clamped rather than trusted: a caller handing over a fraction outside 0..1
## would otherwise drive the fog negative, which Godot renders as an
## ever-thickening black rather than as an error anybody would notice.
static func height_density(blocked: float) -> float:
	return SURFACE_HEIGHT_DENSITY * (1.0 - clampf(blocked, 0.0, 1.0))


## How much of the sky above `from` is cut off by rock, from 0.0 (open) to 1.0
## (fully covered), by casting [method probe_offsets] straight up.
##
## Areas are excluded deliberately: the trigger volumes that drive interaction
## and discovery are not roof, and counting them would switch the weather off
## wherever a player stood in one.
##
## Run every frame rather than on a timer or every Nth frame. Five ray queries
## is nothing beside the frame they belong to, and a sampled version would make
## the answer depend on which frame the question was asked on — which is exactly
## the non-determinism `frame_capture` had to pin out of the cave once already
## (#321), since it settles a fixed number of frames before each shot.
##
## **The reading only ever THINS the ash, never thickens it** — the fraction is
## clamped and [method height_density] subtracts — so the worst a
## misread anywhere in the world can do is leave the air slightly clearer than
## before. It can never introduce a veil where there was none. One consequence
## is worth naming: an outer probe standing at the foot of a cliff begins inside
## the hillside and reports rock overhead, so the air very close under a steep
## face thins a little. All four outdoor capture vantages are byte-identical
## across this change, so nothing framed today shows it.
static func sky_blocked_fraction(space: PhysicsDirectSpaceState3D, from: Vector3) -> float:
	# One query object reused across the cone rather than five built per frame.
	# Areas stay excluded on it: the trigger volumes that drive interaction and
	# discovery are not roof.
	var query := PhysicsRayQueryParameters3D.new()
	query.collide_with_areas = false
	var blocked := 0
	for offset: Vector3 in PROBE_OFFSETS:
		query.from = from + offset
		query.to = query.from + PROBE_RISE
		if not space.intersect_ray(query).is_empty():
			blocked += 1
	# Divided by the pattern's own length, never a second constant that would
	# have to be kept in step with it.
	return float(blocked) / float(PROBE_OFFSETS.size())
