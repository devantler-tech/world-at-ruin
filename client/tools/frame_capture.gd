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


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty():
		_fail("WAR_SHOT_DIR is not set — nowhere to write frames")
		return
	if DisplayServer.get_name() == "headless":
		_fail("running headless — a headless run renders nothing; use a windowed run")
		return

	var main: Node = load("res://scenes/main.tscn").instantiate()
	# The root is still setting up children while our _ready runs, so a direct
	# add_child() is REFUSED — and the capture would then photograph an empty
	# viewport while still reporting success. Defer, then prove it attached.
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	if not main.is_inside_tree():
		_fail("the main scene never attached — nothing would have been rendered")
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
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)" %
			[vantage_name, out, img.get_width(), img.get_height(), spread])

	print("CAPTURE PASS — %d vantages written to %s" % [VANTAGES.size(), dir])
	get_tree().quit(0)


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
			return true
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
	var lo := 2.0
	var hi := -1.0
	var x0 := SAMPLE_X0 * img.get_width()
	var y0 := SAMPLE_Y0 * img.get_height()
	var span_x := (SAMPLE_X1 - SAMPLE_X0) * img.get_width()
	var span_y := (SAMPLE_Y1 - SAMPLE_Y0) * img.get_height()
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
