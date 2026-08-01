extends Node
## Renders the real game from a fixed set of vantages and writes PNGs, so a
## player-visible change can carry evidence a reviewer can LOOK at rather than a
## written claim that it looks fine.
##
## This exists because the quality bar (AGENTS.md) judges player-visible work on
## the rendered frame, and a prose assertion is exactly the self-attestation that
## rule is meant to replace. CI runs this and uploads the frames as a build
## artifact.
##
## Run (must be WINDOWED — a headless run renders nothing at all):
##   WAR_SHOT_DIR=/tmp/shots \
##     WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client --resolution 1600x900 res://tools/frame_capture.tscn
##
## Against the EXPORTED client the scene argument is unavailable — the official
## export template refuses positional scene paths (compiled with
## disable_path_overrides) — so main.gd carries a WAR_CAPTURE=1 boot redirect
## into this scene instead:
##   WAR_CAPTURE=1 WAR_SHOT_DIR=/tmp/shots \
##     WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     "World at Ruin.app/Contents/MacOS/World at Ruin"
##
## Redirect EVERY save seam, not just the character file. This tool boots the
## real launch path, so an unredirected run writes the player's own progression
## vault and their boot-recovery ledger as well as their save (#309, #301) — the
## boot tests get this from IsolatedBoot, but this tool is invoked by hand and by
## CI, so it is on the caller. The ledger is the worst of the three to get wrong:
## quarantine is forward-only, so a build a capture run quarantined could never
## be cleared by a later successful launch. Point WAR_SAVE_PATH at a throwaway COPY of a character recipe: with
## no save present the first-run creator opens and its panel covers a third of
## the frame, and with the real path a capture would touch the player's own save.

## The change-report tool's image comparison, reused rather than reimplemented:
## its max-channel metric is the repo's settled answer to "how much did this
## frame move", and a second private copy here would be free to drift from the
## numbers a reviewer reads in the change report. Preloaded because
## `frame_diff.gd` is a tool script with no `class_name`; only its static
## comparison is called, so nothing of it is instantiated.
const FrameDiff := preload("res://tools/frame_diff.gd")

## Every scenario this tool knows. Listed once so the dispatch below and the
## error message a caller sees cannot disagree — the previous pair of hand-kept
## conditions had already drifted apart by one scenario.
const SCENARIOS: Array[String] = [
	"world",
	"first_run",
	"breath",
	"walk",
	"run",
	"gait_transition",
	"jump",
	"light_response",
	"ash_motion",
	"replication",
	"mob_chase",
]

## The committed vantages. Fixed on purpose — evidence is only comparable across
## commits if the camera does not move between them. Each is [name, eye, target].
const VANTAGES: Array = [
	# Into the low sun: the view that exposes fog/scatter/glow stacking. A pass
	# tuned only on a flattering angle regresses here without anyone noticing.
	["sunward", Vector3(-45.0, 9.0, -55.0), Vector3(0.0, 3.0, 0.0)],
	# Across the ruin field, away from the sun: shows tonal range, contact
	# occlusion and how the scatter reads as composition.
	["crossfield", Vector3(55.0, 11.0, 40.0), Vector3(-10.0, 3.0, -20.0)],
	# Close on the shrine: near-field material and surface detail, where flat
	# untextured materials are most obvious.
	["shrine", Vector3(17.0, 4.5, 17.0), Vector3(0.0, 2.0, 0.0)],
	# Standing ON the pale stone country, west of the shrine. Every other
	# vantage was chosen before the ground had regions and none of them can
	# evidence one: they frame mostly ashflats, and catch a second region only
	# far off, where the haze has already flattened it.
	#
	# Near-field on purpose, and that is measured rather than assumed. Against
	# the same camera on the pre-region build, a vantage looking ACROSS a
	# boundary twenty metres out moved the frame by 0.013 luma; standing on the
	# far ground moved it by 0.034. The ground palette survives underfoot and
	# is largely gone by mid-distance — see [GroundRegions] for the numbers and
	# for what swallows the rest. A frame that cannot show the thing it is
	# evidence for is worse than no frame.
	["bonepale", Vector3(-58.0, 5.5, 2.0), Vector3(-72.0, 1.0, -4.0)],
	# Looking south-west across the open ground at the cinderreach high country
	# (#327). The other outdoor vantages cannot evidence a LANDFORM: they frame
	# ashflats, and the strongest of them moves only 5.38% of pixels when a whole
	# region changes height, because they are near-field cameras chosen to show
	# ground PALETTE — which reads underfoot and is gone by mid-distance.
	#
	# Shape is the opposite: a silhouette survives the haze that eats colour, so
	# the camera that evidences it has to stand BACK and look ACROSS. This one
	# moves 33.61% of pixels on that change. Committed rather than taken ad hoc
	# precisely because a self-chosen angle is the one that can flatter — fixed
	# cameras are what make a later regression here impossible to hide.
	["cinderreach", Vector3(-52.0, 9.0, -34.0), Vector3(-92.0, 2.0, -74.0)],
]

## Frames to let the world build before the first shot (generation is synchronous
## but shaders, shadow cascades and SDFGI cascades need frames).
const WARMUP_FRAMES := 150
## Frames to settle after each camera move. Volumetric fog uses temporal
## reprojection and SDFGI re-converges, so an immediate capture photographs a
## half-resolved frame.
const SETTLE_FRAMES := 120
## Upper bound on the viewport-by-viewport walk of the expanded advanced
## section — a runaway guard only. The list is ~35 controls over ~3 viewports,
## so hitting this means the scroll geometry is wrong, not that the panel grew.
## Exceeding it FAILS the capture: a quiet stop would report success having
## never photographed the bottom of the list.
const MAX_ADVANCED_VIEWPORTS := 20

## Minimum luminance spread across a sampled grid for a frame to count as real.
## A capture that photographs nothing still writes a valid PNG and still reports
## success — this is the guard against that silent failure.
const MIN_LUMA_SPREAD := 0.02

## Minimum luminance spread for a CAVE frame, kept separate on purpose: the
## cave is DESIGNED dark ("darkness from occlusion, light from torches"), so a
## daylight bar would be the wrong contract to hold it to. The torch pools
## against occlusion darkness still put real contrast into a live frame; this
## floor only rejects the dead cases — an all-black frame (torches never built
## or lit) and a near-uniform fill (the camera ended up inside rock).
## Calibration (macOS, 1600x900, shipped lighting): cave-chamber measured
## 0.211 and cave-walkout 0.325 — an order of magnitude over this floor, so
## torch flicker cannot flake it while a dead frame still cannot pass it.
const CAVE_MIN_LUMA_SPREAD := 0.02

## ── The exterior mouth vantage (#495) ────────────────────────────────────────
## Standoff from the mouth along the bore axis, in metres of CAVE-LOCAL +X (the
## direction that runs out of the massif). Chosen so the whole doorway
## composition lands in one frame: at this range the 68° view spans about 16 m
## vertically, against jamb slabs 4.6 m tall, flanking boulders out to z = ±4.8
## and a massif face standing 5.5 m over the bore. Closer crops the face off the
## top; further shrinks the entrance rock toward the noise floor this vantage
## exists to clear.
const MOUTH_STANDOFF := 11.0
## Eye height above the ground the camera stands on — a wanderer's, because the
## composition this frame is evidence for is the one a player walks up to.
const MOUTH_EYE_HEIGHT := 1.7
## Aim point, just inside the bore: far enough in to be roofed by the massif
## (which is what proves the shot looks INTO the doorway rather than past it),
## and high enough that the frame carries the face above the bore rather than
## centring on the floor.
const MOUTH_LOOK_INSET := 1.0
const MOUTH_LOOK_HEIGHT := 2.2

## The guard samples only this central box (fractions of width/height), because
## the HUD is drawn OVER the 3D view: the title sits top-left and the control
## hints run along the bottom. Sampling the whole frame would let those few
## bright text pixels satisfy the spread check while the 3D view behind them is
## entirely blank — the guard would then pass on exactly the failure it exists to
## catch. This box excludes both HUD bands, so the check measures the WORLD.
const SAMPLE_X0 := 0.12
const SAMPLE_X1 := 0.88
const SAMPLE_Y0 := 0.22
const SAMPLE_Y1 := 0.86

## ── Terrain-contribution control (#150) ──────────────────────────────────
## The guard chain above proves the terrain EXISTS, is VISIBLE, is in FRONT of
## the camera and would be DRAWN — none of it proves its material lands pixels.
## A material made fully transparent, or a shader discarding every fragment,
## passes every one of those while the frame shows only sky. The control
## measures the contribution directly: hide the terrain mesh and the frame must
## CHANGE where bare terrain was. One vantage on purpose — the property belongs
## to the shared terrain MATERIAL, not to a camera position, so one honest
## measurement proves it, and every extra control frame adds wall-time and
## flake surface to the job #142 wants promoted to required. Crossfield,
## specifically, because it frames the widest expanse of bare ground without
## the sunward glare.
const CONTRIB_VANTAGE := "crossfield"
## Frames between each pair of control captures. The same gap for the live
## pair (the noise reference) and the hidden pair, so the reference measures
## exactly the drift — wind-swayed foliage, fog reprojection, GI convergence —
## the verdict has to see past.
const CONTRIB_GAP_FRAMES := 15
## The floor on bare-terrain samples: fewer means the vantage frames too
## little open ground for the verdict to mean anything, which is itself a
## failure — a control that silently measured three pixels would be the same
## self-attestation this tool exists to replace.
const CONTRIB_MIN_POINTS := 40
## A sample is QUIET when the live pair differs by no more than this at it.
## Only quiet samples may vouch: a point a grass card sways across changes
## between ANY two frames, terrain or no terrain.
const CONTRIB_QUIET_NOISE := 0.02
## What hiding the terrain must do to a quiet sample for it to count as
## contribution. Bare ground turning into sky moves channels by whole tenths;
## this floor only needs to clear the noise band with margin.
const CONTRIB_MIN_CHANGE := 0.08
## The floor on quiet samples: if wind or temporal effects touch nearly every
## sample, the measurement is impossible and must say so rather than pass.
const CONTRIB_MIN_QUIET := 24
## The fraction of quiet samples that must change when the terrain hides.
## Well under the measured healthy value on purpose: height fog compresses the
## far field toward the sky colour, so distant ground can change less than
## CONTRIB_MIN_CHANGE when hidden, and a wanderer strolling into a sample holds
## a pixel steady — neither refutes contribution. Calibration (macOS, 1600x900,
## shipped lighting): healthy crossfield measured 0.88 contributing with median
## change 0.122; the discard-everything ablation measured 0.00. This floor
## splits that gap with wide margin on both sides.
const CONTRIB_MIN_FRACTION := 0.5

## ── Hollow-ash contribution control (#346) ───────────────────────────────
## Moving the Sun changes opaque terrain too, so two different ash-vantage
## frames do not by themselves prove that the FogVolume landed any pixels.
## Hold camera, light and animation fixed, hide only the built volume subtree,
## and require a visible change across a meaningful part of the world box.
const ASH_CONTRIB_MIN_DELTA := 0.01
const ASH_CONTRIB_MIN_FRACTION := 0.02

## ── Replication capture (#325) ───────────────────────────────────────────
## The committed population the `replication` scenario photographs. Values,
## not bytes: `WireCodec.decode` is pinned against the SERVER's encoder by the
## shared cross-tier goldens, so re-proving the decoder here would duplicate
## that contract while adding a hand-maintained hex blob. What this scenario
## exists to evidence is everything downstream of it — the fold, the view, and
## the pixels — so it enters the store the way a decoded frame does.
const REPLICATION_FIXTURE := "res://tools/data/replication_snapshot.json"
## The zone seam the scenario forces. `.invalid` is the RFC 2606 reserved TLD,
## so it cannot resolve even if a future refactor did try to open it — but the
## scenario does not rely on that: it forces an EMPTY token, and ZoneConnection
## refuses on the missing token before it constructs a socket at all. The
## capture then ASSERTS that refusal, so "no server was contacted" is a proved
## property of the run rather than a claim in a comment.
const REPLICATION_ZONE_URL := "wss://capture.invalid/zone"
const MOB_CHASE_REFERENCE := (
	"docs/art-direction/README.md Character motion — " +
	"Kingmakers Official Announcement Trailer 1:06–1:10 — " +
	"https://www.youtube.com/watch?v=OvezgDni8z4&t=66s"
)
const MOB_CHASE_REMAINING_GAP := "replicated capsules prove authoritative approach and cast hold; creature locomotion, cast telegraphs and authored combat presentation are not replicated yet"
## Where the camera stands relative to the fixture's centroid, and what height
## it looks at. Derived from the fixture rather than committed as a vantage:
## the subject here is the population, so the frame must follow it if the
## fixture ever moves.
const REPLICATION_CAM_OFFSET := Vector3(6.5, 2.6, 7.5)
const REPLICATION_LOOK_HEIGHT_M := 1.0
## How far a marker may sit above the ground beneath it before the fixture is
## judged to be floating. Capsule origins are at the capsule's CENTRE, so a
## grounded marker sits half its height up; the band allows that plus slack for
## uneven ground, and rejects a fixture authored at the wrong height — which
## would publish capsules hanging in the air as evidence.
const REPLICATION_MAX_GROUND_GAP_M := 2.0
## ⚠️ THE VERDICT IS SAMPLED WHERE THE MARKERS ARE, NOT OVER THE WHOLE FRAME,
## and that is MEASURED rather than assumed. The obvious guard — "the frame with
## the population must differ from the frame without it" — was built first and
## proved VACUOUS on exactly the shape the breath guard hit: three capsules
## changed 3.79% of the frame while two shots of the SAME populated state
## already differed by 4.01%, because this world is never still (temporal
## antialiasing jitters every edge, foliage sways, fog reprojects). The
## population was genuinely there and the whole-frame metric could not see it
## past the drift. Any threshold that passed it would also have passed an empty
## table.
##
## So the measurement is restricted to the pixels the capsules actually cover,
## and it runs through the very same [method contribution_verdict] the terrain
## control uses — the question "did this thing land pixels?" is identical, and
## its noise band, change floor and sample floors are already pinned by
## `terrain_contribution_test`. Only the designation differs: bare ground there,
## capsule interiors here.
##
## Sample grid per marker, in fractions of its own half-height and radius, so
## every point is well inside the capsule body rather than on a cap or an edge
## that antialiasing shares with the background.
const REPLICATION_SAMPLE_ROWS := 6
const REPLICATION_SAMPLE_COLS := 3

## The first-run scenario samples the LEFT band instead, because that is where
## the creator's panel is anchored (PRESET_LEFT_WIDE). Sampling the world box
## would measure the 3D view BEHIND the panel — so a run where the creator never
## opened would pass on the scenery, which is the whole failure this scenario
## exists to catch.
const UI_SAMPLE_X0 := 0.02
const UI_SAMPLE_X1 := 0.30
const UI_SAMPLE_Y0 := 0.10
const UI_SAMPLE_Y1 := 0.90

## Phases of one breath the `breath` scenario photographs. Six is enough to
## read the shape of the cycle — inhale, hold, exhale — without turning the
## evidence into a flipbook nobody scrolls through.
const BREATH_PHASES := 6
## Frames to settle after posing a phase. The body is already lit and in view,
## so only the skin needs to re-deform; no shadow/SDFGI convergence is involved.
const BREATH_SETTLE_FRAMES := 4
## Camera offset from the framed chest, in metres: three-quarter front, slightly
## above the chest, close enough that ~10 mm of shoulder travel is not sub-pixel.
const BREATH_CAM_SIDE := 1.15
const BREATH_CAM_RISE := 0.22
const BREATH_CAM_FRONT := 1.55
## The least shoulder travel between opposite phases that counts as a moving
## body, in metres. The shipped idle produces ~19 mm here; a stopped one
## produces exactly 0. The floor sits far below the former and far above the
## latter, so it gates the failure without pinning the tuning.
const BREATH_MIN_TRAVEL_M := 0.003
## The least clavicle rotation between inhale and exhale that counts as a
## breath. The shipped idle swings 2 * SHOULDER_RISE_DEG = 4.0 deg here; a
## build with the breath channel deleted swings exactly 0 while its weight
## shift still clears the travel floor above.
const BREATH_MIN_SWING_DEG := 1.0

## Fixed phases of the opt-in walk cycle. Eight shows both planted/swing
## exchanges and the two passing poses without turning the artifact into a
## long flipbook.
const WALK_PHASES := 8
const WALK_SETTLE_FRAMES := 4
## A real gait must move a foot through the world, not merely rotate an arm.
## The shipped first slice clears this by a wide margin; the floor rejects a
## frozen or disconnected lower body without pinning the tuning.
const WALK_MIN_FOOT_TRAVEL_M := 0.08
## Three-quarter front, full-body framing on open ground south of the shrine.
const WALK_CAM_SIDE := 2.0
const WALK_CAM_RISE := 0.5
const WALK_CAM_FRONT := 3.2
const WALK_VANTAGE_Z := 18.0

## Six equal runtime updates span the complete eased walk↔run crossfade. One
## steady walk frame, six press frames and six release frames produce a compact
## sequence that includes both input edges and both settled endpoints.
const GAIT_TRANSITION_STEPS := 6
const GAIT_TRANSITION_DELTA := (
	WalkLocomotion.GAIT_BLEND_SECONDS / float(GAIT_TRANSITION_STEPS)
)
const GAIT_TRANSITION_REFERENCE := (
	"Kingmakers Official Announcement Trailer 1:06-1:10 — " +
	"https://www.youtube.com/watch?v=OvezgDni8z4&t=66s"
)
const GAIT_TRANSITION_REMAINING_GAP := (
	"walk and run now crossfade; authored starts, stops, turns, directional lean " +
	"and landing impact remain open"
)

