# The wanderer gets an airborne silhouette (#553)

Five exact vertical-velocity frames from the default-off `WAR_JUMP_MOTION`
preview. Read left to right:

| frame | production input |
|---|---:|
| [`jump-00-takeoff.png`](jump-00-takeoff.png) | +7.2 m/s |
| [`jump-01-rise.png`](jump-01-rise.png) | +3.6 m/s |
| [`jump-02-apex.png`](jump-02-apex.png) | 0.0 m/s |
| [`jump-03-fall.png`](jump-03-fall.png) | -3.6 m/s |
| [`jump-04-descent.png`](jump-04-descent.png) | -7.2 m/s |

The committed `jump` scenario in `client/tools/frame_capture.gd` boots the real
main scene, requires `WAR_JUMP_MOTION=1`, finds the shipped `Wanderer` Player and
calls the same `WalkLocomotion.apply_jump` method used on every real airborne
tick. It freezes root translation and the independent breathing channel so only
the production skeleton treatment changes across the sequence. The fixed
three-quarter daylight camera is shared with the gait evidence.

The windowed Godot 4.7.1 run reported:

```text
BOOT_OK v0.1.17 — world built, 24 people and 8 hounds in the Reach
CAPTURE PASS — 5 jump phases written (left-foot travel 69.5 cm)
```

## The moving reference

[Guild Wars 2, “Cubic Riddle,”
1:29–1:32](https://www.youtube.com/watch?v=WgZJuFse9TI&t=89s) is the approved-title
moving reference for this cue. The traversal sequence keeps the small
third-person character readable while the legs tuck promptly after takeoff and
the body returns cleanly to traversal after landing.

This preview takes only those abstract motion relationships. The
vertical-velocity-driven three-pose arc, bilateral mapping to this recipe rig,
fixed Ashfall Reach camera, and conservative close-to-torso arm path are
independent expressive choices.

**Originality:** no reference frame, model, animation data, texture or other
third-party media is committed, traced, downloaded, transformed or used as
generator input. These five images are first-party captures of World at Ruin;
their hashes are recorded in `docs/first-party-captures.sha256`.

## What the sequence shows

- Takeoff, rise, apex, fall and descent are visibly distinct rather than one
  crouch held for the whole arc.
- Both legs move as one airborne silhouette. The first render exposed mirrored
  local-X signs as a split-legged pose; the checked-in sequence is the retuned
  bilateral result.
- The feet travel 69.5 cm across the five production poses, so an upper-body
  flourish cannot satisfy the capture.
- The real-Player regression separately proves ordinary play is unchanged with
  the flag absent, the opted-in capsule actually leaves the floor, and landing
  clears the pose.

## The remaining gap

This is a reviewable first jump arc, not finished movement. The capture holds
the Player root in one place, so it proves the skeleton treatment rather than
the felt timing of a complete translated jump. There is no authored
anticipation, landing compression or recovery, directional lean, camera
response, turn cue, or blend into the opt-in walk/run. Clothing and the base
body also remain below the character-material target. Those gaps are why the
preview remains default-off and why flag retirement is tracked by #562.
