# The Reach gets high ground (#327)

Frame evidence for raising `cinderreach`'s landform.

| frame | build |
|---|---|
| `cinderreach-before.png` | `cinderreach` at `amp` 0.55 |
| `cinderreach-after.png` | `cinderreach` at `amp` 1.15 |

Both taken through the **committed `cinderreach` vantage** in
`client/tools/frame_capture.gd`, so CI reproduces this framing on every run and a later regression
here cannot be hidden by choosing a different angle. Same seed and lighting; `frame_diff` measures
**33.61% of pixels changed, mean |dRGB| 0.0250**.

## The reference this was judged against

**The Composition target in [`docs/art-direction/README.md`](../../art-direction/README.md)** —
*"Something is the subject. Landmarks, focal lighting and silhouette give the eye somewhere to go."*
That is a first-party written brief, and it is the whole of what this change was judged against.

🔴 **No third-party reference was used, and none is cited.** The art-direction page names supporting
analogues for this world, but its citation contract is explicit that a title alone is *no reference
at all*, and equally explicit that **no agent here has viewed that media, so inventing a URL or a
timestamp would be fabricating evidence to satisfy a rule about evidence**. Naming a game I have not
looked at would be exactly that. The first-party brief is a target I can actually hold the frames
against, so it is the one claimed.

## What the pair shows

**Before** is a broad, near-uniform plain. The horizon is a flat band, the ruin on it barely
separates from the ground it stands on, and nothing in the frame asks to be walked toward.

**After** has a foreground crest carrying that ruin, a taller ridge behind it, and further swells
receding into the haze — depth, a silhouette, and somewhere to go.

## The remaining gap

Stated because the quality bar requires it, and because it is real.

**The ground's material response is arithmetic and stays that way** — that is settled design, not a
defect: `AGENTS.md` fixes the ground, cave rock and masonry as *arithmetic-only, colour computed
from noise*, and `terrain.gdshader` already perturbs `NORMAL` and varies `ROUGHNESS`. The gap is in
the **character and scale** of that response, which is where the art-direction page also puts it
("fix the magnitude and character, not the absence"):

- **It has no mid-scale.** The procedural break-up is tuned for the near field, and it is visible
  there in both frames. A whole hillside at thirty to sixty metres has nothing between that grain
  and the landform itself, so the new slopes read as large smooth masses exactly where this change
  put the eye. Raising the landform added surface area at the scale the response is thinnest.
- **The haze compounds it.** Value separation is largely gone by mid-distance (see `GroundRegions`
  for the measured ceiling), so the far ridge flattens toward a single tone and the layering reads
  much more weakly at the back of the frame than at the front.

Neither is closed by this change, and neither is closed by adding texture maps.

## What this evidence does NOT show

The frames are stills, so they evidence **silhouette and composition only**. They say nothing about
how the steeper ground *feels* to cross, and no such claim is made here or in the dev log — what is
claimed about traversal is the measured angle (43.38° worst collision face inside `cinderreach`,
against a 45° floor limit), not an experiential judgement. Judging the climb itself would need a
traversal clip against a moving reference, which this change does not supply.

## Why these are committed rather than left as a CI artifact

An artifact expires and is not reviewable from the PR after the fact. The precedent is
[`docs/evidence/issue-346-light-response/`](../issue-346-light-response/).