## Exact points on the shipped controller's airborne arc: launch, approach to
## apex, apex, approach to landing, and landing-ready descent. A five-frame
## sequence exposes continuity between the three authored silhouettes without
## inventing wall-clock timing in the evidence tool.
const JUMP_SPEEDS := [
	WalkLocomotion.JUMP_REFERENCE_SPEED,
	WalkLocomotion.JUMP_REFERENCE_SPEED * 0.5,
	0.0,
	-WalkLocomotion.JUMP_REFERENCE_SPEED * 0.5,
	-WalkLocomotion.JUMP_REFERENCE_SPEED,
]
const JUMP_LABELS := ["takeoff", "rise", "apex", "fall", "descent"]
const JUMP_SETTLE_FRAMES := 4
## A frozen standing body or an upper-body-only flourish cannot pass this
## evidence gate: one real foot must move through the full-body sequence.
const JUMP_MIN_FOOT_TRAVEL_M := 0.05

## The creator is 2D, but its transparent side photographs the live 3D world.
## SDFGI and volumetric reprojection therefore need the same 150-frame initial
## convergence as a world capture. The former 60-frame UI-only assumption is
## what let independent runners photograph different terrain-lighting phases
## even after the creator's own breathing pose was pinned (#556).
const UI_WARMUP_FRAMES := WARMUP_FRAMES
## Frames to settle after a preset switch: it rebuilds the portrait rig, so an
## immediate shot photographs the previous body.
const UI_SETTLE_FRAMES := 30
## Three frozen controls produce three within-run pairs. One pair can land at an
## unusually quiet phase and understate the renderer's floor by an order of
## magnitude; the maximum across all three pairs is the conservative control.
const ASH_MOTION_CONTROL_FRAMES := 3
## Seconds of the production field clock between the frozen control and moved
## state. At FIELD_SPEED this carries the pattern 4.32 m downwind: large enough
## to judge inside a hollow without jumping to an unrelated phase.
const ASH_MOTION_SECONDS := 4.0
## Real intermediate states in the evidence sequence. Eight at half-second
## spacing show direction and continuity; interpolating two endpoint stills
## would manufacture motion the renderer never produced.
const ASH_MOTION_PHASE_STEPS := 8


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty():
		_fail("WAR_SHOT_DIR is not set — nowhere to write frames")
		return
	if DisplayServer.get_name() == "headless":
		_fail("running headless — a headless run renders nothing; use a windowed run")
		return

	# This tool boots the shipped main scene below, which is the real launch
	# path: unredirected, it reads and can write the player's own character save
	# and progression vault. Boot tests get that guarantee structurally from
	# IsolatedBoot, but this tool is invoked by hand and by CI, so refuse to run
	# rather than document a rule a caller can forget (#309). Every seam, not
	# just the save — a half-redirect still writes the unredirected half.
	#
	# Test the RESOLVED path, not whether the variable is set. The stores read
	# their env override verbatim, so an UNSET seam and one pointed AT the
	# shipped default both resolve to the player's real file — only the resolved
	# value tells either apart from a throwaway probe.
	#
	# And compare the paths CANONICALLY, not as strings. `user://character.json`
	# and the absolute OS path it globalizes to are the same file spelled two
	# ways, so a raw `==` lets an override aimed squarely at the player's real
	# save read as a throwaway probe — the guard would wave through exactly the
	# case it exists to stop.
	for seam: Array in [
			[CharacterStore.SAVE_PATH_ENV, CharacterStore.save_path(), CharacterStore.DEFAULT_PATH],
			[SaveVault.VAULT_PATH_ENV, SaveVault.vault_path(), SaveVault.DEFAULT_PATH],
			# The recovery ledger (#301) is exactly the case the sentence above
			# warns about. Reconcile runs on EVERY boot now, so an unredirected
			# capture reads and rewrites the player's own ledger — and quarantine
			# is forward-only, so a build this tool quarantined could never be
			# cleared by a later successful launch.
			[BootRecovery.RECOVERY_PATH_ENV, BootRecovery.recovery_path(), BootRecovery.DEFAULT_PATH]]:
		if _same_file(String(seam[1]), String(seam[2])):
			_fail(("%s resolves to the player's real file (%s) — refusing to boot the game against "
				+ "real player state. Point every save seam at a throwaway path before capturing.")
				% [seam[0], seam[2]])
			return

	# The scenario is resolved BEFORE the game boots, because one of them has to
	# configure the world it is about to photograph. `replication` needs the
	# zone seam set while main.gd's _ready runs — see _arm_replication_seam().
	var scenario := OS.get_environment("WAR_SCENARIO")
	if scenario.is_empty():
		scenario = "world"
	if not SCENARIOS.has(scenario):
		_fail("unknown WAR_SCENARIO '%s' — expected one of %s" % [scenario, ", ".join(SCENARIOS)])
		return
	if scenario == "replication" or scenario == "mob_chase":
		_arm_replication_seam()

	# Load the scene the PROJECT actually boots, not a hardcoded path: the
	# capture gate treats project.godot as a visual trigger, so a PR that
	# repoints application/run/main_scene must be captured as the shipped game
	# rather than as whatever this tool used to assume.
	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.is_empty():
		_fail("application/run/main_scene is unset — cannot capture the shipped game")
		return
	var main: Node = load(main_scene).instantiate()
	# The root is still setting up children while our _ready runs, so a direct
	# add_child() is REFUSED — and the capture would then photograph an empty
	# viewport while still reporting success. Defer, then prove it attached.
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	if not main.is_inside_tree():
		_fail("the main scene never attached — nothing would have been rendered")
		return

	if scenario == "first_run":
		if not pin_first_run_backdrop_clock(scenario, main):
			_fail("first-run backdrop animation could not be fixed before capture")
			return
		print("BACKDROP PINNED — scenery clocks fixed before first-run capture")

	if scenario == "replication":
		await _capture_replication(dir, main)
		return
	if scenario == "mob_chase":
		await _capture_mob_chase(dir, main)
		return

	# Every remaining scenario boots with no zone, so its replica table is empty
	# and its frames contain no replicated entity — the fact #325 needs STATED
	# rather than left for a reviewer to know. Printed here, above the dispatch,
	# so it cannot be forgotten by one scenario's code path. `replication` has
	# already returned above and prints its own `on` once it has proved the
	# population is really there; an `off` here too would leave that log with
	# two contradictory verdicts, which CI refuses.
	print(ReplicaView.marker(0))

	if scenario == "first_run":
		await _capture_first_run(dir, main)
		return
	if scenario == "breath":
		await _capture_breath(dir, main)
		return
	if scenario == "walk":
		await _capture_gait(dir, main, false)
		return
	if scenario == "run":
		await _capture_gait(dir, main, true)
		return
	if scenario == "gait_transition":
		await _capture_gait_transition(dir, main)
		return
	if scenario == "jump":
		await _capture_jump(dir, main)
		return

	for i in WARMUP_FRAMES:
		await get_tree().process_frame

	# The world must actually EXIST. A luminance check alone cannot tell a
	# rendered world from a bare sky: main.gd builds the environment BEFORE
	# WorldGen, so a failure in or after world setup still leaves a procedural
	# sky gradient — which has plenty of luminance variation — and the capture
	# would publish that as proof of a world that never rendered.
	if not _has_world(main):
		_fail("the world did not build (no Terrain under World) — a sky-only frame is not evidence")
		return

	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 68.0
	get_tree().root.add_child(cam)

	if scenario == "light_response":
		await _capture_light_response(dir, main, cam)
		return
	if scenario == "ash_motion":
		await _capture_ash_motion(dir, main, cam)
		return

	for vantage: Array in VANTAGES:
		var vantage_name: String = vantage[0]
		cam.global_position = vantage[1]
		cam.look_at(vantage[2], Vector3.UP)
		# Re-assert every frame: the player's own camera can otherwise take back
		# `current` and we would silently capture the wrong view.
		for i in SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame

		# And the camera must actually be LOOKING at that world. The terrain
		# carries a collider, so a ray along the view direction hits geometry
		# whenever the shot contains ground — and misses when the camera is
		# framing nothing but sky, which is the case a luminance check happily
		# passes.
		if not _sees_geometry(cam, vantage[2]):
			_fail("vantage '%s' sees no world geometry — the shot is sky only" % vantage_name)
			return
		# A collider hit proves geometry is THERE, not that this camera DRAWS
		# it: moving the terrain to a render layer outside the camera's cull
		# mask would leave the ray hitting while the frame shows only sky.
		if not _camera_draws_world(cam, main):
			_fail("vantage '%s': the terrain's render layers are outside the camera's cull mask — it would not be drawn" % vantage_name)
			return

		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var spread := _luma_spread(img)
		if spread < MIN_LUMA_SPREAD:
			_fail("vantage '%s' is a uniform frame (luma spread %.4f) — nothing rendered" %
				[vantage_name, spread])
			return
		var out := "%s/%s.png" % [dir, vantage_name]
		var err := img.save_png(out)
		if err != OK:
			_fail("could not write %s (error %d)" % [out, err])
			return
		# Report the captured size against the size the project actually ships.
		# A hosted runner's display often cannot realise the configured window,
		# so frames arrive smaller than the game does — and apparent scale of
		# fine detail (material grain especially) changes with it. Silently
		# accepting the clamped size would let a reviewer judge a material at a
		# resolution no player uses, so the mismatch is stated on every frame.
		var note := _size_note(img)
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
			[vantage_name, out, img.get_width(), img.get_height(), spread, note])
		# Which ground the camera stands on. The regions are a palette difference
		# the haze flattens with distance, so a reviewer comparing two frames needs
		# the frame itself to say which region it is, rather than reading it back
		# off the generator by hand.
		var ground := ""
		var world_for_region := main.get_node_or_null("World") as WorldGen
		if world_for_region != null:
			ground = String(world_for_region.region_name_at(
				cam.global_position.x, cam.global_position.z))
		_write_note(dir, vantage_name, img, note, ground)

		# The frame is saved; now prove the terrain actually CONTRIBUTED to it
		# rather than merely being present, visible, ahead and drawable — the
		# gap #150 names (a transparent or discard-everything material passes
		# every structural guard while the frame shows only sky).
		if vantage_name == CONTRIB_VANTAGE:
			if not await _prove_terrain_contribution(cam, main):
				return

	var cave_count := await _capture_cave(cam, dir, main)
	if cave_count < 0:
		return

	# AFTER the cave, and that order carries a guarantee rather than being
	# tidiness: _capture_cave has by now failed the run unless the massif hull
	# exists, is visible and sits inside the camera's cull mask. The hull is
	# this frame's subject too — it is the face standing over the bore — so
	# running second is what lets the exterior step assert only the properties
	# that are its own. Moving this call above the cave capture silently drops
	# that cover.
	var mouth_count := await _capture_mouth(cam, dir, main)
	if mouth_count < 0:
		return

	print("CAPTURE PASS — %d vantages written to %s" %
		[VANTAGES.size() + cave_count + mouth_count, dir])
	get_tree().quit(0)


## Opposing-azimuth key-light positions for the fixed-camera response proof
## (#346). `source-side` puts the DirectionalLight3D at the camera so its rays
## travel WITH the view ray; `far-side` mirrors its horizontal position through
## the subject while retaining the same elevation. Mirroring all three axes
## would put the far-side source below the terrain and point the key upward.
## Directional-light position has no shading effect, but
## Node3D.look_at_from_position uses it to derive the orientation.
## Kept pure so light_response_capture_test can pin the geometry headlessly.
static func light_source_positions(eye: Vector3, target: Vector3) -> Array:
	return [eye, Vector3(target.x * 2.0 - eye.x, eye.y, target.z * 2.0 - eye.z)]


## A close camera outside a real hollow-ash volume, aimed through its centre and
## slightly down onto terrain. The terrain backdrop makes the volume's light
## response visible; sky behind translucent fog would hide the comparison.
## Kept pure so light_response_capture_test can hold the evidence geometry.
static func ash_response_vantage(placement: Dictionary) -> Array:
	var target: Vector3 = placement["pos"]
	var extents: Vector3 = placement["extents"]
	var eye := target + Vector3(0.0, extents.y * 1.8, extents.z + 10.0)
	return [eye, target]


## Player-height camera INSIDE one real hollow, looking mostly crosswind and
## slightly down. Wind therefore carries pockets ACROSS the frame instead of
## compressing their travel into depth, while terrain behind translucent fog
## gives them a readable backdrop.
static func ash_motion_vantage(placement: Dictionary) -> Array:
	var centre: Vector3 = placement["pos"]
	var extents: Vector3 = placement["extents"]
	var floor_y := centre.y - extents.y
	var eye := Vector3(centre.x, floor_y + minf(1.7, extents.y * 1.4), centre.z)
	var travel := minf(extents.x * 0.55, 8.0)
	var along := Wind.axis()
	var across := Vector3(-along.z, 0.0, along.x).normalized()
	var target := (
		eye + along * travel * 0.25 + across * travel * 0.85
		+ Vector3(0.0, -1.1, 0.0)
	)
	return [eye, target]


## Measures a moved ash frame against at least three frozen, identical-field
## controls from the SAME run. Reporting only: issue #328 explicitly requires
## quoted numbers rather than a guessed pass/fail threshold. The conservative
## floor is the largest control-pair delta; the signal is the smallest delta
## from the moved frame to any control, so neither number is cherry-picked.
static func ash_motion_measurement(controls: Array, moved: Image) -> Dictionary:
	var out := {
		"ok": false,
		"reason": "",
		"control_pairs": 0,
		"signal_pairs": 0,
		"noise_mean_max": 0.0,
		"noise_changed_max": 0.0,
		"signal_mean_min": INF,
		"signal_changed_min": INF,
	}
	if controls.size() < ASH_MOTION_CONTROL_FRAMES:
		out["reason"] = "need at least %d identical-field controls, got %d" % [
			ASH_MOTION_CONTROL_FRAMES, controls.size(),
		]
		return out
	for first_index in controls.size() - 1:
		if controls[first_index] is not Image:
			out["reason"] = "control %d is not an image" % first_index
			return out
		for second_index in range(first_index + 1, controls.size()):
			if controls[second_index] is not Image:
				out["reason"] = "control %d is not an image" % second_index
				return out
			var noise := FrameDiff.compare_images(
				controls[first_index] as Image, controls[second_index] as Image
			)
			if not bool(noise["ok"]):
				out["reason"] = "control pair %d/%d: %s" % [
					first_index, second_index, noise["reason"],
				]
				return out
			out["control_pairs"] = int(out["control_pairs"]) + 1
			out["noise_mean_max"] = maxf(
				float(out["noise_mean_max"]), float(noise["mean"])
			)
			out["noise_changed_max"] = maxf(
				float(out["noise_changed_max"]), float(noise["changed_fraction"])
			)
	for control_index in controls.size():
		var moved_delta := FrameDiff.compare_images(controls[control_index] as Image, moved)
		if not bool(moved_delta["ok"]):
			out["reason"] = "moved/control %d: %s" % [control_index, moved_delta["reason"]]
			return out
		out["signal_pairs"] = int(out["signal_pairs"]) + 1
		out["signal_mean_min"] = minf(
			float(out["signal_mean_min"]), float(moved_delta["mean"])
		)
		out["signal_changed_min"] = minf(
			float(out["signal_changed_min"]), float(moved_delta["changed_fraction"])
		)
	out["ok"] = true
	return out


## Production-clock offsets captured after the frozen controls.
static func ash_motion_phase_times() -> Array[float]:
	var times: Array[float] = []
	for step in range(1, ASH_MOTION_PHASE_STEPS + 1):
		times.append(ASH_MOTION_SECONDS * float(step) / float(ASH_MOTION_PHASE_STEPS))
	return times


## Visible built volumes, not placement metadata. A capable device must return
## at least one before the capture may publish ash-response frames; an
## incapable hosted runner instead declares that evidence unavailable.
static func visible_fog_volume_count(root: Node) -> int:
	if root == null:
		return 0
	var count := 0
	for node in root.find_children("*", "FogVolume", true, false):
		if (node as FogVolume).is_visible_in_tree():
			count += 1
	return count


## Stops every delta-driven animation and the shader `TIME` clock while the
## controlled pair is photographed. Process frames still advance so temporal
## reprojection and shadow cascades can settle, but foliage wind and ash drift
## remain at one phase; only the Sun orientation changes between the images.
static func freeze_light_response_animation() -> void:
	Engine.time_scale = 0.0


