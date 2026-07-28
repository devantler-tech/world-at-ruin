# The Reach gets high ground (#327)

Frame evidence for raising `cinderreach`'s landform, judged against the **Composition** target in
[`docs/art-direction/README.md`](../../art-direction/README.md): *"Something is the subject.
Landmarks, focal lighting and silhouette give the eye somewhere to go."* Supporting analogue named
there for this world: WoW's **Outland / Hellfire Peninsula**.

| frame | build |
|---|---|
| `cinderreach-approach-before.png` | `cinderreach` at `amp` 0.55 |
| `cinderreach-approach-after.png` | `cinderreach` at `amp` 1.15 |

Same camera, same seed, same lighting, captured through the shipped
`client/tools/frame_capture.tscn` rig with a seeded save. Measured with `frame_diff`: **32.33% of
pixels changed, mean |dRGB| 0.0296**.

## What the pair shows

**Before** is a broad, near-uniform plain. The horizon is a flat band, the ruin on it barely
separates from the ground it stands on, and nothing in the frame asks to be walked toward.

**After** has a foreground crest carrying that ruin, a taller ridge behind it, and further swells
receding into the haze — depth, a silhouette, and somewhere to go.

## The remaining gap

Stated because the quality bar requires it, and because it is real:

- **The material is unchanged and still below the bar.** The ground is arithmetic-only — no normal,
  roughness or AO maps anywhere (#223) — so the new slopes read as smooth painted dunes rather than
  as ash and stone with surface under the low sun. This change bought **silhouette**, which is the
  axis it set out to move; it bought no material fidelity at all, and the frames show that plainly
  in the near field.
- **The haze still flattens the far ridge.** The atmosphere eats most of the separation past
  mid-distance (see `GroundRegions` for the measured ceiling), so the layering reads much more
  weakly at the back of the frame than at the front.
- **No committed vantage stands on or frames `cinderreach`.** The shipped capture set was fixed
  before the ground had regions, and the strongest of those views moves only 5.38% of pixels on this
  change. These frames were taken with an ad-hoc camera; the region's own read is therefore not yet
  covered by the standing evidence set — the same missing-vantage class as #495.

## Why these are committed rather than left as a CI artifact

An artifact expires and is not reviewable from the PR after the fact. The precedent is
[`docs/evidence/issue-346-light-response/`](../issue-346-light-response/).
