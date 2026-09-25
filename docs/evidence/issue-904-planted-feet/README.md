# Planted feet (#904)

Evidence that the walk and the run now hold the ground. Each leg is solved so
that a foot that is down stays where it landed while the body passes over it,
instead of swinging from the hip at a fixed angle. Part of #890.

## What changed on screen

![The walk at eight evenly spaced phases](walk-phases.png)

![The run at eight evenly spaced phases](run-phases.png)

Eight evenly spaced phases of one cycle, from `WAR_SCENARIO=walk` and
`WAR_SCENARIO=run`, cropped to the body. Frame `k` is `k/8` of the cycle. The
left foot lifts at the quarter point and the right foot at the three-quarter
point, each after being down for the stretch just before, and both gaits spend
the time between in the air. At 6 and 10.5 m/s with these strides, a leg reaches far enough to stay down
for only about a quarter (walk) and a fifth (run) of each cycle, so a flight
phase is what a planted gait at these speeds looks like. It is not a defect to
tune away.

## Measured through the real controller (2026-09-25)

`WAR_SCENARIO=gait_drive` (see [#516's evidence](../issue-516-gait-drive/README.md)
for how the drive works), with the contact line from #903. Host: Apple M2 Pro,
Metal 4.0 Forward+, Godot 4.7.1, `client/recipes/wanderer.json`.

| Gait | Cadence | A foot is down | A down foot moves at | Foot nearest the ground moves at |
|---|---|---|---|---|
| walk, before | 300 steps/min | 31% of the stretch | **127%** of body speed | 109% of body speed |
| walk, planted | 300 steps/min | 52% of the stretch | **6%** of body speed | 36% of body speed |
| run, before | 350 steps/min | 17% of the stretch | **140%** of body speed | 111% of body speed |
| run, planted | 350 steps/min | 26% of the stretch | **5%** of body speed | 42% of body speed |

"Down" means no more than 1 cm above the foot's standing height. The "down foot
moves at" column is the one to judge a planted foot by. Before, a down foot moved faster
than the body: it skated. Now it moves at a twentieth of the body's speed. The
nearest-foot figure stays well above zero only because it also charges each
flight, when the nearest foot is the one swinging forward.

Cadence and speed are unchanged, because stride length and speed are
unchanged. The trace fingerprint changes, because the feet move differently,
to `3ba727c9470cce3e4391b08f063f20684a4f38737c89a65eff14f28320673c55`.

The run's down share is below its geometric bound of about 38% because the
drive crosses real terrain. The feet plant on the body's own flat ground plane,
so on a slope a planted foot sits a few centimetres above or below the ground
under it. On a downhill stretch it counts as lifted. Adapting the plant to the
terrain is a separate slice.

## What the tests pin

`client/tests/planted_feet_test.gd` holds the solve to its promises on the
shipped rig, to the millimetre:

- a planted ankle stays at its standing height and moves back under the hip
  exactly as far as the body travels;
- no phase of either gait moves a foot sideways;
- a foot leaves and meets the ground standing still over it;
- the running knee never straightens;
- the gaits lower the pelvis, and standing still and jumping restore it;
- a rig without the bones the solve needs keeps its jump.

`client/tests/walk_locomotion_test.gd` still holds both gaits to their earlier
laws: default-off, distance-driven, deterministic, and blending across a sprint
press without a jump in any bone.

## Ablations — deliberate wrong builds the tests must refuse

| Wrong build | What fails |
|---|---|
| The swing travels straight between the ends of contact | a foot skids at the ends of its swing: it moves at 0 instead of the stance's speed |
| Each foot's cycle is not offset to lift the left foot at a quarter phase | the feet do not lift at a quarter and three quarters of the cycle |
| The thigh turns about its own bone axis, as the swung gait did | the walk moves a foot 13.2 cm sideways, and a planted ankle sits 5.7 cm off its standing height |
| The run's reach limit raised to 0.999 | the run straightens its knee to 5.1° of flexion |
| A foot trailing past the leg's reach is not lifted instead | the run straightens its knee to 1.8° of flexion |
| The jump keeps the gaits' lowered pelvis | the jump is posed from a lowered pelvis |
| A rig that cannot plant keeps its gaits enabled | a rig that cannot plant a foot kept a grounded gait enabled |
| The foot lifts as `sqrt(sin)`, infinitely fast at lift-off | the sprint press steps a bone 7.2° in one millisecond |

The last two rows were real defects in earlier drafts of this change, and the
tests found both.