## Captures the opted-in intra-pool density field from the player's own
## vantage. All scene animation is frozen for every frame; only the production
## HollowFog clock advances between the controls and moved state. That makes
## the reported signal attributable to the ash field, not foliage or torches.
##
## Run windowed with all save seams redirected:
##   WAR_ASH_FIELD_DRIFT=1 WAR_SCENARIO=ash_motion \
##     WAR_SHOT_DIR=/tmp/ash-motion WAR_SAVE_PATH=/tmp/probe_save.json \
##     WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client res://tools/frame_capture.tscn
func _capture_ash_motion(dir: String, main: Node, cam: Camera3D) -> void:
	if not HollowFog.field_drift_enabled():
		_fail("ash_motion requires WAR_ASH_FIELD_DRIFT=1 — refusing to photograph the settled whole-pool path")
		return
	var placements: Array = main.call("hollow_fog_placements")
	if placements.is_empty():
		_fail("ash_motion: the shipped world placed no hollow ash pool")
		return
	var fog_root := main.get_node_or_null("HollowFog") as Node3D
	if visible_fog_volume_count(fog_root) < 1:
		_fail("ash_motion: the renderer built no visible FogVolume")
		return

	var original_time_scale := Engine.time_scale
	freeze_light_response_animation()
	var field_time_value: Variant = main.get("_hollow_fog_time")
	if field_time_value == null:
		Engine.time_scale = original_time_scale
		_fail("ash_motion: the shipped world exposes no HollowFog production clock")
		return
	var base_field_time := float(field_time_value)
	main.set("_hollow_fog_time", base_field_time)

	var vantage := ash_motion_vantage(placements[0])
	var eye: Vector3 = vantage[0]
	var target: Vector3 = vantage[1]
	cam.global_position = eye
	cam.look_at(target, Vector3.UP)

	var controls: Array[Image] = []
	var frame_names: Array[String] = []
	for control_index in ASH_MOTION_CONTROL_FRAMES:
		var frame_name := "ash-motion-control-%d" % (control_index + 1)
		var settle := SETTLE_FRAMES if control_index == 0 else CONTRIB_GAP_FRAMES
		var control := await _capture_ash_motion_frame(
			dir, frame_name, cam, main, target, settle
		)
		if control == null:
			Engine.time_scale = original_time_scale
			return
		controls.append(control)
		frame_names.append(frame_name)

	var moved: Image = null
	var phase_times := ash_motion_phase_times()
	for phase_index in phase_times.size():
		main.set("_hollow_fog_time", base_field_time + phase_times[phase_index])
		var phase_name := "ash-motion-phase-%02d" % (phase_index + 1)
		var phase_image := await _capture_ash_motion_frame(
			dir, phase_name, cam, main, target, CONTRIB_GAP_FRAMES
		)
		if phase_image == null:
			Engine.time_scale = original_time_scale
			return
		moved = phase_image
		frame_names.append(phase_name)
	Engine.time_scale = original_time_scale

	var measurement := ash_motion_measurement(controls, moved)
	if not bool(measurement["ok"]):
		_fail("ash_motion comparison failed: %s" % measurement["reason"])
		return
	var line := (
		"same-run identical-field floor: max mean |dRGB| %.4f, changed %.2f%% "
		+ "across %d pairs; 4 s field travel: min mean |dRGB| %.4f, changed %.2f%% "
		+ "across %d pairs"
	) % [
		float(measurement["noise_mean_max"]),
		float(measurement["noise_changed_max"]) * 100.0,
		int(measurement["control_pairs"]),
		float(measurement["signal_mean_min"]),
		float(measurement["signal_changed_min"]) * 100.0,
		int(measurement["signal_pairs"]),
	]
	print("ASH MOTION: %s" % line)
	for frame_name in frame_names:
		_append_capture_note(dir, frame_name, line)
	print("CAPTURE PASS — player-height inside a hollow; only the spatial ash field advanced (%s)" % line)
	get_tree().quit(0)


func _capture_ash_motion_frame(
	dir: String,
	frame_name: String,
	cam: Camera3D,
	main: Node,
	target: Vector3,
	settle_frames: int
) -> Image:
	for i in settle_frames:
		cam.current = true
		await get_tree().process_frame
	if not _sees_geometry(cam, target):
		_fail("%s sees no world geometry — the ash frame is sky only" % frame_name)
		return null
	if not _camera_draws_world(cam, main):
		_fail("%s cannot draw the world — the ash frame would be empty" % frame_name)
		return null
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var spread := _luma_spread(img)
	if spread < MIN_LUMA_SPREAD:
		_fail("%s is a uniform frame (luma spread %.4f) — nothing rendered" % [
			frame_name, spread,
		])
		return null
	var out := "%s/%s.png" % [dir, frame_name]
	var err := img.save_png(out)
	if err != OK:
		_fail("could not write %s (error %d)" % [out, err])
		return null
	print("CAPTURED %s -> %s (luma spread %.3f)" % [frame_name, out, spread])
	_write_note(dir, frame_name, img, _size_note(img))
	return img


## Adds the shared field/noise measurement to every frame's provenance note.
func _append_capture_note(dir: String, frame_name: String, line: String) -> void:
	var path := "%s/%s.txt" % [dir, frame_name]
	var f := FileAccess.open(path, FileAccess.READ_WRITE)
	if f == null:
		push_warning("could not append ash-motion measurement to %s" % frame_name)
		return
	f.seek_end()
	f.store_line("ash motion: %s" % line)
	f.close()


## The creator is motionless, but the world visible around and through it is
## live: generated foliage reads shader TIME, while lights and fog advance from
## process delta. Ask the normally booted main scene to fix only those scenery
## phases, leaving player physics and animation time untouched. This runs after
## scene attachment and before _capture_first_run's warm-up and first shutter.
static func pin_first_run_backdrop_clock(scenario: String, main: Node) -> bool:
	if scenario != "first_run":
		return false
	if main == null or not main.has_method("freeze_first_run_backdrop_animation"):
		return false
	return main.call("freeze_first_run_backdrop_animation") == true


## Holds the crossfield camera and real world fixed while the shipping Sun moves
## through opposing horizontal directions at a constant elevation. These are
## evidence frames, not a synthetic material preview: the generated foliage,
## hollow ash volumes, environment, terrain and DirectionalLight3D are the same
## nodes a player sees.
##
## Run windowed with all save seams redirected:
##   WAR_SCENARIO=light_response WAR_SHOT_DIR=/tmp/light-response \
##     WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client res://tools/frame_capture.tscn
func _capture_light_response(dir: String, main: Node, cam: Camera3D) -> void:
	var sun := main.get_node_or_null("Sun") as DirectionalLight3D
	if sun == null:
		_fail("light_response: no DirectionalLight3D named Sun — there is no moving key to prove")
		return
	freeze_light_response_animation()

	var vantage: Array = VANTAGES[1] # crossfield: broad foliage + hollow-ash read
	var response_vantages: Array[Dictionary] = [{
		"names": ["foliage-source-side", "foliage-far-side"],
		"eye": vantage[1],
		"target": vantage[2],
		"requires_volume": false,
	}]
	var placements: Array = main.call("hollow_fog_placements")
	if placements.is_empty():
		_fail("light_response: the shipped world placed no hollow ash pool to isolate")
		return
	var fog_root := main.get_node_or_null("HollowFog") as Node3D
	if visible_fog_volume_count(fog_root) > 0:
		var ash_vantage := ash_response_vantage(placements[0])
		response_vantages.append({
			"names": ["ash-source-side", "ash-far-side"],
			"eye": ash_vantage[0],
			"target": ash_vantage[1],
			"requires_volume": true,
		})
	else:
		print("ASH EVIDENCE UNAVAILABLE — this renderer built no visible FogVolume; no ash-response frames will be published")

	for response: Dictionary in response_vantages:
		var eye: Vector3 = response["eye"]
		var target: Vector3 = response["target"]
		cam.global_position = eye
		cam.look_at(target, Vector3.UP)
		var sources := light_source_positions(eye, target)
		var names: Array = response["names"]
		for index in sources.size():
			var source: Vector3 = sources[index]
			sun.look_at_from_position(source, target, Vector3.UP)
			for i in SETTLE_FRAMES:
				cam.current = true
				await get_tree().process_frame

			if not _sees_geometry(cam, target):
				_fail("%s sees no world geometry — the response frame is sky only" % names[index])
				return
			if not _camera_draws_world(cam, main):
				_fail("%s cannot draw the world — the response frame would be empty" % names[index])
				return

			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			var spread := _luma_spread(img)
			if spread < MIN_LUMA_SPREAD:
				_fail("%s is a uniform frame (luma spread %.4f) — nothing rendered" %
					[names[index], spread])
				return
			var out := "%s/%s.png" % [dir, names[index]]
			var err := img.save_png(out)
			if err != OK:
				_fail("could not write %s (error %d)" % [out, err])
				return
			var light_ray := (sun.global_transform.basis * Vector3.FORWARD).normalized()
			var view_ray := (target - eye).normalized()
			print("CAPTURED %s -> %s (light/view dot %.3f, luma spread %.3f)" %
				[names[index], out, light_ray.dot(view_ray), spread])
			_write_note(dir, names[index], img, _size_note(img))
			if bool(response["requires_volume"]) and not await _prove_ash_contribution(main, img):
				return

	print("CAPTURE PASS — fixed cameras and animation phase, live Sun moved through opposing azimuths")
	get_tree().quit(0)


## Proves the pictured hollow ash contributes pixels by capturing the identical
## view with only the built FogVolume subtree hidden. Animation time is already
## frozen by the scenario, so any measured change belongs to the volume rather
## than foliage wind or ash drift advancing between frames.
func _prove_ash_contribution(main: Node, live: Image) -> bool:
	var fog_root := main.get_node_or_null("HollowFog") as Node3D
	if fog_root == null:
		_fail("light_response: no built HollowFog subtree — placement metadata alone cannot evidence rendered ash")
		return false
	if visible_fog_volume_count(fog_root) < 1:
		_fail("light_response: HollowFog contains no visible FogVolume — ash contributes no rendered pixels")
		return false

	fog_root.visible = false
	for i in CONTRIB_GAP_FRAMES:
		await get_tree().process_frame
	var hidden := await _grab_frame()
	fog_root.visible = true
	if not fog_root.is_visible_in_tree():
		_fail("light_response: HollowFog did not return after the contribution control")
		return false

	var verdict := ash_contribution_verdict(live, hidden)
	print("ASH CONTRIBUTION: %d/%d samples changed (fraction %.3f, p95 delta %.4f)" %
		[int(verdict["changed"]), int(verdict["samples"]), float(verdict["fraction"]),
			float(verdict["delta_p95"])])
	if not bool(verdict["ok"]):
		_fail("light_response: %s" % str(verdict["reason"]))
		return false
	return true


## Reports the captured size against the size the project actually ships. A
## hosted runner's display often cannot realise the configured window, so
## frames arrive smaller than the game does — and apparent scale of fine detail
## (material grain especially) changes with it. Silently accepting the clamped
## size would let a reviewer judge a material at a resolution no player uses,
## so the mismatch is stated on every frame.
func _size_note(img: Image) -> String:
	var want_w: int = ProjectSettings.get_setting("display/window/size/viewport_width", 0)
	var want_h: int = ProjectSettings.get_setting("display/window/size/viewport_height", 0)
	if want_w > 0 and (img.get_width() != want_w or img.get_height() != want_h):
		return " [CLAMPED from the shipped %dx%d — fine detail reads at a different scale here]" % [want_w, want_h]
	return ""


## The cave vantages, in CAVE-LOCAL space, derived from the layout rather than
## committed as constants. This HONOURS the fixed-vantage rule rather than
## bending it: the layout is a pure function of the committed seed, so these
## cameras are bit-identical run over run and move ONLY when the world itself
## moves — exactly the moment a hardcoded eye would silently end up inside
## rock (or photographing a wall that used to be a chamber) and the before/
## after comparison is already void because the subject changed. A layout
## change surfaces as a NAMED density-test failure plus a visible camera
## delta in the evidence log, never as a quietly different frame. Static and
## pure so cave_capture_vantage_test.gd can pin every derived point against
## the generator's own density field — the same truth the mesh is marched
## from. Each entry is [name, eye, target]; callers map through
## WorldGen.cave_to_world().
static func cave_vantages(lay: Dictionary) -> Array:
	var rooms: Array = lay["rooms"]
	# rooms[2] is the main chamber — the space the wanderer wakes in — and
	# rooms[1] the bend the walk-out climbs into (cave_system_gen.layout()).
	var chamber: Dictionary = rooms[2]
	var bend: Dictionary = rooms[1]
	var chamber_c: Vector3 = chamber["center"]
	var chamber_floor: float = chamber["floor"]
	var bend_c: Vector3 = bend["center"]
	var out_dir: Vector3 = ((bend_c - chamber_c) * Vector3(1.0, 0.0, 1.0)).normalized()
	var spawn: Vector3 = lay["spawn"]

	# Into the chamber from its mouth-side edge: the whole wake-up space in one
	# frame — floor, spawn, torch brackets, far wall.
	var edge := chamber_c + out_dir * ((chamber["r"] as float) * 0.72)
	var chamber_eye := Vector3(edge.x, chamber_floor + 1.7, edge.z)
	var chamber_look := Vector3(chamber_c.x, chamber_floor + 1.1, chamber_c.z)

	# The walk-out as the player makes it: over the wanderer's shoulder, looking
	# across the chamber toward the bend the exit path climbs into. The lateral
	# step matters: the avatar idles AT the spawn, so a camera dead behind it
	# would frame mostly avatar and let its collider satisfy the geometry ray.
	# The side is picked toward the chamber's roomy half, so the offset cannot
	# push the eye into the near wall whatever the seed's wobble did.
	var back := spawn - out_dir * 1.3
	var shoulder := Vector3(-out_dir.z, 0.0, out_dir.x)
	var to_center := (chamber_c - back) * Vector3(1.0, 0.0, 1.0)
	if to_center.dot(shoulder) < 0.0:
		shoulder = -shoulder
	var side := back + shoulder * 1.15
	var walkout_eye := Vector3(side.x, chamber_floor + 1.8, side.z)
	var walkout_look := Vector3(bend_c.x, (bend["floor"] as float) + 1.3, bend_c.z)

	return [
		["cave-chamber", chamber_eye, chamber_look],
		["cave-walkout", walkout_eye, walkout_look],
	]


## The doorway seen from OUTSIDE, in cave-local space — the one composition the
## committed set could not photograph (#495).
##
## `cave-walkout` sounds like this frame and is not: it stands inside the
## chamber looking at the bend the exit climbs into, so the exterior face, the
## jamb slabs and the flanking boulders appear in nothing. That is the massif's
## entrance grammar and the cave↔terrain seam it exists to hide, standing in the
## sequence every wanderer walks first — measured unseen on #492, where
## recolouring the entrance rock moved all six committed vantages by 0.01–0.29%,
## the noise floor. A regression there ships with the report reading green.
##
## Derived from the layout for the reason [method cave_vantages] gives, and
## returned as ONE vantage rather than appended to that array because its laws
## are the opposite ones: this camera stands under open sky outside the rock,
## where the cave path's roofed-by-rock and dark-frame guards would reject it.
##
## The eye's Y is NOMINAL — [constant MOUTH_EYE_HEIGHT] over the mouth-floor
## plane. Outside the massif the ground belongs to the world's heightfield, not
## the cave's density field, so [method _capture_mouth] re-seats the eye onto
## the real terrain; the field-level test holds this point across a vertical
## band for exactly that reason. Static and pure so it can.
static func mouth_vantage(lay: Dictionary) -> Array:
	var mouth: Vector3 = lay["mouth"]
	# On the bore's own centreline, taken from the layout rather than assumed to
	# be zero: the bore runs from `mouth` along +X, so `mouth.z` IS the axis this
	# camera looks down, and the roofed-target law below only holds while the
	# aim point sits inside that bore.
	#
	# It is deliberately NOT enough on its own. `_place_boulders` authors the
	# jamb slabs at an ABSOLUTE z = ±3.3 and the flanking boulders at ±3.4/±4.4/
	# ±4.8 — not at `mouth.z` plus those offsets — so a mouth moved off the
	# centreline would slide the doorway out from between its own jambs, and
	# following it here would frame a bore the entrance grammar had been left
	# behind by. The test pins the two together so that desynchronisation fails
	# by name instead of arriving as a quietly lopsided frame.
	var eye := Vector3(mouth.x + MOUTH_STANDOFF, MOUTH_EYE_HEIGHT, mouth.z)
	var target := Vector3(mouth.x + MOUTH_LOOK_INSET, MOUTH_LOOK_HEIGHT, mouth.z)
	return ["cave-mouth", eye, target]


