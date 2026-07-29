# ADR 0001: Generate exposed-stone thickness as batched geometry

- Status: Accepted
- Date: 2026-07-29
- Decision issue: [#543](https://github.com/devantler-tech/world-at-ruin/issues/543)
- Parent: [#272](https://github.com/devantler-tech/world-at-ruin/issues/272)

## Context

The opt-in ground-plate treatment gives the terrain cracks, substance changes,
and fragment-normal relief, but its slab lips are still brighter pixels on the
original terrain surface. At a close or grazing view there is no raised
silhouette, side face, occlusion, or walked top surface.

The current implementation has four constraints:

| Constraint | Current value | Consequence |
|---|---:|---|
| Terrain size | 220 m | Plate work must stay bounded across the whole generated world. |
| Terrain grid | 128 × 128 quads | The base mesh has 129² = 16,641 vertices and 32,768 triangles. |
| Terrain vertex spacing | 220 / 128 = 1.71875 m | A plate-scale lip often falls between terrain vertices. |
| Nominal plate width | 1 / 0.85 = 1.17647 m | One plate is about 0.68 terrain-grid intervals wide. |

The fragment shader currently performs one nine-cell cellular search per
fragment. The first implementation performed four searches and was killed by
the macOS GPU watchdog before it emitted `BOOT_OK`; the current closed-form
gradient exists to avoid repeating that cost.

The committed plate crawl was also run on Apple M2 Pro at 1280 × 720, Forward+,
VSync disabled, with volumetrics enabled:

| State | Flicker contribution | Peak frame delta | GPU profile |
|---|---:|---:|---|
| Plates off | 0.0000 | 0.0372 | unavailable |
| Plates on | 0.0031 | 0.1654 | unavailable |

Godot's command-line GPU profiler reported `GPU PROFILE (total 0.0ms)` for both
states on this Metal run. Zero is not a timing result. The geometry prototype
therefore has to read measured viewport GPU time directly and compare both
states in one run.

## Decision

Exposed-stone thickness will be generated as deterministic, batched overlay
geometry.

1. A pure CPU-side slab field will reproduce the shader's seeded plate
   identity, boundary, exposure, and substance decisions.
2. Exposed cells will contribute real top polygons and closed lip faces. Their
   vertices will sample the existing generated ground rather than replacing the
   world heightfield.
3. The polygons will be combined into one or a small fixed number of static
   `ArrayMesh` surfaces. There will be no node, material, or draw call per slab.
4. The existing `WAR_GROUND_PLATES` flag will gate the work and remain
   default-off. No second player-facing feature flag is introduced.
5. The visible raised top will not be eligible for activation until collision
   and shared surface queries agree with it.

This is an overlay boundary, not a second terrain:

- With `WAR_GROUND_PLATES=0`, mesh, collision, surface queries, world goldens,
  caves, and foliage stay unchanged.
- With the flag on, the existing terrain remains the continuous base. Generated
  stone contributes only the exposed top and lip faces selected by the slab
  field.
- The server, persistence formats, progression, and authoritative world seed
  are outside this change.
- No binary art asset is added. The player-visible implementation must still
  supply a reference, an explicit target gap, captured frames, and a devlog
  entry.

## Why the other approaches do not fit

### Fragment parallax or relief

A spatial shader can move the vertices it receives or replace depth for pixels
the original primitive already covers. It does not add the missing edge
topology, so a grazing camera still cannot see an honest side face or a new
silhouette. Ray-marched parallax would also multiply work around a cellular
field whose four-evaluation version already hit the GPU watchdog.

This option remains useful for fine cracks within a slab, not for the slab's
macro thickness.

### Displace the existing terrain heightfield

Vertex displacement only moves the existing 129 × 129 samples. The 1.71875 m
spacing is larger than the nominal 1.17647 m plate, so it cannot reliably place
both sides of a plate lip.

Giving each nominal plate only two to three grid intervals would require:

| Intervals per plate | Terrain quads | Vertices | Triangles | Triangle multiplier |
|---:|---:|---:|---:|---:|
| 2 | 374² | 140,625 | 279,752 | 8.54× |
| 3 | 561² | 315,844 | 629,442 | 19.21× |

That multiplier would apply to the entire render and collision heightfield,
including places with no exposed stone. It would also change the base surface
used by caves, foliage, walkability, and world goldens. Local overlay geometry
spends vertices only where the feature exists and keeps that blast radius
behind the existing flag.

## Delivery and dependency boundaries

The implementation is split into independently reviewable children of #272:

1. [#546](https://github.com/devantler-tech/world-at-ruin/issues/546) defines
   the deterministic slab field and shader-parity fixtures.
2. [#547](https://github.com/devantler-tech/world-at-ruin/issues/547) builds the
   batched top and lip geometry behind `WAR_GROUND_PLATES`.
3. [#548](https://github.com/devantler-tech/world-at-ruin/issues/548) aligns
   collision and surface queries before activation.
4. [#549](https://github.com/devantler-tech/world-at-ruin/issues/549) gathers
   deterministic rubble and grit at selected broken edges.
5. [#550](https://github.com/devantler-tech/world-at-ruin/issues/550) lets the
   existing named ground regions decide exposure profiles.

The dependency relations are recorded on the issues. #549 and #550 can proceed
independently after the field/mesh boundary they consume.

The current fragment-path defects [#306](https://github.com/devantler-tech/world-at-ruin/issues/306)
and [#499](https://github.com/devantler-tech/world-at-ruin/issues/499) remain
default-on blockers unless the overlay demonstrably removes their affected
medium-distance path and the issues are closed with replacement evidence.

## Prototype acceptance budget

The mesh child is viable only if one same-process measurement at 1280 × 720,
Forward+, VSync disabled, and volumetrics enabled proves all of the following
after warm-up:

- at least 600 steady-state frames in each state;
- plates-on p95 GPU frame time below 16.67 ms;
- plates-on p95 GPU time no more than 1.0 ms above plates-off;
- candidate slabs, visible slabs, vertices, triangles, mesh surfaces, and draw
  calls reported explicitly;
- an unavailable or zero-valued GPU timer reported as unavailable, never
  interpreted as a passing measurement.

The visual and physical gates are equally binding: honest close-range
silhouette and occlusion, no detached or fighting faces, no foot sinking or
hovering, deterministic fresh-boot convergence, and an unchanged plates-off
world.

## Consequences

The decision adds a CPU/GPU parity contract and a small static-geometry build
cost. In return, thickness becomes real topology, the expensive work is bounded
to exposed stone, and the base terrain remains stable while the feature is
default-off.

Activation is intentionally later than rendering. A visually successful
prototype can stay opt-in while collision, medium-distance filtering, and
regional composition are completed; it cannot silently become the shipped
surface before those gates pass.
