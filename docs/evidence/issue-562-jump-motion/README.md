# The ordinary jump carries an authored airborne silhouette

Five exact vertical-velocity frames from the shipping Wanderer jump. Read left
to right:

| frame | production input |
|---|---:|
| [`jump-00-takeoff.png`](jump-00-takeoff.png) | +7.2 m/s |
| [`jump-01-rise.png`](jump-01-rise.png) | +3.6 m/s |
| [`jump-02-apex.png`](jump-02-apex.png) | 0.0 m/s |
| [`jump-03-fall.png`](jump-03-fall.png) | -3.6 m/s |
| [`jump-04-descent.png`](jump-04-descent.png) | -7.2 m/s |

The committed `jump` scenario in `client/tools/frame_capture.gd` boots the real
main scene, finds the shipped `Wanderer` Player and calls the same
`WalkLocomotion.apply_jump` seam used on every airborne tick. It freezes root
translation and the independent breathing channel so only the production
skeleton treatment changes across the sequence. The fixed three-quarter
daylight camera is shared with the gait evidence.

The windowed Godot 4.7.1 run reported:

```text
BOOT_OK v0.1.17 — world built, 24 people and 8 hounds in the Reach
CAPTURE PASS — 5 jump phases written (left-foot travel 69.5 cm)
```

## Moving reference and originality

[Guild Wars 2, “Cubic Riddle,”
1:29–1:32](https://www.youtube.com/watch?v=WgZJuFse9TI&t=89s) is the approved-title
moving reference for this cue. The traversal sequence keeps the small
third-person character readable while the legs tuck promptly after takeoff and
the body returns cleanly to traversal after landing.

World at Ruin takes only those abstract motion relationships. Its
vertical-velocity-driven three-pose arc, bilateral mapping to this recipe rig,
fixed Ashfall Reach camera and close-to-torso arm path are independent
expressive choices.

**Originality:** no reference frame, model, animation data, texture or other
third-party media is committed, traced, downloaded, transformed or used as
generator input. These five images are first-party captures of World at Ruin;
their hashes are recorded in `docs/first-party-captures.sha256`.

## Evaluation and remaining gap

Takeoff, rise, apex, fall and descent read as one airborne cue at gameplay
distance, both legs stay in one silhouette, and 69.5 cm of foot travel prevents
an upper-body flourish from satisfying the evidence gate. The real-Player
regression separately proves that ordinary jump input enacts this treatment and
that landing clears it.

This remains an in-place improvement to an early character surface, not a
finished movement set. There is no authored anticipation, landing compression
or recovery, directional lean, camera response, turn cue, or blend into the
optional walk and run. The hands can still intersect at the tight apex pose,
and the clothing and base body remain below the character-material target.
