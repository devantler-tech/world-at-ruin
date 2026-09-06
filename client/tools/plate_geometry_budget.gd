extends Node
## Measures what the raised exposed-stone overlay (#547) costs on the GPU, in
## the shape ADR 0001 demands: one world, one set of lights, both states of the
## `WAR_GROUND_PLATES` treatment measured in the same process, at 1280×720 with
## VSync disabled and the shipping volumetric atmosphere on, over at least 600
## steady-state frames each, reading the viewport's MEASURED GPU frame time.
##
## The GPU time comes from `RenderingServer.viewport_get_measured_render_time_gpu`
## after `viewport_set_measure_render_time` is switched on — a timer the driver
## fills in, not an estimate. Godot's command-line GPU profiler printed
## `GPU PROFILE (total 0.0ms)` on the Metal run that ADR 0001 records, and zero
## is not a timing result: a state whose readings are mostly zero is reported as
## UNAVAILABLE and the run refuses to pass, because "free" and "unmeasured" look
## identical from the outside and only one of them is good news.
##
## Everything else the acceptance criteria name is printed on the REPORT line:
## candidate, slab, exposed and built counts, vertices, triangles, surfaces and
## the frame's draw calls in each state. The camera stands at walking height a
## few metres from the built slab nearest the shrine, looking down at it, which
## is the close range the treatment exists for.
##
## Like `plate_crawl`, the tool proves the two states DIFFER on screen before it
## believes either number: a camera that quietly reverts to the player's view
## photographs the same cave interior twice and reports a perfect zero cost.
##
## Run (must be WINDOWED — headless renders nothing and measures nothing):
##   WAR_GROUND_PLATES=1 WAR_SAVE_PATH=/tmp/probe_save.json \
##     WAR_VAULT_PATH=/tmp/probe_vault.json WAR_BOOT_RECOVERY_PATH=/tmp/probe_recovery.json \
##     godot --path client --resolution 1280x720 res://tools/plate_geometry_budget.tscn
##
## Redirect all three save seams: this boots the real launch path. Set
## `WAR_PLATE_BUDGET_SHOT_DIR=<dir>` to write `plates-off.png`, `plates-shader.png`
## (the shader's plate paint with the overlay hidden) and `plates-on.png` of the
## measured frame — the close-range before/after evidence the PR carries.
## Exit 0 is a pass within budget, 1 a measured failure, 2 an unusable
## measurement (headless, wrong resolution, no volumetrics, GPU timer silent).

const EXPECTED_SIZE := Vector2i(1280, 720)
const WARMUP_FRAMES := 150
const SETTLE_FRAMES := 60
const MEASURE_FRAMES := 600
## ADR 0001's prototype acceptance budget.
const BUDGET_P95_MS := 16.67
const BUDGET_DELTA_MS := 1.0
## Above this share of zero readings the GPU timer is judged silent.
const MAX_ZERO_FRACTION := 0.5
## The two states must move at least this share of the frame's pixels by more
## than FLICKER_STEP luma, or the camera is not looking at the treatment.
const MIN_STATE_DIFFERENCE := 0.005
const FLICKER_STEP := 0.05
## The two states whose frames are compared to prove the camera sees the overlay.
const COMPARED_STATES: Array[String] = ["shader", "on"]
## Walking-height eye relative to the nearest built slab's site: 4.8 m back and
## across, 1.6 m up — a player standing two strides away, looking down at it.
const EYE_OFFSET := Vector3(-3.4, 1.6, 3.4)

