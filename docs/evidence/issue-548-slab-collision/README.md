# Raised exposed stone is solid where drawn (#548)

Evidence for the collision, surface query and step that make the opt-in raised slabs (#547)
walkable. All of it is measured on the shipped seed with `WAR_GROUND_PLATES=1`; with the flag unset
none of it runs.

## What a player sees (2026-09-25)

The real wanderer walking onto the same 0.138 m lip, rendered windowed on an Apple M2 Pro (Metal,
Forward+) from one build, once as shipped and once with the new collision and step switched off —
which is exactly the render-only overlay #547 shipped.

| Frame | What it shows |
|---|---|
| [`lip-before.png`](lip-before.png) | Collision and step off: the body walks on the ash under the slab, and its feet end **12.4 cm inside the stone**. |
| [`lip-after-mid-step.png`](lip-after-mid-step.png) | As shipped, mid-step: the capsule rides 10 cm up over the lip edge. |
| [`lip-after.png`](lip-after.png) | As shipped: the body stands on the stone, 1.3 cm off the top (the physics margin). |

Reference: the Kingmakers announcement trailer, 1:06–1:10, for a full-body stride that keeps its
feet on the ground it crosses. Remaining gap: the step is instant (no knee lift or weight shift), and
a glancing approach up a slope can still slide along a lip (below, #896).

## What `ground_plates_physics_test` holds

- **Collision is the drawn surface.** A ray down onto each of the 3,438 built tops lands on the
  collision at exactly `WorldGen.walkable_height_at()`, and so do rays just past 9,996 top edges
  that open onto ash, where the ray meets the terrain itself. The collision is built from the
  render mesh, so they cannot disagree.
- **The query answers both ways.** Inside a raised top it reads the ground plus that slab's
  thickness; on open ground it reads exactly `surface_height_at()`.
- **The step is load-bearing.** The test first walks the thickest head-on lips with no step and
  takes the first that stops the player (a 0.140 m lip); then, with the world's step, the player
  climbs it, walks back off it with no airborne tick, crosses from a 0.093 m slab onto a 0.135 m
  neighbour, and walks through a point where three slabs meet — arriving on time, resting within
  the surfaces under its footprint, and never below the base ground.
- **Same seed, same stone.** Two fresh builds give identical render-mesh, collision-face and
  surface-query fingerprints.
- **Off is off.** Hiding the overlay removes its collision and the query falls back to the base
  ground; a player given no step keeps the engine's floor snap and `is_grounded()` is exactly
  `is_on_floor()`.

Ablations, each turning the test red: no step (the player snags 1.05 m short of the lip); the gait
told only `is_on_floor()` (9 airborne ticks stepping off the lip); no collision body; a query that
ignores the slabs; a toggle that leaves the collision on. Deepening the floor snap as well was also
tried and removed — the test passes without it, so it was not load-bearing.

## How often a player still stalls: `client/tools/plate_crossing_sweep.gd`

60 lips of at least 10 cm spread over the world, each approached over open ash at 90°, 45° and 25°,
walking and sprinting — 262 walks per setting, headless:

| Step | Stalled | 90° | 45° | 25° |
|---|---|---|---|---|
| none | 110 of 262 (42.0%) | 43/88 | 37/94 | 30/80 |
| the world's 0.24 m | 13 of 262 (5.0%) | 0/88 | 6/94 | 7/80 |

Every head-on approach now steps up. The remaining stalls are all angled (45° and 25°), and the
cases traced were up a grade: the lifted stride lands on the lip edge steeper than the floor limit,
and the body glides along the edge instead. Tracked in #896; foliage that still grows up through
a slab is #895. The treatment stays opt-in.