## Photographs the starter cave from vantages derived off the live layout, and
## returns the number of frames written (or -1 after failing the run). The cave
## is where every player begins, and it is lit on a different principle from
## the surface — darkness from occlusion, light from torches — so the outdoor
## frames cannot vouch for it: a lighting, fog or material change can regress
## the opening minutes while every outdoor vantage still looks fine.
func _capture_cave(cam: Camera3D, dir: String, main: Node) -> int:
	var world := main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("no WorldGen node named World — cannot derive cave vantages")
		return -1
	var cave := world.get_node_or_null("StarterCave") as CaveSystemGen
	if cave == null:
		_fail("no StarterCave under World — the place every player starts would go unphotographed")
		return -1
	var hull := _cave_hull(cave)
	if hull == null or not hull.is_visible_in_tree():
		_fail("the cave hull mesh is missing or hidden — a cave frame would show nothing")
		return -1
	# The torches are the cave's ONLY intended light source. Checked
	# structurally, so a lighting regression fails as "no torches" rather than
	# as a luminance number someone has to decode.
	if _visible_torch_light_count(cave) < 1:
		_fail("no visible torch light in the starter cave — every cave frame would be black")
		return -1

	# ...and because they are the only light, their FLICKER sets the exposure of
	# every cave frame. Pin it before shooting (#321): the torches swing
	# slightly over 2x in energy on accumulated wall-clock time, so an unpinned
	# capture photographs whatever phase the frame pacing happened to land on.
	# Measured on unchanged main, consecutive runs: cave-walkout 16.8% -> 20.8%
	# of value range and cave-chamber 12.5% -> 14.1%, while every outdoor
	# vantage repeated exactly. A cave value delta under about 4pp was therefore
	# unfalsifiable — wider than the effects art PRs are asked to prove here.
	cave.freeze_flicker()

	var to_world := world.cave_to_world()
	var lay: Dictionary = cave.last_layout
	# Declare the derived cameras in the evidence log: fixed per committed
	# seed, so a coordinate delta between two runs means the WORLD moved — a
	# fact a reviewer should read off the log diff, not have to infer.
	for vantage: Array in cave_vantages(lay):
		var e := to_world * (vantage[1] as Vector3)
		var t := to_world * (vantage[2] as Vector3)
		print("CAVE VANTAGE %s: eye (%.2f, %.2f, %.2f) -> target (%.2f, %.2f, %.2f)" %
			[vantage[0], e.x, e.y, e.z, t.x, t.y, t.z])
	var captured := 0
	for vantage: Array in cave_vantages(lay):
		var vantage_name: String = vantage[0]
		var eye := to_world * (vantage[1] as Vector3)
		var target := to_world * (vantage[2] as Vector3)
		# The eye must still be inside the system's protected footprint: the
		# vantages and the footprint derive from the same layout, so a miss
		# here means the derivation went stale against the generator.
		if not world.cave_protects(eye.x, eye.z):
			_fail("vantage '%s': derived eye (%.1f, %.1f) is outside the cave footprint — the derivation went stale against the generator" %
				[vantage_name, eye.x, eye.z])
			return -1
		cam.global_position = eye
		cam.look_at(target, Vector3.UP)
		for i in SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame
		if not _sees_geometry(cam, target):
			_fail("vantage '%s' sees no geometry — the shot frames nothing" % vantage_name)
			return -1
		# Underground is the POINT. A cave camera the sky can see is a
		# mis-derivation whatever its frame looks like — outdoors this ray
		# reaches the sky and misses everything (the vantage test proves the
		# check falsifiable with an outdoor control).
		if not _under_rock(cam):
			_fail("vantage '%s' is not roofed by rock — the camera is not inside the cave" % vantage_name)
			return -1
		if (hull.layers & cam.cull_mask) == 0:
			_fail("vantage '%s': the cave hull's render layers are outside the camera's cull mask — it would not be drawn" % vantage_name)
			return -1
		await RenderingServer.frame_post_draw
		var img := get_viewport().get_texture().get_image()
		var spread := _luma_spread(img)
		if spread < CAVE_MIN_LUMA_SPREAD:
			_fail("vantage '%s' is a near-uniform frame (luma spread %.4f) — black cave or a camera inside rock" %
				[vantage_name, spread])
			return -1
		var out := "%s/%s.png" % [dir, vantage_name]
		var err := img.save_png(out)
		if err != OK:
			_fail("could not write %s (error %d)" % [out, err])
			return -1
		var cave_note := _size_note(img)
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
			[vantage_name, out, img.get_width(), img.get_height(), spread, cave_note])
		_write_note(dir, vantage_name, img, cave_note)
		captured += 1
	return captured


## Photographs the cave mouth from OUTSIDE and returns the number of frames
## written (or -1 after failing the run). See [method mouth_vantage] for why the
## composition needs its own frame; this is the capture half, and it is separate
## from [method _capture_cave] because every structural guard inverts: the
## camera must be UNROOFED rather than roofed, it stands in daylight so it is
## held to the outdoor luminance floor rather than the cave's, and the ground
## under it is the world's heightfield rather than a cave floor.
func _capture_mouth(cam: Camera3D, dir: String, main: Node) -> int:
	var world := main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("no WorldGen node named World — cannot derive the mouth vantage")
		return -1
	var cave := world.get_node_or_null("StarterCave") as CaveSystemGen
	if cave == null:
		_fail("no StarterCave under World — the entrance every player walks out of would go unphotographed")
		return -1
	# The torches are inside, but their light reaches OUT through the bore, and
	# the bore is the subject. An unpinned flicker therefore moves this frame
	# the same way it moved the cave frames before #321 — so pin it here rather
	# than inheriting whatever _capture_cave left behind. freeze_flicker() is
	# idempotent, so this neither depends on nor disturbs the call order.
	cave.freeze_flicker()

	var to_world := world.cave_to_world()
	var lay: Dictionary = cave.last_layout
	var vantage: Array = mouth_vantage(lay)
	var vantage_name: String = vantage[0]
	var eye := to_world * (vantage[1] as Vector3)
	var target := to_world * (vantage[2] as Vector3)

	# Stand the camera on the ground it is actually looking across. Outside the
	# massif that ground is the terrain, which the cave layout knows nothing
	# about: it sits 0.39 m below the mouth apron at this standoff and keeps
	# falling — 3.1 m by 16 m out — so a camera left at the nominal height would
	# float over the near ground, and would sink under a reshaped heightfield.
	var ground := world.surface_height_at(eye.x, eye.z)
	if ground <= WorldGen.NO_GROUND + 1.0:
		ground = world.height_at(eye.x, eye.z)
	eye.y = ground + MOUTH_EYE_HEIGHT
	# Declare it under the SAME marker as the interior cave vantages, not a
	# bespoke one. This is a derived cave camera by every part of that
	# definition — fixed per committed seed, moving only when the world moves —
	# and `AGENTS.md` tells a reviewer that such movement surfaces as a
	# `CAVE VANTAGE` coordinate delta in this log. A marker of its own would
	# leave this camera out of the set a reader following that instruction
	# collects, which is the one place a silent shift was meant to show up.
	# The ground it was seated on rides along, since that is what moves it.
	print("CAVE VANTAGE %s: eye (%.2f, %.2f, %.2f) -> target (%.2f, %.2f, %.2f), ground %.2f" %
		[vantage_name, eye.x, eye.y, eye.z, target.x, target.y, target.z, ground])

	cam.global_position = eye
	cam.look_at(target, Vector3.UP)
	for i in SETTLE_FRAMES:
		cam.current = true
		await get_tree().process_frame

	if not _sees_geometry(cam, target):
		_fail("vantage '%s' sees no geometry — the shot frames nothing" % vantage_name)
		return -1
	if not _camera_draws_world(cam, main):
		_fail("vantage '%s': the terrain's render layers are outside the camera's cull mask — it would not be drawn" % vantage_name)
		return -1
	# OUTSIDE is the point, and it is the one property that separates this frame
	# from `cave-walkout`. The cave path fails a camera the sky can see; this one
	# fails a camera it cannot — a vantage that drifted inside the bore would
	# still see geometry, still draw the world and still make a bright frame,
	# and would silently be the interior shot we already had.
	#
	# Inverting a predicate is how a guard goes vacuous, so note what stops it
	# here: _capture_cave has already REQUIRED this same call to answer true at
	# two interior vantages in this very run. A broken _under_rock that always
	# answered false would have failed there before reaching this line, so the
	# two directions hold each other up and neither can quietly pass on nothing.
	if _under_rock(cam):
		_fail("vantage '%s' is roofed by rock — the camera is inside the massif, so this is not the entrance seen from outside" % vantage_name)
		return -1

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var spread := _luma_spread(img)
	if spread < MIN_LUMA_SPREAD:
		_fail("vantage '%s' is a uniform frame (luma spread %.4f) — nothing rendered" %
			[vantage_name, spread])
		return -1
	var out := "%s/%s.png" % [dir, vantage_name]
	var err := img.save_png(out)
	if err != OK:
		_fail("could not write %s (error %d)" % [out, err])
		return -1
	var note := _size_note(img)
	print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
		[vantage_name, out, img.get_width(), img.get_height(), spread, note])
	_write_note(dir, vantage_name, img, note,
		String(world.region_name_at(cam.global_position.x, cam.global_position.z)))
	return 1


## The hull massif, found structurally: generated children carry
## auto-uniquified class-based names, so the hull is identified as the LARGEST
## direct mesh child — it spans the whole system (tens of metres) while the
## other direct mesh children (mouth jambs, flanking boulders) are slabs a few
## metres across.
func _cave_hull(cave: Node) -> MeshInstance3D:
	var best: MeshInstance3D = null
	var best_span := 0.0
	for child in cave.get_children():
		var mi := child as MeshInstance3D
		if mi == null or mi.mesh == null:
			continue
		var span := mi.mesh.get_aabb().get_longest_axis_size()
		if span > best_span:
			best_span = span
			best = mi
	return best


## Visible torch lights under the cave, counted with owned=false: generated
## nodes carry no scene owner, so the default find_children would see none.
func _visible_torch_light_count(cave: Node) -> int:
	var count := 0
	for node in cave.find_children("*", "OmniLight3D", true, false):
		if (node as OmniLight3D).is_visible_in_tree():
			count += 1
	return count


## Whether rock stands over the camera: an upward ray against the colliders.
## Inside the cave it hits the massif hull's trimesh; under open sky it hits
## nothing within range.
##
## Reaches exactly as far as the weather's own sky probes ([constant
## CaveAtmosphere.PROBE_HEIGHT]), so this guard and the ash agree on what "under
## rock" means. It stays a single CENTRE ray rather than deriving an answer from
## [method CaveAtmosphere.sky_blocked_fraction]: that returns how MUCH of the
## sky is covered across a 6 m disc, so it is non-zero whenever any probe in the
## cone is blocked — and a threshold on it would let this accept a vantage with
## open sky directly overhead because something clipped the edge of the disc.
func _under_rock(cam: Camera3D) -> bool:
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var query := PhysicsRayQueryParameters3D.create(
		from, from + Vector3.UP * CaveAtmosphere.PROBE_HEIGHT)
	query.collide_with_areas = false
	return not space.intersect_ray(query).is_empty()


## One real creator-authored state for every production-activated wardrobe
## region/layer. Registry slot order and kit layer order are the stable visual
## evidence order; pieces within one pair use the creator's sorted writer list.
## The first piece keeps the established region/layer frame name, while later
## pieces add their own name so activating a second option cannot overwrite the
## first one's evidence.
func outfit_capture_states(registry: Dictionary) -> Array[Dictionary]:
	var states: Array[Dictionary] = []
	for slot: String in CharacterCreator.pickable_regions(registry):
		for layer: String in CharacterCreator.pickable_layers(registry, slot):
			var pieces := CharacterCreator._pieces_in_slot(registry, slot, layer)
			for index in pieces.size():
				var piece_name := pieces[index]
				var shot_name := "first_run_%s_%s" % [slot, layer]
				if index > 0:
					shot_name += "_%s" % piece_name
				states.append({
					"slot": slot,
					"layer": layer,
					"piece": piece_name,
					"shot": shot_name,
				})
	return states


## The character creator as a new player meets it — the surface a first-run UI
## change actually alters, and the one the world scenario deliberately seeds away.
func _capture_first_run(dir: String, main: Node) -> void:
	for i in UI_WARMUP_FRAMES:
		await get_tree().process_frame

	# The creator must have OPENED. Without this the scenario degrades into an
	# ordinary world shot the moment a save leaks into the run — and a world shot
	# passes the luminance guard perfectly well, so nothing would complain while
	# the evidence stopped depicting the reviewed surface entirely.
	var creator := _find_creator(main)
	if creator == null:
		_fail("the character creator never opened — a save is present, so this is a world shot, not first-run evidence")
		return
	if not creator.visible:
		_fail("the character creator opened but is not visible — the frame would not show it")
		return
	# It must be the FIRST-RUN creator, not the manual reshape UI. main.gd opens
	# the same scene either way; the flag is the only thing that distinguishes
	# the forced new-player flow (no Cancel, no Esc) from the one a settled
	# player opens with C. Capturing the latter and calling it first-run
	# evidence would depict a screen no new player ever sees.
	if not (creator as CharacterCreator).first_run:
		_fail("the creator opened in reshape mode, not first-run mode — that is not the new-player screen")
		return
	# And its PANEL must be there and drawn. The creator is a CanvasLayer over
	# the live 3D scene, so a change that leaves the layer alive while removing
	# or hiding its controls yields a frame that is pure world — which sails
	# through the luminance check below on the scenery alone.
	if _visible_panel_area(creator) <= 0.0:
		_fail("the creator has no visible panel — the frame would be the world behind a transparent layer")
		return

	# One frame is not enough for what the gate triggers on. The panel places 29
	# shape sliders and six bone sliders above its outfit and skin sections, so
	# those controls sit BELOW THE FOLD; and the gate fires on any recipe, while
	# a single shot shows only the default one. Without these, a PR changing
	# brute.json or the skin picker gets a green capture whose frame does not
	# contain the surface it changed.
	if not await _shoot(dir, "first_run", creator):
		return
	var shots := 1

	var scroll := _find_scroll(creator)
	if scroll == null:
		_fail("the creator has no scroll container — the controls below the fold would go unphotographed")
		return
	# The hosted runner's 1024x576 viewport clips the final outfit row from the
	# default frame. Scroll the last wardrobe control into view and name this
	# evidence explicitly; a green capture may never omit the surface the PR
	# activates merely because a larger local display happened to show it.
	var bottom_outfit := _bottom_outfit_picker(creator as CharacterCreator)
	if bottom_outfit == null:
		_fail("the creator exposes no outfit control — the wardrobe writer has no visible evidence")
		return
	scroll.ensure_control_visible(bottom_outfit)
	for i in 2:
		await get_tree().process_frame
	var scroll_rect := scroll.get_global_rect()
	var outfit_rect := bottom_outfit.get_global_rect()
	if outfit_rect.position.y < scroll_rect.position.y \
			or outfit_rect.end.y > scroll_rect.end.y:
		_fail("the last outfit control remains clipped after scrolling — the wardrobe frame would not depict it")
		return
	if not await _shoot(dir, "first_run_outfit", creator):
		return
	shots += 1

	# A row of names is not frame evidence for the wearable meshes behind those
	# names. Drive the opted-in creator through every production-active
	# region/layer while its real control is visible. This includes the head pair
	# in layer order (eyewear, then the helm suppressing it) and the activated
	# hand armour; these are real player authoring calls, not meshes instanced
	# around the creator (#329, #653).
	if CharacterCreator.layered_outfit_pickers_enabled():
		var capture_player := creator.get("_player") as Player
		if capture_player == null:
			_fail("the first-run creator lost its player — cannot render the wardrobe evidence")
			return
		for state: Dictionary in outfit_capture_states(CharacterFactory.equipment_registry()):
			var slot := String(state["slot"])
			var layer := String(state["layer"])
			var slot_pickers: Variant = (creator.get("_outfit_pickers") as Dictionary).get(slot)
			if not (slot_pickers is Dictionary) or not (slot_pickers as Dictionary).has(layer):
				_fail("the opted-in creator has no %s %s control — cannot render its evidence"
					% [slot, layer])
				return
			creator.call("_set_recipe_equipment", slot, layer, state["piece"])
			capture_player.set_character(creator.get("_recipe"))
			creator.call("_sync_sliders_from_recipe")
			scroll.ensure_control_visible((slot_pickers as Dictionary)[layer] as Control)
			for i in UI_SETTLE_FRAMES:
				await get_tree().process_frame
			if not await _shoot(dir, state["shot"], creator):
				return
			shots += 1
	scroll.scroll_vertical = 0
	await get_tree().process_frame
	# The shaping controls now sit inside a section that is COLLAPSED by default
	# (the art direction demotes them below the named choices), so scrolling
	# alone would photograph a panel that never shows them. Open every section
	# first: the evidence has to depict the whole surface, including what the
	# default view folds away.
	creator.call("expand_all_sections")
	await get_tree().process_frame
	# `max_value` is the CONTENT extent, not the furthest scroll position: the bar
	# only travels to `max_value - page`. Comparing against max_value means the
	# walk never registers as having reached the bottom. (The old jump-to-max
	# worked only because assigning past the limit silently clamps to it.)
	var bar := scroll.get_v_scroll_bar()
	var limit := maxi(0, int(bar.max_value) - int(bar.page))
	if limit <= 0:
		_fail("the creator's control list did not scroll — its lower sections would go unphotographed")
		return

	# Walk the expanded list ONE VIEWPORT AT A TIME rather than jumping to the
	# bottom. Jumping straight to the end photographs only the tail: the default
	# frame above was taken with this section collapsed, so the controls near its
	# start (ARCHETYPE, HERITAGE, TORSO, LIMBS) would appear in NO frame at all,
	# and a regression to any of them would sail through this gate. The overlap
	# keeps a row from falling between two frames.
	var page := maxi(1, int(bar.page) - 40)
	var offset := 0
	var index := 0
	var reached_bottom := false
	while index < MAX_ADVANCED_VIEWPORTS:
		scroll.scroll_vertical = offset
		await get_tree().process_frame
		var at := scroll.scroll_vertical
		index += 1
		# The bottom frame keeps its established name so anything reading the
		# capture set by name still finds it.
		var shot_name := "first_run_lower" if at >= limit else "first_run_advanced_%d" % index
		if not await _shoot(dir, shot_name, creator):
			return
		shots += 1
		if at >= limit:
			reached_bottom = true
			break
		var next := at + page
		if next <= at:
			_fail("the creator's control list stopped advancing at %d of %d — the rest would go unphotographed" % [at, limit])
			return
		offset = next
	# Running out of steps is a FAILURE, never a quiet stop. A silent cap here
	# would report CAPTURE PASS having never photographed the bottom of the list,
	# which is precisely the blind spot this walk exists to close.
	if not reached_bottom:
		_fail("the control list needed more than %d viewports to reach its end (stopped at %d of %d) — the rest would go unphotographed"
			% [MAX_ADVANCED_VIEWPORTS, offset, limit])
		return
	scroll.scroll_vertical = 0

	# Every preset the creator offers, because the gate fires on any recipe
	# change while only the default one is otherwise on screen.
	for preset: String in CharacterCreator.PRESETS:
		creator.call("_on_preset", preset)
		for i in UI_SETTLE_FRAMES:
			await get_tree().process_frame
		if not await _shoot(dir, "first_run_%s" % preset, creator):
			return
		shots += 1

	# The base garment is intentionally UNDER every recipe-selected piece. The
	# four shipped presets all wear trousers, so their frames can prove fit but
	# cannot prove what remains when the wardrobe is emptied. Drive the same
	# first-run creator through its real equipment-editing seam and capture that
	# state explicitly; a hidden, missing, or removable base can no longer pass
	# behind an opaque pair of trousers.
	creator.call("_on_preset", "brute")
	for slot: String in CharacterCreator.pickable_regions(CharacterFactory.equipment_registry()):
		for layer: String in CharacterCreator.pickable_layers(
				CharacterFactory.equipment_registry(), slot):
			creator.call("_set_recipe_equipment", slot, layer, "")
	var capture_player := creator.get("_player") as Player
	if capture_player == null:
		_fail("the first-run creator lost its player — cannot render the empty-wardrobe base layer")
		return
	capture_player.set_character(creator.get("_recipe"))
	creator.call("_sync_sliders_from_recipe")
	for i in UI_SETTLE_FRAMES:
		await get_tree().process_frame
	if not await _shoot(dir, "first_run_base_layer", creator):
		return
	shots += 1

	print("CAPTURE PASS — %d first-run vantages written to %s" % [shots, dir])
	get_tree().quit(0)