var _main: Node
var _world: WorldGen
var _cam: Camera3D
var _viewport_rid: RID
var _frames := {}


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_unusable("run WINDOWED — a headless run renders nothing and measures nothing")
		return
	_main = load("res://scenes/main.tscn").instantiate()
	get_tree().root.add_child.call_deferred(_main)
	await get_tree().process_frame
	for _i in WARMUP_FRAMES:
		await get_tree().process_frame

	_world = _main.get_node_or_null("World") as WorldGen
	if _world == null:
		_unusable("no WorldGen under World — nothing to measure")
		return
	var size := get_viewport().get_visible_rect().size
	if Vector2i(size) != EXPECTED_SIZE:
		_unusable("the viewport is %s, the budget is defined at %s — pass --resolution 1280x720"
			% [Vector2i(size), EXPECTED_SIZE])
		return
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	Engine.max_fps = 0
	if DisplayServer.window_get_vsync_mode() != DisplayServer.VSYNC_DISABLED:
		_unusable("VSync could not be disabled — a refresh-capped frame time measures the display, not the overlay")
		return
	var volumetrics := _volumetrics_enabled()
	if not volumetrics:
		_unusable("the shipping WorldEnvironment has volumetric fog OFF here — the budget is defined with it on")
		return

	if _world.ground_plates_stats().is_empty():
		print("  world booted with WAR_GROUND_PLATES off — building the overlay now")
		_world.set_ground_plates_enabled(true)
	var stats := _world.ground_plates_stats()
	if int(stats.get(&"built", 0)) <= 0:
		_unusable("the overlay built no slab: %s" % [stats])
		return
	_quiet_the_world()

	var site: Vector3 = stats[&"nearest_built_site"]
	_cam = Camera3D.new()
	_cam.fov = 68.0
	_cam.far = 400.0
	get_tree().root.add_child(_cam)
	_cam.global_position = site + EYE_OFFSET
	_cam.look_at(site + Vector3(0.0, 0.05, 0.0), Vector3.UP)
	_cam.current = true
	_viewport_rid = get_viewport().get_viewport_rid()
	RenderingServer.viewport_set_measure_render_time(_viewport_rid, true)

	# Three states of ONE build: the treatment off, the shader's plate path alone
	# (uniform on, overlay hidden — what shipped before this child), and the full
	# treatment with the raised overlay. The overlay's own cost is full minus
	# shader-only; the whole treatment's is full minus off. A final off pass
	# shows whether the floor drifted while the run was measuring.
	var off := await _measure("off", false, false)
	var shader := await _measure("shader", true, false)
	var on := await _measure("on", true, true)
	var off_again := await _measure("off-again", false, false)

	# A median frame time equal to the display's refresh period, in every state, is
	# the display pacing the window — not a render time. Measured on this host:
	# 13.333 ms in all four states, exactly the 75 Hz period, AFTER the VSync
	# read-back above reported DISABLED, so that read-back is necessary but not
	# sufficient (the compositor throttles an occluded or display-asleep window).
	# Every wall-clock delta would then read ~0 whatever the overlay costs, which is
	# the one reading this tool must never hand out.
	var refresh := DisplayServer.screen_get_refresh_rate()
	var period := 1000.0 / refresh if refresh > 0.0 else 0.0
	var medians := [float(off[&"wall_p50"]), float(shader[&"wall_p50"]), float(on[&"wall_p50"])]
	# Pinned medians alone prove nothing — three states could genuinely cost the
	# same — so the verdict keys on the DISPLAY PERIOD: a median within 2% of it is
	# the display. When the period cannot be read, pinned medians are the only
	# tell left, and the run is refused as unmeasurable rather than passed.
	var pinned := absf(medians[0] - medians[1]) < 0.05 and absf(medians[0] - medians[2]) < 0.05
	var paced := period > 0.0 and absf(medians[0] - period) < period * 0.02
	if paced or (pinned and period <= 0.0):
		_unusable(("wall-clock frame time is PACED — medians %.3f / %.3f / %.3f ms against a "
			+ "%.3f ms display period (0 = unreadable) — so the proxy measures the display, "
			+ "not the overlay; rerun with the display awake and the window focused and unoccluded")
			% [medians[0], medians[1], medians[2], period])
		return

	var state_difference := FrameMetrics.changed_fraction(
		_frames[COMPARED_STATES[0]], _frames[COMPARED_STATES[1]], FLICKER_STEP)
	if state_difference < MIN_STATE_DIFFERENCE:
		_unusable(("VACUOUS — the plates-off and plates-on frames differ on %.4f of pixels "
			+ "(need %.4f); the camera is not framing the treatment") % [state_difference, MIN_STATE_DIFFERENCE])
		return

	var draw_delta := int(on[&"draw_calls"]) - int(off[&"draw_calls"])
	print(("BUDGET REPORT resolution=%dx%d vsync=disabled volumetrics=%s frames=%d "
		+ "candidates=%d slabs=%d exposed=%d built=%d vertices=%d triangles=%d surfaces=%d "
		+ "draw_calls_off=%d draw_calls_on=%d draw_call_delta=%d primitives_off=%d primitives_on=%d "
		+ "gpu_off_p50=%.3f gpu_off_p95=%.3f gpu_off_max=%.3f "
		+ "gpu_shader_p95=%.3f gpu_on_p50=%.3f gpu_on_p95=%.3f gpu_on_max=%.3f gpu_off_again_p95=%.3f "
		+ "gpu_overlay_delta_p95=%.3f gpu_treatment_delta_p95=%.3f cpu_off_p95=%.3f cpu_on_p95=%.3f zero_off=%.3f zero_on=%.3f "
		+ "wall_off_p50=%.3f wall_off_p95=%.3f wall_shader_p95=%.3f wall_on_p50=%.3f wall_on_p95=%.3f wall_off_again_p95=%.3f "
		+ "wall_overlay_delta_p95=%.3f wall_treatment_delta_p95=%.3f "
		+ "state_difference=%.4f eye=%s site=%s")
		% [EXPECTED_SIZE.x, EXPECTED_SIZE.y, "on" if volumetrics else "off", MEASURE_FRAMES,
			int(stats[&"candidates"]), int(stats[&"slabs"]), int(stats[&"exposed"]),
			int(stats[&"built"]), int(stats[&"vertices"]), int(stats[&"triangles"]),
			int(stats[&"surfaces"]), int(off[&"draw_calls"]), int(on[&"draw_calls"]), draw_delta,
			int(off[&"primitives"]), int(on[&"primitives"]),
			float(off[&"gpu_p50"]), float(off[&"gpu_p95"]), float(off[&"gpu_max"]),
			float(shader[&"gpu_p95"]), float(on[&"gpu_p50"]), float(on[&"gpu_p95"]), float(on[&"gpu_max"]),
			float(off_again[&"gpu_p95"]),
			float(on[&"gpu_p95"]) - float(shader[&"gpu_p95"]),
			float(on[&"gpu_p95"]) - float(off[&"gpu_p95"]),
			float(off[&"cpu_p95"]), float(on[&"cpu_p95"]),
			float(off[&"zero_fraction"]), float(on[&"zero_fraction"]),
			float(off[&"wall_p50"]), float(off[&"wall_p95"]), float(shader[&"wall_p95"]), float(on[&"wall_p50"]),
			float(on[&"wall_p95"]), float(off_again[&"wall_p95"]),
			float(on[&"wall_p95"]) - float(shader[&"wall_p95"]),
			float(on[&"wall_p95"]) - float(off[&"wall_p95"]),
			state_difference, _cam.global_position, site])

	if float(off[&"zero_fraction"]) > MAX_ZERO_FRACTION or float(on[&"zero_fraction"]) > MAX_ZERO_FRACTION:
		_unusable(("GPU TIMER UNAVAILABLE — %.0f%% of plates-off and %.0f%% of plates-on readings "
			+ "were 0.0 ms; a silent timer is not free rendering. Wall-clock frame time is reported "
			+ "above as a GPU-bound PROXY only (p95 off %.3f ms, shader-only %.3f ms, on %.3f ms; "
			+ "overlay delta %.3f ms) — it can "
			+ "bound what a player feels, never stand in for the GPU budget")
			% [float(off[&"zero_fraction"]) * 100.0, float(on[&"zero_fraction"]) * 100.0,
				float(off[&"wall_p95"]), float(shader[&"wall_p95"]), float(on[&"wall_p95"]),
				float(on[&"wall_p95"]) - float(shader[&"wall_p95"])])
		return
	var delta := float(on[&"gpu_p95"]) - float(shader[&"gpu_p95"])
	var verdict := "BUDGET PASS" if float(on[&"gpu_p95"]) < BUDGET_P95_MS and delta <= BUDGET_DELTA_MS \
		else "BUDGET FAIL"
	print("%s — plates-on p95 GPU %.3f ms (budget %.2f), overlay adds %.3f ms p95 over the shader-only state (budget %.2f), %d draw call(s)"
		% [verdict, float(on[&"gpu_p95"]), BUDGET_P95_MS, delta, BUDGET_DELTA_MS, draw_delta])
	get_tree().quit(0 if verdict == "BUDGET PASS" else 1)


