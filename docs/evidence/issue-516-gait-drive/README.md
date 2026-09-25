# Judging a gait at speed: the controller-driven capture (#516)

Evidence for the `gait_drive` scenario of `client/tools/frame_capture.gd`, which
drives the shipped controller with real input instead of posing fixed phases.

The `walk`, `run` and `gait_transition` scenarios call `WalkLocomotion` directly
with the body pinned, so their frames show the POSE and nothing downstream of it.
Cadence, foot slide, the stride constants turning speed into step rate, and the
follow camera at speed are all invisible to them: a stride-length regression
produces a fixed-phase sequence identical to a correct one.

## How it runs

```sh
WAR_SCENARIO=gait_drive WAR_WALK_CYCLE=1 WAR_RUN_CYCLE=1 \
  WAR_SHOT_DIR=/tmp/shots WAR_SAVE_PATH=/tmp/probe_save.json \
  WAR_VAULT_PATH=/tmp/probe_vault.json WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
  godot --path client --resolution 1600x900 res://tools/frame_capture.tscn
```

`WAR_SAVE_PATH` must be a throwaway copy of `client/recipes/wanderer.json`, as for
every capture. The run must be windowed.

The drive holds `move_forward` (and `sprint` where the plan says so) and steps
`Player._physics_process` by hand, once per physics tick, at the engine's fixed
step: a 2.4 m walk run-up from rest, a measured two-cycle walk, the sprint press,
and a measured two-cycle run, along a committed straight line north-east of the
shrine. It writes:

- `gait_drive_NN_<segment>.png` — a three-quarter-front camera carried with the
  body, at evenly spaced **distances** through one cycle of each gait and six
  points across the sprint press;
- `gait_drive_follow_walk.png` and `gait_drive_follow_run.png` — the Wanderer's
  own follow camera at the end of each measured gait;
- `gait_drive_summary.txt` — cadence, speed, slide and lift over every
  controller step of each measured gait, and the trace fingerprint.

## What makes it reproducible

- The controller is stepped from a physics-frame hook, where `move_and_slide`
  takes the fixed physics delta. Stepped anywhere else it would take the render
  delta and follow wall-clock, so the tool fails if it ever finds itself outside
  a physics frame.
- Frames are taken at distance marks, never at times.
- The breathing idle, which runs on wall-clock, is pinned to one phase exactly
  as in the fixed-phase sequences, and mouse and right-stick look are disabled
  so nothing but the held actions steers the body.
- A rehearsal drives the whole plan first at 8 controller steps per engine tick
  with no rendering; the photographed drive then runs at 1 step per tick with
  renders between marks. The two per-step traces must be **identical**, or the
  capture fails.

## Measured on the shipped gaits (2026-09-25)

Host: Apple M2 Pro, Metal 4.0 Forward+, Godot 4.7.1, `client/recipes/wanderer.json`.

| Gait | Cadence | Speed | Per stride cycle | Foot nearest the ground | Its height off standing (mean, range) |
|---|---|---|---|---|---|
| walk | 300 steps/min | 6.00 m/s | 2.40 m | moves at **109%** of body speed | 4.0 cm (−1.4 to 9.5) |
| run | 350 steps/min | 10.49 m/s | 3.60 m | moves at **111%** of body speed | 6.7 cm (−2.7 to 17.1) |

Both cadences are exactly what the authored constants produce
(`WALK_SPEED / STRIDE_LENGTH_M` and `SPRINT_SPEED / RUN_STRIDE_LENGTH_M`, two
steps per cycle), so the runtime wiring is right. What the table also shows is
the remaining gap: **no foot holds the ground at either gait**. The foot nearest
the ground travels slightly faster than the body rather than staying put, and
both gaits lift both feet together at the ends of each stride — the body rides
several centimetres above its standing height instead of setting a foot down.

Three separate processes on this host and CI's hosted macOS runner all
produced the same trace fingerprint,
`550cd878d150921a10b6ef586c152e04d95bf92ac3666811de5a9607b868db23`, and each
reproduced its own rehearsal exactly. That the two machines agree is an
observation, not a promise: a different Godot build or CPU class may compute a
different trace, so a mismatch across machines is a question to investigate
rather than proof of a regression. Between runs of one commit on one machine it
must match.

## Ablations — deliberate wrong builds the instrument must tell apart

| Wrong build | What the drive reports |
|---|---|
| The run's stride equalised to the walk's (`RUN_STRIDE_LENGTH_M` 3.6 → 2.4) | run reads **525** steps/min and **2.40 m** per cycle, against 350 and 3.60. The capture still passes: it is evidence for a reviewer, not a gate on tuning. |
| Locomotion advanced by the render delta instead of the physics step | `CAPTURE FAIL` — the photographed drive differs from its rehearsal from the first moving step, by up to 0.81 m |
| The controller never calls `advance_motion` | `CAPTURE FAIL` — no complete step in the measured walk: the feet are not alternating |

## How the numbers are defined

- A **step** is counted where the leading foot changes along the heading, with
  2 cm of hysteresis, and timed at the feet's actual crossing, interpolated
  between the two controller steps it falls between. Cadence uses whole stride
  cycles only: the standing pose leans on one leg, so the feet cross at uneven
  intervals (11 and 13 controller steps on the walk).
- "Which foot is lower" is deliberately **not** the step signal. Both gaits lift
  and lower the feet together, so on the walk the lower foot barely alternates
  although the legs plainly do.
- **Slide** is how far the foot nearest the ground moves over it, divided by how
  far the body moves, over intervals where the same foot is nearest at both
  ends. 0% is a foot that holds its place; 100% is a foot carried like a skate.
- **Lift** is that nearest foot's height against the standing pose's own foot
  height at the same spot.

`client/tests/gait_drive_capture_test.gd` pins all of these against constructed
traces with known answers, and checks that the committed line is still clear on
a freshly generated world.