## The `breath` scenario: a phase sequence of one standing body, because a
## STILL CANNOT SHOW AN IDLE (#243).
##
## The world scenario photographs one instant, which is the right evidence for
## a material or a composition and useless for motion — a reviewer looking at
## it cannot tell a breathing character from a frozen one. This walks one body
## through fixed phases of the breath and writes a frame at each, so the
## sequence itself is the evidence.
##
## Phases are DRIVEN, never observed: the idle node is stopped and
## `BreathingIdle.apply_at` is called at chosen times. Watching the node's own
## clock would make the frames depend on how fast the runner happened to render,
## so two runs would photograph different moments and nothing would be
## comparable across PRs — the property the fixed VANTAGES exist to protect.
##
## A NPC by the shrine is framed rather than the wanderer, who wakes in the
## cave where torchlight and deep shadow would hide millimetre movement.
func _capture_breath(dir: String, main: Node) -> void:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build — a sky-only frame is not evidence")
		return

	# Refuse to photograph the subject through the character creator.
	#
	# With no save present the first-run creator opens and its panel covers a
	# third of the frame. That is a CALLER mistake — an unseeded WAR_SAVE_PATH —
	# but it degrades the evidence SILENTLY: the body stays partly visible,
	# every luma and travel guard still passes, and the artifact comes back with
	# a UI panel across the subject. CI shipped exactly that once, and the only
	# thing that caught it was a human opening the PNG. Fail loudly instead, and
	# name the cause rather than the symptom.
	var creator := _find_creator(main)
	if creator != null and _visible_panel_area(creator) > 0.0:
		_fail("the first-run creator is open over the subject — WAR_SAVE_PATH must point at a SEEDED save (copy client/recipes/wanderer.json), or the frames photograph the UI instead of the body")
		return

	var body := _first_breathing_body(main)
	if body == null:
		_fail("no character with a BreathingIdle was found in the shipped scene — either nothing breathes, or the idle is not attached where a player would see it")
		return
	var skeleton: Skeleton3D = CharacterFactory.find_skeleton(body)
	var idle: Node = body.get_node_or_null("BreathingIdle")
	# Stop the node driving itself, or the next frame overwrites every phase we
	# set and the sequence photographs the runner's clock instead.
	idle.set_process(false)

	var chest := skeleton.find_bone("spine_03")
	var focus: Vector3 = skeleton.get_bone_global_pose(chest).origin
	focus = skeleton.global_transform * focus
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 40.0
	get_tree().root.add_child(cam)
	# Three-quarter front, chest height, close: the breath is ~10 mm of
	# shoulder travel, so a wide world vantage would render it sub-pixel.
	cam.global_position = focus + Vector3(BREATH_CAM_SIDE, BREATH_CAM_RISE, BREATH_CAM_FRONT)
	cam.look_at(focus, Vector3.UP)

	var shoulder := skeleton.find_bone("upperarm_l")
	var clavicle := skeleton.find_bone("clavicle_l")
	var poses: Array[Vector3] = []
	var breath_rotations: Array[Quaternion] = []
	var frames: Array[Image] = []
	for i in BREATH_PHASES:
		# HALF-STEP OFFSET, and it is load-bearing. On a plain i/N sampling the
		# breath is a sine zero-crossing at BOTH i=0 and i=N/2, so the sequence
		# never photographs an inhale or an exhale — it samples the two moments
		# where the chest is doing nothing. With the offset, i=N/4 is peak
		# inhale and i=3N/4 peak exhale.
		var t := BreathingIdle.BREATH_PERIOD * (float(i) + 0.5) / float(BREATH_PHASES)
		BreathingIdle.apply_at(skeleton, t)
		skeleton.force_update_all_bone_transforms()
		poses.append(skeleton.get_bone_global_pose(shoulder).origin)
		# The clavicle's LOCAL pose rotation is driven by the breath channel and
		# nothing else. The pelvis shift moves the clavicle's GLOBAL transform
		# through the chain, so only the local rotation isolates the breath.
		breath_rotations.append(skeleton.get_bone_pose_rotation(clavicle))
		for _s in BREATH_SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame
		var img := await _grab_frame()
		var spread := _luma_spread(img)
		if spread < MIN_LUMA_SPREAD:
			_fail("breath phase %d is a uniform frame (luma spread %.4f) — nothing rendered" % [i, spread])
			return
		var frame_name := "breath_%02d" % i
		var err := img.save_png("%s/%s.png" % [dir, frame_name])
		if err != OK:
			_fail("could not write %s (error %d)" % [frame_name, err])
			return
		_write_note(dir, frame_name, img, _size_note(img))
		frames.append(img)
		print("CAPTURED %s (phase %.2fs of %.2fs)" % [frame_name, t, BreathingIdle.BREATH_PERIOD])

	# 🔑 THE GUARD THAT MAKES THIS EVIDENCE RATHER THAN DECORATION.
	#
	# Every check above passes a sequence of IDENTICAL frames: a body whose
	# idle silently stopped still renders, still has luma spread, and still
	# writes N files — #231's shape exactly, an evidence job going green while
	# the thing it evidences is absent. So the sequence must be shown to depict
	# genuinely different poses.
	#
	# ⚠️ IT IS NOT A PIXEL COMPARISON, AND THAT IS A MEASURED DECISION, not a
	# shortcut. The obvious guard — "opposite phases must differ" — was built
	# first and PROVED VACUOUS: with the idle forced to produce no motion at
	# all, opposite phases still differed by a max pixel delta of 0.32, because
	# this scene is never still (temporal antialiasing jitters every edge,
	# foliage sways, fog drifts, torches flicker). Adding a same-phase control
	# frame and counting changed pixels instead of taking a max narrowed it but
	# did not save it: the real idle scored 2534 changed pixels against 1926
	# for two shots of the SAME pose — a 1.3x margin, far too thin to gate on.
	# Any threshold that passed the real idle would also have passed a frozen
	# body, so tuning one would have been fitting the guard to the answer.
	#
	# What IS reliable is the pose the frames were taken at. If the idle stops,
	# every phase renders the same skeleton, and that is exactly detectable.
	# The frames remain the human-inspectable evidence; this is the machine
	# guard that they depict a body in different positions.
	var inhale := int(round(float(BREATH_PHASES) * 0.25 - 0.5))
	var exhale := int(round(float(BREATH_PHASES) * 0.75 - 0.5))
	var travel := (poses[inhale] - poses[exhale]).length()
	if travel < BREATH_MIN_TRAVEL_M:
		_fail(("the breath sequence photographs one pose: the shoulder moved %.5f m between the inhale " +
			"and the exhale, under the %.5f m floor. The frames would show a frozen body.") %
			[travel, BREATH_MIN_TRAVEL_M])
		return

	# ⚠️ AND THE BREATH SPECIFICALLY, not merely "the body moved somewhere".
	#
	# The idle has two independent channels, and the slow pelvis weight shift
	# moves the shoulder several millimetres on its own. So a travel check alone
	# passes a build whose entire breathing is deleted, as long as the weight
	# shift survives — the sequence would advertise a breath that is not there.
	# The clavicle's LOCAL pose rotation comes only from the breath channel, so
	# it is the one measurement the pelvis cannot fake.
	var breath_swing := rad_to_deg(breath_rotations[inhale].angle_to(breath_rotations[exhale]))
	if breath_swing < BREATH_MIN_SWING_DEG:
		_fail(("the body moves but does not BREATHE: the clavicle turned %.3f deg between inhale and " +
			"exhale, under the %.3f deg floor. The weight shift alone can satisfy the travel check, " +
			"so this is the measurement that proves a breath was photographed.") %
			[breath_swing, BREATH_MIN_SWING_DEG])
		return

	print("CAPTURE PASS — %d breath phases written to %s (shoulder travel %.1f mm, breath swing %.2f deg)" %
		[BREATH_PHASES, dir, travel * 1000.0, breath_swing])
	get_tree().quit(0)


## The `walk` and `run` scenarios: a fixed-phase full-body sequence of the REAL
## wanderer, in whichever grounded gait `running` selects.
##
## One function rather than two: the vantage, framing, settling, uniform-frame
## rejection and foot-travel floor are identical for both gaits, and the only
## real difference is which pose the shipping driver is asked for. A copied
## second capture would drift from this one the first time either is retuned.
##
## Each gait has its OWN opt-in, and the flag is read when Player binds its
## recipe body — so the caller must export the flag for the gait it wants
## before this scene boots: `WAR_WALK_CYCLE=1` for `walk`, `WAR_RUN_CYCLE=1`
## for `run`. Setting the wrong one is refused below rather than quietly
## photographing a standing body. The runtime driver is then stopped with
## Player physics, and its own `apply_phase` method poses the sequence
## deterministically — the evidence uses the shipping implementation, not a
## preview copy.
func _capture_gait(dir: String, main: Node, running: bool) -> void:
	var gait := "run" if running else "walk"
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build — a sky-only %s sequence is not evidence" % gait)
		return

	var player := main.get_node_or_null("Wanderer") as Player
	if player == null:
		_fail("the shipped scene has no Wanderer Player — the %s path is not live" % gait)
		return
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null:
		_fail("the shipped Wanderer has no WalkLocomotion driver")
		return
	# Each gait has its own opt-in, so the evidence must demand the flag for the
	# gait it is photographing — checking the walk's flag while capturing the run
	# would publish a standing body as a run sequence.
	var gait_flag := WalkLocomotion.RUN_FLAG_ENV if running else WalkLocomotion.FLAG_ENV
	if OS.get_environment(gait_flag) != "1":
		_fail("%s is not opted in — refusing to advertise a disabled gait" % gait_flag)
		return
	var world := main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("the shipped scene has no WorldGen for the daylight walk vantage")
		return

	# Hold translation and input fixed while the exact phases are driven. The
	# body stands on open ground south of the shrine rather than in the
	# starter cave, so daylight reaches it without the shrine pillar occluding
	# the full silhouette.
	player.set_physics_process(false)
	player.control_enabled = false
	var walk_ground := world.surface_height_at(0.0, WALK_VANTAGE_Z)
	if walk_ground <= WorldGen.NO_GROUND + 1.0:
		_fail("the committed walk vantage has no terrain under it")
		return
	player.global_position = Vector3(0.0, walk_ground + 0.1, WALK_VANTAGE_Z)
	player.face_toward(Vector3.ZERO)
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	if skeleton == null:
		_fail("the shipped Wanderer has no recipe skeleton")
		return

	# Keep the independently-running breath on one deterministic phase. Without
	# this, frame-to-frame chest motion is legitimate but makes the walk
	# sequence depend on runner speed.
	var body := skeleton.get_parent()
	var idle := body.get_node_or_null("BreathingIdle") if body != null else null
	if idle != null:
		idle.set_process(false)
		BreathingIdle.apply_at(skeleton, 0.0)

	skeleton.force_update_all_bone_transforms()
	var chest := skeleton.find_bone("spine_03")
	var left_foot := skeleton.find_bone("foot_l")
	if chest < 0 or left_foot < 0:
		_fail("the walk evidence rig lacks spine_03 or foot_l")
		return
	var focus: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(chest).origin
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 42.0
	get_tree().root.add_child(cam)
	cam.global_position = focus + Vector3(WALK_CAM_SIDE, WALK_CAM_RISE, -WALK_CAM_FRONT)
	cam.look_at(focus - Vector3(0.0, 0.45, 0.0), Vector3.UP)

	var foot_positions: Array[Vector3] = []
	for i in WALK_PHASES:
		var phase := TAU * float(i) / float(WALK_PHASES)
		animator.call("apply_phase", phase, running)
		skeleton.force_update_all_bone_transforms()
		foot_positions.append(
			skeleton.global_transform * skeleton.get_bone_global_pose(left_foot).origin)
		for _s in WALK_SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame
		var img := await _grab_frame()
		var spread := _luma_spread(img)
		if spread < MIN_LUMA_SPREAD:
			_fail("%s phase %d is a uniform frame (luma spread %.4f) — nothing rendered" %
				[gait, i, spread])
			return
		var frame_name := "%s_%02d" % [gait, i]
		var err := img.save_png("%s/%s.png" % [dir, frame_name])
		if err != OK:
			_fail("could not write %s (error %d)" % [frame_name, err])
			return
		_write_note(dir, frame_name, img, _size_note(img))
		print("CAPTURED %s (phase %.3f rad)" % [frame_name, phase])

	var travel := 0.0
	for a in foot_positions:
		for b in foot_positions:
			travel = maxf(travel, a.distance_to(b))
	if travel < WALK_MIN_FOOT_TRAVEL_M:
		_fail(("the %s sequence photographs one lower-body pose: the left foot travels %.4f m, " +
			"under the %.4f m floor") % [gait, travel, WALK_MIN_FOOT_TRAVEL_M])
		return

	print("CAPTURE PASS — %d %s phases written to %s (left-foot travel %.1f cm)" %
		[WALK_PHASES, gait, dir, travel * 100.0])
	get_tree().quit(0)


## The `gait_transition` scenario: a real runtime sprint press and release.
##
## Fixed-phase walk/run captures prove the settled endpoints and cannot show
## the input edge #496 fixes. This sequence instead drives
## [method WalkLocomotion.advance_motion] with both existing opt-ins enabled,
## using deterministic deltas that span the complete transition in each
## direction. Physics is paused only after the shipped player has booted.
func _capture_gait_transition(dir: String, main: Node) -> void:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build — a sky-only gait transition is not evidence")
		return

	var player := main.get_node_or_null("Wanderer") as Player
	if player == null:
		_fail("the shipped scene has no Wanderer Player — the gait path is not live")
		return
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null or not animator.has_method("advance_motion"):
		_fail("the shipped Wanderer has no runtime locomotion driver")
		return
	for gait_flag: String in [
		WalkLocomotion.FLAG_ENV,
		WalkLocomotion.RUN_FLAG_ENV,
	]:
		if OS.get_environment(gait_flag) != "1":
			_fail("%s is not opted in — refusing a partial gait transition" % gait_flag)
			return
	var world := main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("the shipped scene has no WorldGen for the gait-transition vantage")
		return

	player.set_physics_process(false)
	player.control_enabled = false
	var ground := world.surface_height_at(0.0, WALK_VANTAGE_Z)
	if ground <= WorldGen.NO_GROUND + 1.0:
		_fail("the committed gait-transition vantage has no terrain under it")
		return
	player.global_position = Vector3(0.0, ground + 0.1, WALK_VANTAGE_Z)
	player.face_toward(Vector3.ZERO)
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	if skeleton == null:
		_fail("the shipped Wanderer has no recipe skeleton")
		return

	var body := skeleton.get_parent()
	var idle := body.get_node_or_null("BreathingIdle") if body != null else null
	if idle != null:
		idle.set_process(false)
		BreathingIdle.apply_at(skeleton, 0.0)

	skeleton.force_update_all_bone_transforms()
	var chest := skeleton.find_bone("spine_03")
	var left_foot := skeleton.find_bone("foot_l")
	if chest < 0 or left_foot < 0:
		_fail("the gait-transition evidence rig lacks spine_03 or foot_l")
		return
	var focus: Vector3 = (
		skeleton.global_transform * skeleton.get_bone_global_pose(chest).origin
	)
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 42.0
	get_tree().root.add_child(cam)
	cam.global_position = (
		focus + Vector3(WALK_CAM_SIDE, WALK_CAM_RISE, -WALK_CAM_FRONT)
	)
	cam.look_at(focus - Vector3(0.0, 0.45, 0.0), Vector3.UP)

	var samples: Array[Dictionary] = [{
		"event": "walk",
		"sprinting": false,
		"delta": 0.0,
		"step": 0,
	}]
	for step in range(1, GAIT_TRANSITION_STEPS + 1):
		samples.append({
			"event": "press",
			"sprinting": true,
			"delta": GAIT_TRANSITION_DELTA,
			"step": step,
		})
	for step in range(1, GAIT_TRANSITION_STEPS + 1):
		samples.append({
			"event": "release",
			"sprinting": false,
			"delta": GAIT_TRANSITION_DELTA,
			"step": step,
		})

	var foot_positions: Array[Vector3] = []
	for i in samples.size():
		var sample: Dictionary = samples[i]
		var sprinting: bool = sample["sprinting"]
		var speed := Player.SPRINT_SPEED if sprinting else Player.WALK_SPEED
		animator.call(
			"advance_motion",
			speed,
			true,
			sprinting,
			sample["delta"])
		skeleton.force_update_all_bone_transforms()
		foot_positions.append(
			skeleton.global_transform * skeleton.get_bone_global_pose(left_foot).origin)
		for _settle in WALK_SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame
		var img := await _grab_frame()
		var spread := _luma_spread(img)
		if spread < MIN_LUMA_SPREAD:
			_fail(("gait transition frame %d is uniform (luma spread %.4f) — " +
				"nothing rendered") % [i, spread])
			return
		var frame_name := "gait_transition_%02d_%s_%02d" % [
			i,
			sample["event"],
			sample["step"],
		]
		var err := img.save_png("%s/%s.png" % [dir, frame_name])
		if err != OK:
			_fail("could not write %s (error %d)" % [frame_name, err])
			return
		_write_note(dir, frame_name, img, _size_note(img), "", [
			"input: %s" % sample["event"],
			"transition step: %d/%d" % [
				sample["step"],
				GAIT_TRANSITION_STEPS,
			],
			"reference: %s" % GAIT_TRANSITION_REFERENCE,
			"remaining gap: %s" % GAIT_TRANSITION_REMAINING_GAP,
		])
		print("CAPTURED %s" % frame_name)

	var travel := 0.0
	for a in foot_positions:
		for b in foot_positions:
			travel = maxf(travel, a.distance_to(b))
	if travel < WALK_MIN_FOOT_TRAVEL_M:
		_fail(("the gait transition photographs one lower-body pose: the left foot " +
			"travels %.4f m, under the %.4f m floor") %
			[travel, WALK_MIN_FOOT_TRAVEL_M])
		return

	print(("CAPTURE PASS — %d gait transition frames written to %s " +
		"(left-foot travel %.1f cm)") %
		[samples.size(), dir, travel * 100.0])
	get_tree().quit(0)


