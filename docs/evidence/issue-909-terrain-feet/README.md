# Issue #909 — planted feet stand on the terrain under them

Before this change a planted foot held its place on the body's own flat ground
plane. Over real terrain that plane is not where the ground is, so on the
controller-driven drive a planted foot sank into rising ground and hung over
falling ground, and on downhill stretches a foot that should be down counted as
lifted.

Now `WalkLocomotion` asks the controller for the ground height under each foot
(the same walkable height the body is kept on) and raises or lowers each foot by
how far that ground stands above or below the body's plane. The pelvis drops by
the deeper foot's offset so the downhill leg still reaches. Where there is no
ground to sample (inside a cave system, off the terrain's edge), or the body is
not standing on the sampled ground (a rock or a ruin), both offsets are zero and
the gait is exactly the flat-plane one. Both gaits stay default-off behind
`WAR_WALK_CYCLE=1` and `WAR_RUN_CYCLE=1`.

## Measured through the real controller (2026-11-04)

`WAR_SCENARIO=gait_drive` with both gait opt-ins (see
[#516's evidence](../issue-516-gait-drive/README.md) for how the drive works).
Host: Apple M2 Pro, Metal Forward+, Godot 4.7.1, `client/recipes/wanderer.json`.
"Before" is `main` at `52baa1b` on the same host, the same run.

| Gait | A foot is down | A down foot moves at | Lowest foot reading | Cadence |
|---|---|---|---|---|
| walk, before | 52% of the stretch | 6% of body speed | −2.8 cm | 300 steps/min |
| walk, after | 58% of the stretch | 7% of body speed | −1.1 cm | 300 steps/min |
| run, before | 19% of the stretch | 5% of body speed | −3.9 cm | 350 steps/min |
| run, after | 43% of the stretch | 5% of body speed | −1.1 cm | 350 steps/min |

"Down" means no more than 1 cm above the foot's standing height, the drive's
own contact line. A down foot still moves at well under the 15% bound, and
cadence and speed are unchanged.

The run now keeps a foot down for more than its 37.6% flat-ground share: as on
flat ground (41.5% there), a foot also counts as down for the moment it is
within 1 cm of the ground as it lifts and lands.

**The −1.1 cm left is the drive's baseline, not the plant.** The drive measures
lift against each foot's clearance in the standing pose at the spawn point,
which is itself on uneven ground: there the left foot stood 9.09 cm above the
terrain and the right 6.98 cm, about ±1.05 cm around their 8.0 cm midpoint
(the rig is symmetric, so both ankles stand equally high over flat ground). A
foot planted exactly on the terrain therefore reads about −1.1 cm against the
left foot's baseline. `planted_feet_test` measures the plant directly against a
15° slope and holds every planted ankle to its standing height above the ground
under it within 1 mm.

The trace fingerprint changes, because the feet move differently, to
`b241c5b5acb2315e3d98a97439f1eff38618b8ec126870aa48f410e3204d6b0d`.

## Frames

The drive's follow frames, before and after. A centimetre at the foot is close
to invisible at this camera distance; the frames show that nothing else moved,
and the table above is the measurement.

| | Before | After |
|---|---|---|
| walk | ![walk before](follow-walk-before.png) | ![walk after](follow-walk-after.png) |
| run | ![run before](follow-run-before.png) | ![run after](follow-run-after.png) |

Reference: the drive's own cue, *Kingmakers* Official Announcement Trailer
1:06–1:10 (full-body stride and camera tracking at speed), linked from the
drive summary and not copied here.

## Remaining gap

- The feet follow the terrain's height, not its tilt: a planted foot keeps its
  standing orientation, so on a slope its sole meets the ground at the ankle but
  not along its whole length.
- The standing pose does not plant: at rest on uneven ground each foot keeps its
  flat-plane height, which is the ±1 cm the drive's baseline shows.
- Ground that the walkable height does not describe (ruins, rocks and other
  static pieces) is not sampled; there the gait falls back to the flat plane.
