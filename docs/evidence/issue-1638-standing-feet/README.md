# Issue #1638 — the standing pose rests both feet on the terrain

Before this change, a wanderer standing still on uneven ground kept each foot at
the height of the body's own flat ground plane, so one foot sank into the ground
and the other hovered over it. The planted gaits (#909) already stood their
feet on the terrain; the standing pose did not.

Now, with either gait preview opted in (`WAR_WALK_CYCLE=1` or `WAR_RUN_CYCLE=1`),
the standing pose samples the ground under each ankle with the same sampler the
gaits use, raises or lowers each ankle by how far that ground stands off the
body's plane, and lowers the pelvis by the deeper foot's offset so that leg
still reaches. On flat ground, where no ground is sampled (a cave, the terrain's
edge) or where the body is not standing on the sampled ground, the pose is the
rest pose bit for bit. Walking off and stopping ease the terrain offsets over the
gaits' 0.15 s instead of jumping. With neither preview opted in nothing changes:
the standing pose ships today.

## Measured through the real controller (2026-11-10)

`WAR_SCENARIO=gait_drive` with both gait opt-ins (see
[#516's evidence](../issue-516-gait-drive/README.md)). Host: Apple Silicon Mac
mini, Metal Forward+, Godot 4.7.1, `client/recipes/wanderer.json`. "Before" is
`main` at `6349106` on the same host and run setup.

| | Left ankle over the terrain at rest | Right ankle | Lowest walk / run foot reading | A down foot moves at (walk / run) |
|---|---|---|---|---|
| before | 9.09 cm | 6.98 cm | −1.1 cm / −1.1 cm | 7% / 5% of body speed |
| after | 7.98 cm | 7.75 cm | −0.0 cm / −0.0 cm | 5% / 5% of body speed |

Both ankles stand 8.0 cm over flat ground. The drive measures every lift against
the standing pose at the spawn point, so the −1.1 cm baseline #909 recorded is
gone. The 2.5 mm left on the right ankle is well inside the 1 cm bound; the drive
reads the smooth terrain height, while the feet are planted on the walkable
height the body is kept on. `planted_feet_test` measures the standing plant on an
exact 15° plane, along and across it and with the body turned, scaled and lifted,
and holds each ankle to within 0.01 mm of its standing height above the ground.
The trace fingerprint changes, because the feet stand differently, to
`6b4f9c731f835df05d1ed6ddd7ec9d092e247bbde27da66efefcb827557b6ae5`.

## Frames

The drive's new standing frame, side-on at ankle height before any input,
halved, and a crop of the feet at full size. The spawn point slopes gently, so
the change is a few centimetres: the near (left) foot comes down onto the sand
and the far (right) foot rises onto it.

| | Before | After |
|---|---|---|
| Standing | ![Side view of the standing wanderer on uneven ground, before the change](standing-before.png) | ![Side view of the standing wanderer on uneven ground, after the change](standing-after.png) |
| Feet | ![Close view of the standing wanderer’s feet on uneven ground, before the change](standing-feet-before.png) | ![Close view of the standing wanderer’s feet on uneven ground, after the change](standing-feet-after.png) |

Reference: the drive's own cue, *Kingmakers* Official Announcement Trailer
1:06–1:10 (full-body stride and camera tracking), as recorded in
[`docs/art-direction/`](../../art-direction/README.md). The cue judged here is a
body that bears its weight on the ground under it; no reference media is
committed or used as input.

**Originality:** first-party code and captures only. The standing plant reuses
World at Ruin's own sagittal two-bone leg solve and its own terrain sampler; no
reference pose, timing or staging was copied.

## Walking off and stopping

The same drive with `WAR_GAIT_DRIVE_TRANSITIONS=1` (a local capture option; CI
keeps its plan) also photographs, side-on at ankle height, the first 24
controller steps of the walk-off from the standing pose (every 3rd step, 0.05 s
apart at 60 steps a second) and 48 steps after the run's input is released
(every 6th step, 0.1 s apart). Before and after are the same run on `main` and
on this change. Cropped to the feet and halved.

At the walk-off the first gait pose still snaps from the standing pose, as on
`main` (pelvis drop and leg angles are unauthored transitions); what changes is
that the terrain offsets ease from the planted stand instead of starting from
the flat plane, so in the first frames the feet already meet the sand. Stopping
from the run, the body slides to rest in the standing pose; after the change
both feet settle onto the sand under them within the 0.15 s ease instead of
returning to the flat plane.

| Moment | Before | After |
|---|---|---|
| walk-off, step 3 | ![Wanderer walking off, step 3, before the change](start_03-before.png) | ![Wanderer walking off, step 3, after the change](start_03-after.png) |
| walk-off, step 9 | ![Wanderer walking off, step 9, before the change](start_09-before.png) | ![Wanderer walking off, step 9, after the change](start_09-after.png) |
| walk-off, step 15 | ![Wanderer walking off, step 15, before the change](start_15-before.png) | ![Wanderer walking off, step 15, after the change](start_15-after.png) |
| walk-off, step 21 | ![Wanderer walking off, step 21, before the change](start_21-before.png) | ![Wanderer walking off, step 21, after the change](start_21-after.png) |
| stop, step 6 after release | ![Wanderer stopping after input release, step 6, before the change](stop_06-before.png) | ![Wanderer stopping after input release, step 6, after the change](stop_06-after.png) |
| stop, step 18 after release | ![Wanderer stopping after input release, step 18, before the change](stop_18-before.png) | ![Wanderer stopping after input release, step 18, after the change](stop_18-after.png) |
| stop, step 30 after release | ![Wanderer stopping after input release, step 30, before the change](stop_30-before.png) | ![Wanderer stopping after input release, step 30, after the change](stop_30-after.png) |
| stop, step 48 after release | ![Wanderer stopping after input release, step 48, before the change](stop_48-before.png) | ![Wanderer stopping after input release, step 48, after the change](stop_48-after.png) |

Motion reference: the drive's cue, *Kingmakers* Official Announcement Trailer 1:06–1:10.

## Remaining gap

- The feet follow the terrain's height, not its tilt: on a slope the sole meets
  the ground at the ankle, not along its whole length.
- Only the heightfield (and raised stone, with its preview) is sampled.
- The gait's own first pose still snaps from the standing pose (pelvis drop and
  leg angles), as it did before; only the terrain offsets ease. Authored starts
  and stops remain unauthored.
