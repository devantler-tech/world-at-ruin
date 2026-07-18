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
## Two scenarios, chosen with WAR_SCENARIO:
##
##   world (default) — the shipped world from fixed vantages. Needs a seeded
##     save, or the first-run creator opens over the shot.
##   first_run       — the character creator as a new player meets it. Needs the
##     save to be ABSENT, which is what makes the creator open.
##
## The second exists because a PR changing first-run UI otherwise gets no
## evidence of the surface it changed: the world scenario seeds a save precisely
## so the creator is not in frame, so it photographs everything except the thing
## under review and still passes.
##
## Run (must be WINDOWED — a headless run renders nothing at all):
##   WAR_SHOT_DIR=/tmp/shots WAR_SAVE_PATH=/tmp/probe_save.json \
##     godot --path client --resolution 1600x900 res://tools/frame_capture.tscn
##
## Point WAR_SAVE_PATH at a throwaway COPY of a character recipe: with no save
## present the first-run creator opens and its panel covers a third of the frame,
## and with the real path a capture would touch the player's own save.

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
]

## Frames to let the world build before the first shot (generation is synchronous
## but shaders, shadow cascades and SDFGI cascades need frames).
const WARMUP_FRAMES := 150
## Frames to settle after each camera move. Volumetric fog uses temporal
## reprojection and SDFGI re-converges, so an immediate capture photographs a
## half-resolved frame.
const SETTLE_FRAMES := 120
## Minimum luminance spread across a sampled grid for a frame to count as real.
## A capture that photographs nothing still writes a valid PNG and still reports
## success — this is the guard against that silent failure.
const MIN_LUMA_SPREAD := 0.02

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

## The first-run scenario samples the LEFT band instead, because that is where
## the creator's panel is anchored (PRESET_LEFT_WIDE). Sampling the world box
## would measure the 3D view BEHIND the panel — so a run where the creator never
## opened would pass on the scenery, which is the whole failure this scenario
## exists to catch.
const UI_SAMPLE_X0 := 0.02
const UI_SAMPLE_X1 := 0.30
const UI_SAMPLE_Y0 := 0.10
const UI_SAMPLE_Y1 := 0.90

## The creator is 2D and needs no shadow/SDFGI convergence, so it settles far
## sooner than a world vantage. Kept separate so adding this scenario does not
## lengthen the world capture, per #145.
const UI_WARMUP_FRAMES := 60


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty():
		_fail("WAR_SHOT_DIR is not set — nowhere to write frames")
		return
	if DisplayServer.get_name() == "headless":
		_fail("running headless — a headless run renders nothing; use a windowed run")
		return

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

	var scenario := OS.get_environment("WAR_SCENARIO")
	if scenario.is_empty():
		scenario = "world"
	if scenario == "first_run":
		await _capture_first_run(dir, main)
		return
	if scenario != "world":
		_fail("unknown WAR_SCENARIO '%s' — expected 'world' or 'first_run'" % scenario)
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
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
			[vantage_name, out, img.get_width(), img.get_height(), spread, _size_note(img)])

	print("CAPTURE PASS — %d vantages written to %s" % [VANTAGES.size(), dir])
	get_tree().quit(0)


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

	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var spread := _luma_spread_box(img, UI_SAMPLE_X0, UI_SAMPLE_X1, UI_SAMPLE_Y0, UI_SAMPLE_Y1)
	if spread < MIN_LUMA_SPREAD:
		_fail("the creator panel band is a uniform frame (luma spread %.4f) — the UI did not draw" % spread)
		return
	var out := "%s/first_run.png" % dir
	var err := img.save_png(out)
	if err != OK:
		_fail("could not write %s (error %d)" % [out, err])
		return
	# The clamp note matters MORE here than for a world vantage. A hosted runner
	# often cannot realise the shipped window size, and the creator's panel is a
	# fixed-height column: at a shorter viewport it clips, which reads exactly
	# like a layout bug in the change under review. Say so on the frame rather
	# than let a reviewer draw that conclusion.
	print("CAPTURED first_run -> %s (%dx%d, luma spread %.3f)%s" %
		[out, img.get_width(), img.get_height(), spread, _size_note(img)])
	print("CAPTURE PASS — 1 first-run vantage written to %s" % dir)
	get_tree().quit(0)


## Reports the captured size against the size the project actually ships. A
## hosted runner's display often cannot realise the configured window, so frames
## arrive smaller than the game does — and both fine material detail and UI
## layout read differently at that size. Silently accepting the clamp would let a
## reviewer judge a surface at a resolution no player uses.
func _size_note(img: Image) -> String:
	var want_w: int = ProjectSettings.get_setting("display/window/size/viewport_width", 0)
	var want_h: int = ProjectSettings.get_setting("display/window/size/viewport_height", 0)
	if want_w > 0 and (img.get_width() != want_w or img.get_height() != want_h):
		return " [CLAMPED from the shipped %dx%d — detail and UI layout read at a different scale here]" % [want_w, want_h]
	return ""


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


## Whether the camera has world geometry in front of it, by raycasting from the
## eye toward the vantage's target against the terrain/ruin colliders. Distinct
## from _has_world: the world can exist while the camera frames only sky.
func _sees_geometry(cam: Camera3D, target: Vector3) -> bool:
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var to := from + (target - from).normalized() * 500.0
	var query := PhysicsRayQueryParameters3D.create(from, to)
	query.collide_with_areas = false
	var hit := space.intersect_ray(query)
	return not hit.is_empty()


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


func _fail(message: String) -> void:
	push_error(message)
	print("CAPTURE FAIL — %s" % message)
	get_tree().quit(1)