## The `jump` scenario: a fixed-velocity full-body sequence of the REAL
## wanderer on open daylight ground. Player physics is paused only after the
## production scene has built and bound its recipe body; each frame then calls
## the shipping driver's exact [method WalkLocomotion.apply_jump] seam.
##
## This is intentionally separate from the grounded gait loop. A jump advances
## from vertical velocity rather than a periodic phase, and describing it as a
## gait would make it too easy for future capture cleanup to erase that
## behavioral distinction.
func _capture_jump(dir: String, main: Node) -> void:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build — a sky-only jump sequence is not evidence")
		return

	var player := main.get_node_or_null("Wanderer") as Player
	if player == null:
		_fail("the shipped scene has no Wanderer Player — the jump path is not live")
		return
	var animator := player.get_node_or_null("WalkLocomotion")
	if animator == null or not animator.has_method("apply_jump"):
		_fail("the shipped Wanderer has no exact jump-pose seam")
		return
	var world := main.get_node_or_null("World") as WorldGen
	if world == null:
		_fail("the shipped scene has no WorldGen for the daylight jump vantage")
		return

	player.set_physics_process(false)
	player.control_enabled = false
	var ground := world.surface_height_at(0.0, WALK_VANTAGE_Z)
	if ground <= WorldGen.NO_GROUND + 1.0:
		_fail("the committed jump vantage has no terrain under it")
		return
	player.global_position = Vector3(0.0, ground + 0.1, WALK_VANTAGE_Z)
	player.face_toward(Vector3.ZERO)
	var skeleton := CharacterFactory.find_skeleton(player.get_node("Visual"))
	if skeleton == null:
		_fail("the shipped Wanderer has no recipe skeleton")
		return

	var body := skeleton.get_parent()
	var idle := body.get_node_or_null("BreathingIdle") if body != null else null
	if idle != null:
		idle.set_process(false)
		BreathingIdle.apply_at(skeleton, 0.0)

	skeleton.force_update_all_bone_transforms()
	var chest := skeleton.find_bone("spine_03")
	var left_foot := skeleton.find_bone("foot_l")
	if chest < 0 or left_foot < 0:
		_fail("the jump evidence rig lacks spine_03 or foot_l")
		return
	var focus: Vector3 = skeleton.global_transform * skeleton.get_bone_global_pose(chest).origin
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 42.0
	get_tree().root.add_child(cam)
	cam.global_position = focus + Vector3(WALK_CAM_SIDE, WALK_CAM_RISE, -WALK_CAM_FRONT)
	cam.look_at(focus - Vector3(0.0, 0.45, 0.0), Vector3.UP)

	var foot_positions: Array[Vector3] = []
	for i in JUMP_SPEEDS.size():
		var speed: float = JUMP_SPEEDS[i]
		animator.call("apply_jump", speed)
		skeleton.force_update_all_bone_transforms()
		foot_positions.append(
			skeleton.global_transform * skeleton.get_bone_global_pose(left_foot).origin)
		for _s in JUMP_SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame
		var img := await _grab_frame()
		var spread := _luma_spread(img)
		if spread < MIN_LUMA_SPREAD:
			_fail("jump phase %d is a uniform frame (luma spread %.4f) — nothing rendered" %
				[i, spread])
			return
		var frame_name := "jump_%02d_%s" % [i, JUMP_LABELS[i]]
		var err := img.save_png("%s/%s.png" % [dir, frame_name])
		if err != OK:
			_fail("could not write %s (error %d)" % [frame_name, err])
			return
		_write_note(dir, frame_name, img, _size_note(img))
		print("CAPTURED %s (vertical speed %.1f m/s)" % [frame_name, speed])

	var travel := 0.0
	for a in foot_positions:
		for b in foot_positions:
			travel = maxf(travel, a.distance_to(b))
	if travel < JUMP_MIN_FOOT_TRAVEL_M:
		_fail(("the jump sequence photographs one lower-body pose: the left foot travels %.4f m, " +
			"under the %.4f m floor") % [travel, JUMP_MIN_FOOT_TRAVEL_M])
		return

	print("CAPTURE PASS — %d jump phases written to %s (left-foot travel %.1f cm)" %
		[JUMP_SPEEDS.size(), dir, travel * 100.0])
	get_tree().quit(0)


## Point the zone seam at a URL nothing can answer, with NO token.
##
## Must run before main.gd's `_ready`, because `_connect_zone()` reads these
## once at boot and returns immediately when no zone is configured — so setting
## them any later leaves `_zone` null and the whole scenario without the shipped
## wiring it exists to photograph.
##
## The token is forced EMPTY deliberately. `ZoneConnection.connect_to` refuses a
## missing token before it constructs a transport, so the capture cannot open a
## socket, cannot resolve a name, and cannot depend on a network at all — which
## is what makes this scenario runnable on any runner. It is also OVERWRITING,
## not defaulting: an operator with a real zone in their environment would
## otherwise have this capture reach for their live server.
func _arm_replication_seam() -> void:
	OS.set_environment(ZoneConnection.ZONE_URL_ENV, REPLICATION_ZONE_URL)
	OS.set_environment(ZoneConnection.ZONE_TOKEN_ENV, "")


## The `replication` scenario: photograph a deterministic replicated population,
## with NO zone server anywhere (#325).
##
## Every other capture boots the client with no zone, so `ReplicaStore` stays
## empty, `ReplicaView` correctly draws nothing, and the published frames are
## byte-comparable to a build without replication. A reviewer of any
## replication-visual change — remote appearance, interpolation, nameplates,
## culling — therefore receives evidence that structurally cannot contain the
## thing under review. That is #231's failure shape gated by CONFIGURATION
## rather than by hardware, and this scenario is the answer to it.
##
## The population enters through the SHIPPED path: main.gd's own
## `_connect_zone()` built the view and the store, `ReplicaStore.apply` folds
## the fixture exactly as it folds a decoded frame, and main.gd's `_process`
## calls `ReplicaView.sync`. Only the socket is absent, and its absence is
## asserted rather than assumed.
##
## Run:
##   WAR_SCENARIO=replication WAR_SHOT_DIR=/tmp/replication \
##     WAR_SAVE_PATH=/tmp/probe_save.json WAR_VAULT_PATH=/tmp/probe_vault.json \
##     WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client res://tools/frame_capture.tscn
func _capture_replication(dir: String, main: Node) -> void:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build (no Terrain under World) — a sky-only frame is not evidence")
		return

	# The SHIPPED wiring, not a harness copy. If either of these is missing the
	# scenario has nothing to prove: markers drawn by the tool itself would
	# evidence the tool, not the game.
	var zone: ZoneConnection = main.get("_zone")
	if zone == null:
		_fail(("main.gd built no zone connection even though the capture set %s — the shipped " +
			"_connect_zone() path did not run, so these frames could not contain a replicated entity") %
			ZoneConnection.ZONE_URL_ENV)
		return
	var view := main.get_node_or_null("Replicas") as ReplicaView
	if view == null:
		_fail("the shipped scene has no Replicas view under Main — nothing would draw the replicated table")
		return

	# 🔑 NO SERVER WAS CONTACTED, and it is proved rather than promised. The
	# refusal must be the TOKEN one specifically: any other terminal state means
	# the connection got further than the credential check, i.e. this capture
	# tried to reach the network — which would make it flake on an offline
	# runner and, worse, could point a CI job at whatever host resolved.
	if zone.state() != ZoneConnection.State.FAILED or zone.error() != ZoneConnection.ERR_TOKEN:
		_fail(("the zone connection did not stop at the credential check (state %d, error '%s') — this " +
			"capture must never open a socket, so the population is refused rather than photographed " +
			"against an unknown network state") % [zone.state(), zone.error()])
		return

	var fixture := _load_replication_fixture()
	if fixture.is_empty():
		return
	var entities: Array = fixture["entities"]

	# Folded by the REAL store, which validates the frame whole: a fixture that
	# named the observer, repeated an id or exceeded the wire's cap is refused
	# here exactly as a bad frame off the socket would be.
	var applied: Dictionary = zone.store().apply({
		"ok": true,
		"kind": WireCodec.KIND_SNAPSHOT,
		"snapshot": fixture,
	})
	if applied.get("ok") != true:
		_fail("the committed replication fixture was refused by the store (%s: %s)" %
			[str(applied.get("error")), str(applied.get("detail"))])
		return

	var centroid := Vector3.ZERO
	for e_var: Variant in entities:
		var e: Dictionary = e_var
		centroid += Vector3(float(e["x"]), float(e["y"]), float(e["z"])) / ReplicaView.MM_PER_M
	centroid /= float(entities.size())

	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 55.0
	get_tree().root.add_child(cam)
	cam.global_position = centroid + REPLICATION_CAM_OFFSET
	cam.look_at(Vector3(centroid.x, centroid.y + REPLICATION_LOOK_HEIGHT_M, centroid.z), Vector3.UP)
	for i in SETTLE_FRAMES:
		# Re-assert every frame: the player's own camera can otherwise take back
		# `current` and we would silently capture the wrong view.
		cam.current = true
		await get_tree().process_frame

	if view.count() != entities.size():
		_fail(("the view holds %d markers for a %d-entity fixture — the shipped per-frame sync did not " +
			"put the folded table on screen") % [view.count(), entities.size()])
		return
	if not _replicas_are_framed(cam, view, entities):
		return

	# Designated while the population is ON SCREEN, because these are the pixels
	# the verdict is about. Taken once and reused for both comparisons, so the
	# noise reference and the signal are measured at identical points.
	var points := _designate_replica_points(cam, view, entities)

	var populated := await _grab_frame()
	var spread := _luma_spread(populated)
	if spread < MIN_LUMA_SPREAD:
		_fail("the replication frame is uniform (luma spread %.4f) — nothing rendered" % spread)
		return
	if not _write_frame(dir, "replication_populated", populated):
		return

	# The noise reference: the SAME state, the same gap later. Two shots of one
	# scene are never identical here — temporal antialiasing jitters every edge,
	# foliage sways, fog reprojects — so this measures the drift the verdict
	# below has to see past, in this run, on this machine. A committed floor
	# alone would be a constant fitted to whatever machine authored it.
	for i in CONTRIB_GAP_FRAMES:
		cam.current = true
		await get_tree().process_frame
	var populated_again := await _grab_frame()

	# The control. A resync snapshot with no entities is the store's own
	# wholesale-replacement semantics, so the table empties through the same
	# path a server resync would use rather than through a test-only reset.
	var cleared: Dictionary = zone.store().apply({
		"ok": true,
		"kind": WireCodec.KIND_SNAPSHOT,
		"snapshot": {"tick": int(fixture["tick"]) + 1, "observer": int(fixture["observer"]), "entities": []},
	})
	if cleared.get("ok") != true:
		_fail("the empty control snapshot was refused by the store (%s: %s)" %
			[str(cleared.get("error")), str(cleared.get("detail"))])
		return
	for i in CONTRIB_GAP_FRAMES:
		cam.current = true
		await get_tree().process_frame
	if view.count() != 0:
		_fail(("the control still draws %d markers after an empty resync — it is not a control, and the " +
			"comparison below would be measuring nothing") % view.count())
		return
	var empty := await _grab_frame()
	if not _write_frame(dir, "replication_empty", empty):
		return

	# 🔑 THE GUARD THAT MAKES THIS EVIDENCE RATHER THAN DECORATION.
	#
	# Everything above passes a build whose markers render as nothing at all: a
	# material discarding every fragment, a mesh with zero extent, a shader that
	# failed to compile. The view would still hold N nodes, the frustum checks
	# would still place them on screen, and the capture would still publish two
	# PNGs — while the population contributed no pixels. So the population must
	# be shown to have changed the pixels it covers, against the drift measured
	# moments ago in the same run at those same points.
	var verdict := contribution_verdict(points, populated, populated_again, empty,
		"on-capsule marker", "removing the replicated population")
	if not bool(verdict["ok"]):
		_fail("%s — the markers are in the tree and in front of the camera, so these frames depict the same world with and without them" %
			str(verdict["reason"]))
		return

	# Reported, never gated: the whole-frame figure is what a reviewer sees in
	# the change report, and it is useful context — but it is drift-dominated
	# here, which is exactly why the verdict above is sampled instead.
	var whole_frame: Dictionary = FrameDiff.compare_images(empty, populated)
	var whole_drift: Dictionary = FrameDiff.compare_images(populated, populated_again)

	print(ReplicaView.marker(entities.size()))
	print(("CAPTURE PASS — %d replicated entities written to %s (%.0f%% of %d quiet on-capsule samples " +
		"changed, median %.3f; whole frame moved %.3f%% against %.3f%% drift; luma spread %.3f)") %
		[entities.size(), dir, float(verdict["fraction"]) * 100.0, int(verdict["quiet"]),
		float(verdict["median_change"]),
		float(whole_frame.get("changed_fraction", 0.0)) * 100.0,
		float(whole_drift.get("changed_fraction", 0.0)) * 100.0, spread])
	get_tree().quit(0)