## Settle, then record MEASURE_FRAMES of measured GPU and CPU frame time for one
## state. The uniform and the overlay flip together through the world's own
## toggle, so nothing but the treatment differs between two calls.
func _measure(state: String, plates: bool, overlay_visible: bool) -> Dictionary:
	_world.set_ground_plates_enabled(plates)
	var overlay := _world.get_node_or_null(WorldGen.GROUND_PLATES_NODE) as MeshInstance3D
	if overlay != null:
		overlay.visible = plates and overlay_visible
	for _f in SETTLE_FRAMES:
		_cam.current = true
		await get_tree().process_frame
	var gpu := PackedFloat32Array()
	var cpu := PackedFloat32Array()
	var wall := PackedFloat32Array()
	var zeros := 0
	for _f in MEASURE_FRAMES:
		# Re-asserted every frame, as frame_capture does: the player's own camera
		# otherwise takes `current` back and the tool measures the cave interior.
		_cam.current = true
		await get_tree().process_frame
		var g := RenderingServer.viewport_get_measured_render_time_gpu(_viewport_rid)
		if g <= 0.0:
			zeros += 1
		gpu.append(g)
		cpu.append(RenderingServer.viewport_get_measured_render_time_cpu(_viewport_rid))
		wall.append(get_process_delta_time() * 1000.0)
	# Last frame's counters describe the settled state; every frame's would only
	# describe the same state 600 times over.
	var draw_calls := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
	var primitives := int(RenderingServer.get_rendering_info(
		RenderingServer.RENDERING_INFO_TOTAL_PRIMITIVES_IN_FRAME))
	if state in COMPARED_STATES:
		_frames[state] = FrameMetrics.luma_buffer(get_viewport().get_texture().get_image())
	_save_frame(state)
	gpu.sort()
	cpu.sort()
	wall.sort()
	print("  measured %s gpu p50=%.3f p95=%.3f max=%.3f cpu p95=%.3f wall p50=%.3f p95=%.3f zeros=%d/%d draw_calls=%d"
		% [state, FrameMetrics.percentile(gpu, 0.50), FrameMetrics.percentile(gpu, 0.95), gpu[gpu.size() - 1],
			FrameMetrics.percentile(cpu, 0.95), FrameMetrics.percentile(wall, 0.50), FrameMetrics.percentile(wall, 0.95),
			zeros, MEASURE_FRAMES, draw_calls])
	return {
		&"gpu_p50": FrameMetrics.percentile(gpu, 0.50),
		&"gpu_p95": FrameMetrics.percentile(gpu, 0.95),
		&"gpu_max": gpu[gpu.size() - 1],
		&"cpu_p95": FrameMetrics.percentile(cpu, 0.95),
		&"wall_p50": FrameMetrics.percentile(wall, 0.50),
		&"wall_p95": FrameMetrics.percentile(wall, 0.95),
		&"zero_fraction": float(zeros) / float(MEASURE_FRAMES),
		&"draw_calls": draw_calls,
		&"primitives": primitives,
	}



func _save_frame(state: String) -> void:
	var dir := OS.get_environment("WAR_PLATE_BUDGET_SHOT_DIR")
	if dir.is_empty():
		return
	var path := "%s/plates-%s.png" % [dir, state]
	if get_viewport().get_texture().get_image().save_png(path) != OK:
		push_warning("could not write %s" % path)


func _volumetrics_enabled() -> bool:
	for node in _main.find_children("*", "WorldEnvironment", true, false):
		var env := (node as WorldEnvironment).environment
		if env != null and env.volumetric_fog_enabled:
			return true
	return false


## Hide the movers and the HUD so nothing but the treatment changes between the
## states; the scenery stays, because the overlay is measured in the frame a
## player actually sees.
func _quiet_the_world() -> void:
	var hidden := FrameMetrics.quiet(_main, ["Wanderer", "Npcs", "Creatures", "Hud", "Replicas"])
	print("  quieted: %s" % ", ".join(hidden))


func _unusable(message: String) -> void:
	push_error(message)
	print("BUDGET UNAVAILABLE — %s" % message)
	get_tree().quit(2)