## The `mob_chase` scenario: a fixed-camera motion sequence sourced from the
## authoritative Go tick and wire encoder, then folded through ZoneConnection
## before the shipped ReplicaView draws it (#357).
##
## The ordinary replication capture proves a static committed population
## contributes pixels. This sequence proves the moving behavior reaches the
## same render path: four approach states close monotonically, the cast-start
## state lands inside the configured capsule-surface range, and two later
## authoritative ticks hold the identical position. The fixture's zero-speed
## stationary control remains beside the sequence as the pre-retirement
## baseline without preserving a runtime feature flag.
func _capture_mob_chase(dir: String, main: Node) -> void:
	for i in WARMUP_FRAMES:
		await get_tree().process_frame
	if not _has_world(main):
		_fail("the world did not build (no Terrain under World) — a sky-only chase sequence is not evidence")
		return

	var refused_zone: ZoneConnection = main.get("_zone")
	var view := main.get_node_or_null("Replicas") as ReplicaView
	if refused_zone == null or view == null:
		_fail("the shipped Main scene did not build its zone connection and Replicas view")
		return
	if refused_zone.state() != ZoneConnection.State.FAILED or refused_zone.error() != ZoneConnection.ERR_TOKEN:
		_fail("mob-chase capture did not stop the boot connection at the credential boundary")
		return

	var replay := MobChaseReplay.new()
	if not replay.is_valid():
		_fail("authoritative mob-chase fixture was refused: %s" % replay.error_detail())
		return
	if not replay.start():
		_fail("authoritative mob-chase replay could not start: %s" % replay.error_detail())
		return
	main.set("_zone", replay.connection())
	main.set("_zone_failure_reported", false)
	main.set("_zone_was_live", true)

	var first_mob := replay.first_mob_state()
	var first_target := replay.first_target_state()
	if first_mob.is_empty() or first_target.is_empty():
		_fail("authoritative mob-chase fixture has no first mob/target state")
		return
	var centroid := Vector3(
		(float(first_mob["x"]) + float(first_target["x"])) * 0.5 / ReplicaView.MM_PER_M,
		(float(first_mob["y"]) + float(first_target["y"])) * 0.5 / ReplicaView.MM_PER_M,
		(float(first_mob["z"]) + float(first_target["z"])) * 0.5 / ReplicaView.MM_PER_M,
	)
	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 55.0
	get_tree().root.add_child(cam)
	cam.global_position = centroid + REPLICATION_CAM_OFFSET
	cam.look_at(Vector3(centroid.x, centroid.y + REPLICATION_LOOK_HEIGHT_M, centroid.z), Vector3.UP)

	var previous_distance2 := -1
	var cast_position := Vector2i()
	var have_cast_position := false
	var approach_frames := 0
	var hold_frames := 0
	var captured := 0
	while replay.has_next():
		var result := replay.advance()
		if result.get("ok") != true:
			_fail("authoritative mob-chase frame %d was refused: %s" % [captured, str(result)])
			return
		for i in SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame

		var store := replay.connection().store()
		var entities := _mob_chase_entities(store, [replay.mob_id(), replay.target_id()])
		if entities.size() != 2 or view.count() != 2:
			_fail("mob-chase frame %d reached %d states and %d rendered markers, want two of each" %
				[captured, entities.size(), view.count()])
			return
		if not _replicas_are_framed(cam, view, entities):
			return
		for entity: Dictionary in entities:
			var marker := view.marker_for(int(entity["id"]))
			var expected := Vector3(
				float(entity["x"]) / ReplicaView.MM_PER_M,
				float(entity["y"]) / ReplicaView.MM_PER_M,
				float(entity["z"]) / ReplicaView.MM_PER_M,
			)
			if marker == null or not marker.global_position.is_equal_approx(expected):
				_fail("marker %d does not render the folded authoritative position %s" % [entity["id"], expected])
				return

		var mob := store.entity(replay.mob_id())
		var target := store.entity(replay.target_id())
		var dx: int = int(mob["x"]) - int(target["x"])
		var dz: int = int(mob["z"]) - int(target["z"])
		var distance2 := dx * dx + dz * dz
		var phase := String(result["phase"])
		if phase == "approach":
			approach_frames += 1
			if previous_distance2 >= 0 and distance2 >= previous_distance2:
				_fail("rendered approach did not close: distance² %d after %d" % [distance2, previous_distance2])
				return
		else:
			var position := Vector2i(int(mob["x"]), int(mob["z"]))
			var maximum_center_distance := (
				replay.cast_range_mm() + int(mob["radius"]) + int(target["radius"])
			)
			if distance2 > maximum_center_distance * maximum_center_distance:
				_fail("rendered %s state is outside capsule-surface cast range" % phase)
				return
			if not have_cast_position:
				cast_position = position
				have_cast_position = true
			elif position != cast_position:
				_fail("rendered mob drifted during cast: %s -> %s" % [cast_position, position])
				return
			if phase == "cast_hold":
				hold_frames += 1
		previous_distance2 = distance2

		var image := await _grab_frame()
		var frame_name := "mob_chase_%02d_%s" % [captured, phase]
		if not _write_frame(dir, frame_name, image):
			return
		_write_note(dir, frame_name, image, _size_note(image), "", [
			"authoritative_tick: %d" % int(result["tick"]),
			"phase: %s" % phase,
			"reference: %s" % MOB_CHASE_REFERENCE,
			"remaining_gap: %s" % MOB_CHASE_REMAINING_GAP,
		])
		captured += 1

	if approach_frames < 3 or hold_frames < 2:
		_fail("mob-chase capture under-evidences motion: approach=%d held=%d" % [approach_frames, hold_frames])
		return
	print(ReplicaView.marker(view.count()))
	print("MOB CHASE on — %d authoritative frames, %d approach states, %d held-cast states" %
		[captured, approach_frames, hold_frames])
	print("CAPTURE PASS — authoritative chase sequence written to %s" % dir)
	get_tree().quit(0)


func _mob_chase_entities(store: ReplicaStore, ids: Array) -> Array:
	var out: Array = []
	for id_var: Variant in ids:
		var id := int(id_var)
		var state := store.entity(id)
		if state.is_empty():
			continue
		state["id"] = id
		out.append(state)
	return out


## The committed population, validated as a wire snapshot before it is trusted.
##
## A fixture that silently lost its entity list would otherwise photograph an
## empty world and — with the store happily folding an empty snapshot — report
## a pass for frames containing nothing.
func _load_replication_fixture() -> Dictionary:
	if not FileAccess.file_exists(REPLICATION_FIXTURE):
		_fail("the replication fixture %s is missing — there is no committed population to photograph" % REPLICATION_FIXTURE)
		return {}
	var text := FileAccess.get_file_as_string(REPLICATION_FIXTURE)
	var parsed: Variant = JSON.parse_string(text)
	if not (parsed is Dictionary):
		_fail("the replication fixture %s is not a JSON object" % REPLICATION_FIXTURE)
		return {}
	var doc: Dictionary = parsed
	for key: String in ["tick", "observer", "entities"]:
		if not doc.has(key):
			_fail("the replication fixture is missing '%s'" % key)
			return {}
	var entities: Variant = doc["entities"]
	if not (entities is Array) or (entities as Array).is_empty():
		_fail("the replication fixture names no entities — an empty population is not evidence of replication")
		return {}
	# JSON numbers are ALWAYS floats in Godot, and the store's contract is
	# integer millimetres, so hand every value across as an int rather than
	# letting a 4000.0 reach code that indexes and compares ids.
	var out_entities: Array = []
	for e_var: Variant in entities as Array:
		if not (e_var is Dictionary):
			_fail("the replication fixture holds a non-object entity")
			return {}
		var e: Dictionary = e_var
		for key: String in ["id", "x", "y", "z", "radius"]:
			if not e.has(key):
				_fail("a replication fixture entity is missing '%s'" % key)
				return {}
		out_entities.append({
			"id": int(e["id"]), "x": int(e["x"]), "y": int(e["y"]),
			"z": int(e["z"]), "radius": int(e["radius"]),
		})
	return {"tick": int(doc["tick"]), "observer": int(doc["observer"]), "entities": out_entities}


## Whether every replicated marker is one this camera would actually DRAW, and
## is standing on the ground rather than hanging over it.
##
## A marker present in the tree proves the sync ran; it does not prove the shot
## contains it. Each of these has a distinct way of publishing an empty-looking
## frame while every other check passes: behind the camera, outside the frame,
## hidden, on a render layer the camera does not cull for, or — the one a
## reviewer would notice and no numeric guard would — floating in the air
## because the fixture was authored at the wrong height.
func _replicas_are_framed(cam: Camera3D, view: ReplicaView, entities: Array) -> bool:
	var vp := get_viewport().get_visible_rect().size
	var space := cam.get_world_3d().direct_space_state
	for e_var: Variant in entities:
		var e: Dictionary = e_var
		var id: int = e["id"]
		var marker := view.marker_for(id)
		if marker == null:
			_fail("replicated entity %d has no marker — the view's table and the fixture disagree" % id)
			return false
		if not marker.visible:
			_fail("the marker for replicated entity %d is hidden — it would not appear in the frame" % id)
			return false
		if (marker.layers & cam.cull_mask) == 0:
			_fail("the marker for replicated entity %d is on render layers outside the camera's cull mask — it would not be drawn" % id)
			return false
		if not _on_screen(cam, vp, marker.global_position):
			var p := cam.unproject_position(marker.global_position)
			_fail(("the marker for replicated entity %d is not in shot (behind=%s, projects to (%.0f, %.0f) " +
				"in a %dx%d frame)") %
				[id, str(cam.is_position_behind(marker.global_position)), p.x, p.y, int(vp.x), int(vp.y)])
			return false
		# Well above the marker so the ray starts outside the terrain even for a
		# fixture authored below it — a buried marker then reads as a NEGATIVE
		# gap rather than as a missing hit.
		var from := Vector3(marker.global_position.x, marker.global_position.y + 50.0, marker.global_position.z)
		var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 200.0)
		query.collide_with_areas = false
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			_fail("no ground under replicated entity %d — the fixture places it off the world" % id)
			return false
		var gap: float = marker.global_position.y - (hit["position"] as Vector3).y
		if gap < 0.0 or gap > REPLICATION_MAX_GROUND_GAP_M:
			_fail(("replicated entity %d sits %.2f m above the ground at its position (ground y %.2f), " +
				"outside the [0, %.2f] band — re-measure the fixture's y for this entity rather than " +
				"publishing a capsule hanging in the air") %
				[id, gap, (hit["position"] as Vector3).y, REPLICATION_MAX_GROUND_GAP_M])
			return false
	return true


## Whether a world point is in front of the camera AND inside its frame.
##
## Shared by the framing assertion and the sample designation so the two cannot
## drift into disagreeing about what "in shot" means — a designation that
## accepted a point the assertion rejected would hand the verdict pixels the
## capture never photographed.
func _on_screen(cam: Camera3D, vp: Vector2, world: Vector3) -> bool:
	if cam.is_position_behind(world):
		return false
	var p := cam.unproject_position(world)
	return p.x >= 0.0 and p.y >= 0.0 and p.x < vp.x and p.y < vp.y


## The pixels the replicated capsules cover — the samples the verdict measures.
##
## Points are taken INSIDE the capsule body, offset along the camera's own right
## and up axes so the grid faces the viewer whatever direction the shot is from.
## Interior rather than silhouette on purpose: an edge pixel is shared with the
## background by antialiasing, so it moves between any two frames and would land
## in the drift band rather than in the signal.
##
## Caps are excluded (the vertical span stops short of ±half-height) for the
## same reason — a cap curves away from the camera, so its shading is the part
## most sensitive to a fog froxel drifting past.
func _designate_replica_points(cam: Camera3D, view: ReplicaView, entities: Array) -> Array[Vector2i]:
	var vp := get_viewport().get_visible_rect().size
	var right := cam.global_transform.basis.x
	var up := cam.global_transform.basis.y
	var out: Array[Vector2i] = []
	for e_var: Variant in entities:
		var e: Dictionary = e_var
		# Never null: _replicas_are_framed runs first and hard-fails on a missing
		# marker, so reaching here means every fixture id has one.
		var marker := view.marker_for(int(e["id"]))
		# Measured off the mesh the view ACTUALLY built rather than re-derived
		# from the fixture and the nominal height. `ReplicaView._fit_capsule`
		# grows a capsule's height once its radius passes half the nominal one,
		# so a span computed from the constant would creep onto the caps for a
		# wide entity. Reading the mesh cannot drift from that rule, because it
		# is the result of it.
		var mesh: CapsuleMesh = marker.mesh
		var radius := mesh.radius
		# The straight section is what the rows must stay inside — Godot's
		# capsule height INCLUDES both hemispherical caps. Zero when the mesh
		# has become a sphere (radius equal to half its height), which collapses
		# the rows onto the equator: degenerate, but still interior, which is
		# the property the samples actually need.
		var cylinder_half := maxf(mesh.height * 0.5 - radius, 0.0)
		for row in REPLICATION_SAMPLE_ROWS:
			# Spans 90% of the straight section, so no row sits on the seam
			# where the cap begins and antialiasing mixes in the background.
			var v := (float(row) / float(REPLICATION_SAMPLE_ROWS - 1) - 0.5) * 1.8 * cylinder_half
			for col in REPLICATION_SAMPLE_COLS:
				# Spans ±0.5 of the radius, so a point stays interior even where
				# the capsule curves away from the camera.
				var h := (float(col) / float(REPLICATION_SAMPLE_COLS - 1) - 0.5) * radius
				var world: Vector3 = marker.global_position + up * v + right * h
				if not _on_screen(cam, vp, world):
					continue
				out.append(Vector2i(cam.unproject_position(world)))
	return out


## Write one captured frame and its note, failing the capture if the file did
## not land.
func _write_frame(dir: String, frame_name: String, img: Image) -> bool:
	var err := img.save_png("%s/%s.png" % [dir, frame_name])
	if err != OK:
		_fail("could not write %s (error %d)" % [frame_name, err])
		return false
	_write_note(dir, frame_name, img, _size_note(img))
	print("CAPTURED %s" % frame_name)
	return true


## A character in the shipped scene that actually carries an idle, preferring
## one of the settlement's people.
##
## The preference is about EVIDENCE, not correctness: the wanderer wakes in the
## starter cave, where torchlight and deep shadow swallow the ~10 mm of
## shoulder travel this scenario exists to show, while the people by the shrine
## stand in daylight. Falls back to any breathing body — including the
## wanderer — so the scenario still produces evidence if the settlement is ever
## absent, rather than failing for a reason unrelated to the idle.
##
## Searched rather than assumed: the point is to photograph what a PLAYER would
## see, so a scene where the factory attached no idle at all must surface as a
## failure instead of being quietly skipped.
func _first_breathing_body(main: Node) -> Node3D:
	var npcs := main.get_node_or_null("Npcs")
	if npcs != null:
		var from_settlement := _search_breathing_body(npcs)
		if from_settlement != null:
			return from_settlement
	return _search_breathing_body(main)


func _search_breathing_body(node: Node) -> Node3D:
	if node.get_node_or_null("BreathingIdle") != null and CharacterFactory.find_skeleton(node) != null:
		return node as Node3D
	for child in node.get_children():
		var found := _search_breathing_body(child)
		if found != null:
			return found
	return null


## Captures one creator frame, re-checking the panel is really on screen first:
## a preset switch rebuilds the portrait and could take the panel with it, and a
## frame of bare world would otherwise be saved under a first-run name.
func _shoot(dir: String, frame: String, creator: CanvasLayer) -> bool:
	if _visible_panel_area(creator) <= 0.0:
		_fail("%s: the creator has no visible panel — the frame would be the world behind a transparent layer" % frame)
		return false
	# Pin the breath before the shutter (#485). Re-done per shot rather than once
	# up front because a preset switch calls `set_character`, which rebuilds the
	# portrait and gives it a FRESH idle already advancing on wall-clock time —
	# so freezing only at the start would leave every frame after the first
	# preset unpinned, which is most of the set.
	var pinned := _pin_idles()
	if pinned == 0:
		_fail("%s: no breathing idle to pin — the portrait would be photographed mid-breath and the frame would not repeat" % frame)
		return false
	# Declared per frame so CI can assert the pin FIRED, not merely that it
	# exists. Deleting the call above passes every unit test in the repo — the
	# frames still render, still write, still report CAPTURE PASS, and only the
	# change report silently goes back to tens of percent on unchanged builds.
	# That is #231's shape exactly, so the wiring gets its own evidence.
	print("PINNED %s — %d idle(s) frozen at +%.2fs" % [frame, pinned, BreathingIdle.BREATH_CAPTURE_TIME])
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var spread := _luma_spread_box(img, UI_SAMPLE_X0, UI_SAMPLE_X1, UI_SAMPLE_Y0, UI_SAMPLE_Y1)
	if spread < MIN_LUMA_SPREAD:
		_fail("%s: the creator panel band is a uniform frame (luma spread %.4f) — the UI did not draw" % [frame, spread])
		return false
	var out := "%s/%s.png" % [dir, frame]
	var err := img.save_png(out)
	if err != OK:
		_fail("could not write %s (error %d)" % [out, err])
		return false
	var note := _size_note(img)
	print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
		[frame, out, img.get_width(), img.get_height(), spread, note])
	_write_note(dir, frame, img, note)
	return true


## Freezes every body in the scene at a fixed breath phase and returns how many
## were pinned, so the caller can refuse a frame that pinned nothing.
##
## ## Why the first-run frames needed this (#485)
##
## The creator is a CanvasLayer whose panel takes the LEFT band only, so most of
## every `first_run_*` frame is a live 3D portrait — and that portrait breathes
## on accumulated wall-clock time. The capture settles a fixed number of FRAMES,
## so the pose at the shutter depended on how fast those frames rendered.
##
## Measured on unchanged `main`, two runs of IDENTICAL code, this machine
## (macOS, the platform CI captures on), as changed-pixel fraction per frame:
##
##   first_run_elder        53.74%      first_run_head_clothing  19.18%
##   first_run_villager     46.63%      first_run_first_run      16.70%
##   first_run_brute        31.67%      first_run_lower          14.13%
##   first_run_base_layer   24.21%      first_run_wanderer        9.18%
##   first_run_advanced_1    3.62%      first_run_outfit          2.58%
##   first_run_head_armor    3.01%
##
## Nothing changed between those two runs. `frame_diff.gd` carries the same
## table with the pinned column beside it: every frame falls to 0.00%-0.60%,
## which is what temporal antialiasing, foliage and fog still move. That column
## is NOT a CI floor — see the warning under it before treating it as one.
##
## Scoped to `_shoot`, which only the first-run scenario calls, so the world
## vantages keep the behaviour they were calibrated on.
func _pin_idles() -> int:
	var pinned := 0
	for node: Node in get_tree().root.find_children("*", "BreathingIdle", true, false):
		# A body whose idle never found its skeleton is NOT counted as pinned:
		# it is exactly the case where the caller would believe the frame
		# repeats when it does not.
		if (node as BreathingIdle).freeze_at():
			pinned += 1
	return pinned


## The creator's scrolling control list.
func _find_scroll(node: Node) -> ScrollContainer:
	for child in node.get_children():
		if child is ScrollContainer:
			return child as ScrollContainer
		var found := _find_scroll(child)
		if found != null:
			return found
	return null


## The lowest real wardrobe control, regardless of whether the creator exposes
## one picker per region or the opted-in dictionary of layer-specific pickers.
## Choosing by rendered position rather than dictionary order keeps the capture
## tied to what can actually fall below the viewport.
func _bottom_outfit_picker(creator: CharacterCreator) -> Control:
	var by_slot: Variant = creator.get("_outfit_pickers")
	if not (by_slot is Dictionary):
		return null
	var bottom: Control = null
	for slot: Variant in by_slot:
		var controls: Variant = (by_slot as Dictionary)[slot]
		if controls is Dictionary:
			for layer: Variant in controls:
				var candidate: Variant = (controls as Dictionary)[layer]
				if candidate is Control and (bottom == null \
						or (candidate as Control).global_position.y > bottom.global_position.y):
					bottom = candidate as Control
		elif controls is Control and (bottom == null \
				or (controls as Control).global_position.y > bottom.global_position.y):
			bottom = controls as Control
	return bottom


## Writes the frame's own provenance next to it, so the artifact carries what
## the log knows. Best-effort: failing to write a note must never fail a capture
## that succeeded.
## `ground` names the region the camera stands on, where that is meaningful —
## empty for the cave vantages, which are underground and belong to no region.
## `details` carries scenario-specific provenance as complete `key: value`
## lines, rather than overloading the size field.
func _write_note(
	dir: String,
	frame: String,
	img: Image,
	note: String,
	ground: String = "",
	details: Array[String] = [],
) -> void:
	# Art-direction check 1 — value range and hue span — measured rather than
	# eyeballed (#230). Printed AND written: the job log is where an agent
	# judging its own PR looks, and the note travels with the uploaded frames
	# for whoever reads the artifact later. Reporting only, never a gate; a
	# deliberately monochrome scene is a legitimate composition.
	var separation: String = FrameMetrics.format(FrameMetrics.measure(img))
	print("SEPARATION %s — %s" % [frame, separation])
	var f := FileAccess.open("%s/%s.txt" % [dir, frame], FileAccess.WRITE)
	if f == null:
		push_warning("could not write the note for %s" % frame)
		return
	f.store_line("frame: %s.png" % frame)
	f.store_line("captured: %dx%d" % [img.get_width(), img.get_height()])
	if note.is_empty():
		f.store_line("size: as shipped")
	else:
		f.store_line("size:%s" % note)
	f.store_line("separation: %s" % separation)
	if not ground.is_empty():
		f.store_line("ground: %s" % ground)
	for detail: String in details:
		f.store_line(detail)
	f.close()


## On-screen area of the creator's visible Control children that actually falls
## INSIDE the viewport. Measured as an intersection, not as the control's own
## size: a layout regression that pushes the panel off the edge leaves it
## visible and full-sized, so counting its bare area would accept a frame the
## panel does not appear in — and the luminance check behind it would then pass
## on the 3D world, which is the failure this whole scenario exists to catch.
func _visible_panel_area(creator: CanvasLayer) -> float:
	var screen := Rect2(Vector2.ZERO, Vector2(get_viewport().get_visible_rect().size))
	var area := 0.0
	for child in creator.get_children():
		if child is Control and (child as Control).is_visible_in_tree():
			var on_screen := screen.intersection((child as Control).get_global_rect())
			area += on_screen.size.x * on_screen.size.y
	return area


## The open CharacterCreator, if any. Found by TYPE rather than by node name:
## main.gd constructs it with `CharacterCreator.new()` and never names it, so a
## name lookup would silently find nothing and report the creator missing.
func _find_creator(main: Node) -> CanvasLayer:
	for child in main.get_children():
		if child is CharacterCreator:
			return child as CanvasLayer
	return null


## Whether the generated world is actually present in the tree: a WorldGen node
## carrying its baked Terrain mesh. Structural rather than visual on purpose —
## it answers "did the world build?" directly, instead of inferring it from
## pixels that a sky alone can produce.
func _has_world(main: Node) -> bool:
	var world := main.get_node_or_null("World")
	if world == null:
		return false
	for child in world.get_children():
		if child is MeshInstance3D and str(child.name) == "Terrain" \
				and (child as MeshInstance3D).mesh != null:
			# Present is not the same as VISIBLE. A regression that hides or
			# culls the terrain leaves the mesh (and its collider, so the ray
			# still hits) while the camera sees only sky — which the luminance
			# check happily accepts.
			return (child as MeshInstance3D).is_visible_in_tree()
	return false


## Whether this camera would actually DRAW the terrain: its cull mask must share
## at least one render layer with the terrain mesh. Separate from both
## _has_world (does it exist and is it visible) and _sees_geometry (is it in
## front of us) — a mesh can be present, visible and directly ahead while still
## being excluded from this camera's render pass.
func _camera_draws_world(cam: Camera3D, main: Node) -> bool:
	var world := main.get_node_or_null("World")
	if world == null:
		return false
	for child in world.get_children():
		if child is MeshInstance3D and str(child.name) == "Terrain":
			return ((child as MeshInstance3D).layers & cam.cull_mask) != 0
	return false


## Proves the terrain contributes PIXELS to the frame. Three captures at the
## already-settled vantage: two live frames CONTRIB_GAP_FRAMES apart — the
## noise reference, because wind-swayed foliage and temporal effects move
## between ANY two frames and a point they touch may vouch for nothing — then
## the same view with the terrain mesh hidden. At samples whose camera ray
## hits bare terrain, hiding the terrain must change the pixel: ground becomes
## sky. A fully transparent material, or a shader discarding every fragment,
## leaves the hidden frame identical to the live one and fails here. The
## TerrainBody collider is a SIBLING of the mesh, so hiding the mesh cannot
## disturb the designation or the physics under the wanderers.
func _prove_terrain_contribution(cam: Camera3D, main: Node) -> bool:
	var world := main.get_node_or_null("World")
	var terrain := _terrain_mesh(world)
	if terrain == null:
		_fail("no Terrain mesh under World — cannot run the terrain-contribution control")
		return false
	var pts := designate_terrain_points(cam, world, get_viewport().get_visible_rect().size)
	if pts.size() < CONTRIB_MIN_POINTS:
		_fail("vantage '%s' frames only %d bare-terrain samples (floor %d) — too little open ground to prove the terrain renders" %
			[CONTRIB_VANTAGE, pts.size(), CONTRIB_MIN_POINTS])
		return false
	var live_a := await _grab_frame()
	for i in CONTRIB_GAP_FRAMES:
		await get_tree().process_frame
	var live_b := await _grab_frame()
	terrain.visible = false
	for i in CONTRIB_GAP_FRAMES:
		await get_tree().process_frame
	var hidden := await _grab_frame()
	terrain.visible = true
	if not terrain.is_visible_in_tree():
		_fail("the terrain did not come back visible after the contribution control — every later frame would photograph a world with no ground")
		return false
	var verdict := contribution_verdict(pts, live_a, live_b, hidden)
	print("TERRAIN CONTRIBUTION %s: %d terrain samples, %d quiet (noise p95 %.4f), %d contributing (fraction %.2f, median change %.3f)" %
		[CONTRIB_VANTAGE, pts.size(), int(verdict["quiet"]), float(verdict["noise_p95"]),
			int(verdict["contributing"]), float(verdict["fraction"]), float(verdict["median_change"])])
	if not bool(verdict["ok"]):
		_fail("vantage '%s': %s" % [CONTRIB_VANTAGE, str(verdict["reason"])])
		return false
	return true


## The baked Terrain mesh under World, or null.
func _terrain_mesh(world: Node) -> MeshInstance3D:
	if world == null:
		return null
	for child in world.get_children():
		if child is MeshInstance3D and str(child.name) == "Terrain":
			return child as MeshInstance3D
	return null


## One settled frame as an Image.
func _grab_frame() -> Image:
	await RenderingServer.frame_post_draw
	return get_viewport().get_texture().get_image()


## The sample points whose camera ray lands on BARE TERRAIN: the same grid the
## luminance guard walks, kept only where the first collider hit is the
## terrain's own TerrainBody. First hit, deliberately: a ray whose first hit is
## a ruin, the shrine or a wanderer is a pixel that shows THAT, and letting it
## vouch for the terrain would re-open the gap this control closes. Static and
## side-effect-free so terrain_contribution_test.gd can pin the designation
## against the real generated world, headlessly.
static func designate_terrain_points(cam: Camera3D, world: Node, vp_size: Vector2) -> Array[Vector2i]:
	var space := cam.get_world_3d().direct_space_state
	var out: Array[Vector2i] = []
	var x0 := SAMPLE_X0 * vp_size.x
	var y0 := SAMPLE_Y0 * vp_size.y
	var span_x := (SAMPLE_X1 - SAMPLE_X0) * vp_size.x
	var span_y := (SAMPLE_Y1 - SAMPLE_Y0) * vp_size.y
	for gy in 12:
		for gx in 16:
			var px := Vector2(x0 + (gx + 0.5) * span_x / 16.0, y0 + (gy + 0.5) * span_y / 12.0)
			var from := cam.project_ray_origin(px)
			var to := from + cam.project_ray_normal(px) * 500.0
			var query := PhysicsRayQueryParameters3D.create(from, to)
			query.collide_with_areas = false
			var hit := space.intersect_ray(query)
			if hit.is_empty():
				continue
			var collider: Object = hit["collider"]
			if collider is StaticBody3D and str((collider as Node).name) == "TerrainBody" \
					and (collider as Node).get_parent() == world:
				out.append(Vector2i(px))
	return out


## The pure verdict over one designation and three frames — static so the test
## can drive it with synthetic images. Returns ok/reason plus the counts the
## capture log prints; every non-ok reason names what failed and why it damns.
##
## The question is never terrain-specific: given points that should be covered
## by SOMETHING, two live frames to measure the world's own drift at them, and a
## third frame with that something ablated, did it land pixels? Terrain hidden
## behind its own `visible = false` (#150) and a replicated population removed
## from the store (#325) are the same measurement, so `subject` and `ablation`
## only supply the nouns the reason strings read back. Their defaults keep the
## terrain control and its test reading exactly as before.
static func contribution_verdict(points: Array[Vector2i], live_a: Image, live_b: Image, hidden: Image,
		subject: String = "bare-terrain", ablation: String = "hiding the terrain",
		min_fraction: float = CONTRIB_MIN_FRACTION) -> Dictionary:
	var verdict := {
		"ok": false, "reason": "", "quiet": 0, "contributing": 0,
		"fraction": 0.0, "noise_p95": 0.0, "median_change": 0.0,
	}
	if points.size() < CONTRIB_MIN_POINTS:
		verdict["reason"] = "only %d %s samples (floor %d) — too few to measure contribution" % [points.size(), subject, CONTRIB_MIN_POINTS]
		return verdict
	if live_a.get_size() != live_b.get_size() or live_a.get_size() != hidden.get_size():
		verdict["reason"] = "control frames differ in size — the captures are not comparable"
		return verdict
	var noises: Array[float] = []
	var changes: Array[float] = []
	var quiet := 0
	var contributing := 0
	for pt in points:
		if pt.x < 0 or pt.x >= live_a.get_width() or pt.y < 0 or pt.y >= live_a.get_height():
			verdict["reason"] = "sample (%d, %d) is outside the %dx%d frame — designation and capture disagree about the viewport" % [pt.x, pt.y, live_a.get_width(), live_a.get_height()]
			return verdict
		var noise := _pixel_delta(live_a.get_pixel(pt.x, pt.y), live_b.get_pixel(pt.x, pt.y))
		noises.append(noise)
		if noise > CONTRIB_QUIET_NOISE:
			continue
		quiet += 1
		var change := _pixel_delta(live_b.get_pixel(pt.x, pt.y), hidden.get_pixel(pt.x, pt.y))
		changes.append(change)
		if change >= CONTRIB_MIN_CHANGE:
			contributing += 1
	verdict["quiet"] = quiet
	verdict["contributing"] = contributing
	verdict["noise_p95"] = _percentile(noises, 0.95)
	verdict["median_change"] = _percentile(changes, 0.5)
	if quiet < CONTRIB_MIN_QUIET:
		verdict["reason"] = "only %d of %d %s samples were quiet across the live pair (floor %d) — too much frame motion to measure what it contributes" % [quiet, points.size(), subject, CONTRIB_MIN_QUIET]
		return verdict
	var fraction := float(contributing) / float(quiet)
	verdict["fraction"] = fraction
	if fraction < min_fraction:
		verdict["reason"] = "%s changed only %d of %d quiet %s samples (%.0f%%, floor %.0f%%) — it contributes no pixels, exactly what a transparent or discard-everything material renders" % [ablation, contributing, quiet, subject, fraction * 100.0, min_fraction * 100.0]
		return verdict
	verdict["ok"] = true
	return verdict


## Pure image verdict for the hollow-ash ablation above. The same central grid
## used by the world luminance guard excludes HUD text; the minimum changed
## fraction prevents a lone noisy pixel from vouching for a whole volume.
static func ash_contribution_verdict(live: Image, hidden: Image) -> Dictionary:
	var verdict := {
		"ok": false, "reason": "", "samples": 0, "changed": 0,
		"fraction": 0.0, "delta_p95": 0.0,
	}
	if live.is_empty() or hidden.is_empty():
		verdict["reason"] = "with/without-volume control produced an empty frame"
		return verdict
	if live.get_size() != hidden.get_size():
		verdict["reason"] = "with/without-volume frames differ in size and cannot be compared"
		return verdict
	var deltas: Array[float] = []
	var changed := 0
	for gy in 12:
		for gx in 16:
			var x := clampi(int((SAMPLE_X0 + (gx + 0.5) * (SAMPLE_X1 - SAMPLE_X0) / 16.0) *
				live.get_width()), 0, live.get_width() - 1)
			var y := clampi(int((SAMPLE_Y0 + (gy + 0.5) * (SAMPLE_Y1 - SAMPLE_Y0) / 12.0) *
				live.get_height()), 0, live.get_height() - 1)
			var delta := _pixel_delta(live.get_pixel(x, y), hidden.get_pixel(x, y))
			deltas.append(delta)
			if delta >= ASH_CONTRIB_MIN_DELTA:
				changed += 1
	var fraction := float(changed) / float(deltas.size())
	verdict["samples"] = deltas.size()
	verdict["changed"] = changed
	verdict["fraction"] = fraction
	verdict["delta_p95"] = _percentile(deltas, 0.95)
	if fraction < ASH_CONTRIB_MIN_FRACTION:
		verdict["reason"] = "hiding the FogVolume changed only %d of %d samples (%.1f%%, floor %.1f%%) — no rendered ash contribution was proved" % [
			changed, deltas.size(), fraction * 100.0, ASH_CONTRIB_MIN_FRACTION * 100.0
		]
		return verdict
	verdict["ok"] = true
	return verdict


## The largest per-channel difference between two pixels. Channels rather than
## luminance on purpose: a ground/sky pair can share brightness while differing
## wildly in hue, and luminance would read that as "no change".
static func _pixel_delta(a: Color, b: Color) -> float:
	return maxf(maxf(absf(a.r - b.r), absf(a.g - b.g)), absf(a.b - b.b))


## The q-th percentile of a sample list (0 on an empty list — callers print it,
## they never gate on it).
static func _percentile(values: Array[float], q: float) -> float:
	if values.is_empty():
		return 0.0
	var sorted: Array[float] = []
	sorted.assign(values)
	sorted.sort()
	return sorted[clampi(int(q * (sorted.size() - 1)), 0, sorted.size() - 1)]


## Whether the camera has world geometry in front of it, by raycasting from the
## eye toward the vantage's target against the terrain/ruin colliders. Distinct
## from _has_world: the world can exist while the camera frames only sky.
## Characters — the wanderer, the Reach's people, hounds — are NOT world
## geometry: a shot validated by an avatar strolling through the ray would pass
## while framing nothing, so character bodies are stepped over rather than
## counted.
func _sees_geometry(cam: Camera3D, target: Vector3) -> bool:
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var to := from + (target - from).normalized() * 500.0
	var exclude: Array[RID] = []
	for i in 4:
		var query := PhysicsRayQueryParameters3D.create(from, to)
		query.collide_with_areas = false
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if hit.is_empty():
			return false
		if not (hit["collider"] is CharacterBody3D):
			return true
		exclude.append((hit["collider"] as CollisionObject3D).get_rid())
	return false


## Luminance spread over a grid sampled from the central box only — enough to
## tell a rendered world from a flat clear-colour fill, while ignoring the HUD
## text that would otherwise vouch for a blank 3D view (see SAMPLE_* above).
func _luma_spread(img: Image) -> float:
	return _luma_spread_box(img, SAMPLE_X0, SAMPLE_X1, SAMPLE_Y0, SAMPLE_Y1)


## Luminance spread over a grid sampled from an arbitrary box, so each scenario
## can measure the part of the frame its own subject occupies.
func _luma_spread_box(img: Image, fx0: float, fx1: float, fy0: float, fy1: float) -> float:
	var lo := 2.0
	var hi := -1.0
	var x0 := fx0 * img.get_width()
	var y0 := fy0 * img.get_height()
	var span_x := (fx1 - fx0) * img.get_width()
	var span_y := (fy1 - fy0) * img.get_height()
	for gy in 12:
		for gx in 16:
			var sample := img.get_pixel(
				int(x0 + (gx + 0.5) * span_x / 16.0),
				int(y0 + (gy + 0.5) * span_y / 12.0))
			var lum := sample.get_luminance()
			lo = minf(lo, lum)
			hi = maxf(hi, lum)
	return hi - lo


## Do these two paths name the same file? Godot accepts `user://`, `res://` and
## plain OS paths interchangeably, so the same file has several spellings and a
## string compare answers "different" for all but one of them.
## [method ProjectSettings.globalize_path] collapses the schemes to absolute OS
## paths and [method String.simplify_path] removes `.`/`..` and duplicate
## separators, leaving one spelling per file.
func _same_file(a: String, b: String) -> bool:
	return _canonical(a) == _canonical(b)


func _canonical(path: String) -> String:
	return ProjectSettings.globalize_path(path).simplify_path()


func _fail(message: String) -> void:
	push_error(message)
	print("CAPTURE FAIL — %s" % message)
	get_tree().quit(1)
