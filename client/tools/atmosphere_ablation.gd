extends Node

## Measures WHICH part of the atmosphere flattens ground colour, and by how much
## (#273), by rendering the same frame twice with only the ground's albedo
## changed and reading how much of that change survives to the screen.
##
## #260 shipped four ground regions whose baked vertex colours span a 3.1x luma
## range, and almost none of it reaches the player: measured at 0.005-0.010 luma
## at distance and 0.034 standing on a region. That number is the SYMPTOM. This
## tool exists because the fix depends on the CAUSE, and "fog, probably" is a
## guess — the issue asks for a measurement per candidate.
##
## [b]Method.[/b] The independent variable is a known albedo ratio, applied
## through [code]terrain.gdshader[/code]'s [code]albedo_probe[/code] uniform:
## render at 1.0, render at [constant REGION_RATIO], and take the difference in
## mean ground luminance. That difference is "how much of a region step you can
## see". Then neutralise one atmosphere term at a time and re-measure it. A term
## whose removal makes the difference jump is a term that was eating it.
##
## Varying albedo rather than moving the camera between two real regions is the
## whole point: two regions sit on different ground, so their slopes, props and
## shadowing differ and the measurement would confound geometry with palette.
## Here the frame is identical in every respect but the one under test.
##
## [b]Reporting only.[/b] Nothing here gates anything. It prints a table meant to
## be pasted into the issue and the PR that acts on it.
##
## Run it windowed, with every save seam redirected (see [code]_ready[/code]):
## [codeblock]
## WAR_SAVE_PATH=... WAR_VAULT_PATH=... WAR_BOOT_RECOVERY_PATH=... \
##   godot --path client res://tools/atmosphere_ablation.tscn
## [/codeblock]

## The baked luma ratio between the palest region (bonepale, 0.437) and the
## darkest (cinderreach, 0.140), from #273's measured table. Using the real
## spread rather than a round number keeps the reported delta directly
## comparable to the figures in the issue.
const REGION_RATIO := 3.1

## Frames to let the renderer settle after a camera move or an environment
## change. Deliberately generous: volumetric fog is temporally reprojected, so a
## froxel volume needs several frames to converge on the new parameters. Reading
## too early would credit a term with a change that is really just the volume
## still catching up — and that error would look exactly like a discovery.
const SETTLE_FRAMES := 24

## Warmup before the first measurement, matching `frame_capture`.
const WARMUP_FRAMES := 30

## Where each vantage's ground actually is in frame, as fractions of the
## viewport (x0, x1, y0, y1). Hand-placed against the committed baseline shots
## so each box sits on terrain rather than on sky, ruins or the HUD — and
## verified at runtime by the vacuity guard below rather than trusted.
const GROUND_BOXES := {
	# Standing on the pale country: ground fills the lower half of the frame.
	"bonepale": [0.20, 0.80, 0.58, 0.92],
	# Looking across the ruin field: the ground band sits below the horizon and
	# above the near lip, and this is the distance case #273 says is worst.
	"crossfield": [0.20, 0.80, 0.55, 0.80],
}

## The vantages, copied from `frame_capture.VANTAGES` so the two tools frame the
## same world. Near-field and mid-distance, because #273's finding is that the
## two behave very differently and a single vantage would hide that.
const VANTAGES := [
	["bonepale", Vector3(-58.0, 5.5, 2.0), Vector3(-72.0, 1.0, -4.0)],
	["crossfield", Vector3(55.0, 11.0, 40.0), Vector3(-10.0, 3.0, -20.0)],
]

## Grid density for the mean-luminance read. 32x24 = 768 samples per box, which
## is dense enough that the mean is stable against the shader's grain without
## costing a visible fraction of the run.
const GRID_X := 32
const GRID_Y := 24

## The delta the `all-off` condition must clear for the run to mean anything.
## With every atmospheric term neutralised, a 3.1x albedo change MUST move the
## measured box substantially; if it does not, the box is not looking at
## terrain and every other row in the table is measuring nothing. This is the
## guard that stops a mis-placed sample box from being reported as a discovery.
const VACUITY_FLOOR := 0.05

var _env: Environment = null
var _terrain_mat: ShaderMaterial = null


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		_fail("running headless — nothing renders; use a windowed run")
		return

	# Same fail-closed seam guard as `frame_capture`: this tool boots the shipped
	# main scene, which is the real launch path and will read and rewrite the
	# player's own save, vault and recovery ledger if left unredirected. Compare
	# the RESOLVED path canonically — an unset seam and one aimed at the shipped
	# default both land on the real file, and `user://x` and its globalized
	# absolute path are one file spelled two ways.
	for seam: Array in [
			[CharacterStore.SAVE_PATH_ENV, CharacterStore.save_path(), CharacterStore.DEFAULT_PATH],
			[SaveVault.VAULT_PATH_ENV, SaveVault.vault_path(), SaveVault.DEFAULT_PATH],
			[BootRecovery.RECOVERY_PATH_ENV, BootRecovery.recovery_path(), BootRecovery.DEFAULT_PATH]]:
		if _canonical(String(seam[1])) == _canonical(String(seam[2])):
			_fail(("%s resolves to the player's real file (%s) — refusing to boot the game against "
				+ "real player state. Point every save seam at a throwaway path first.") % [seam[0], seam[2]])
			return

	var main_scene: String = ProjectSettings.get_setting("application/run/main_scene", "")
	if main_scene.is_empty():
		_fail("application/run/main_scene is unset — cannot measure the shipped game")
		return
	var main: Node = load(main_scene).instantiate()
	get_tree().root.add_child.call_deferred(main)
	await get_tree().process_frame
	await get_tree().process_frame
	if not main.is_inside_tree():
		_fail("the main scene never attached — nothing would have been rendered")
		return

	for i in WARMUP_FRAMES:
		await get_tree().process_frame

	if not _bind(main):
		return

	var cam := Camera3D.new()
	cam.far = 400.0
	cam.fov = 68.0
	get_tree().root.add_child(cam)

	await _run(cam)
	get_tree().quit(0)


## Finds the two objects the measurement drives: the live Environment and the
## terrain's ShaderMaterial. Both are looked up structurally and the run aborts
## if either is missing — silently skipping a condition would print a table of
## zeroes that reads like "this term does nothing".
func _bind(main: Node) -> bool:
	var world_env := main.get_node_or_null("WorldEnvironment") as WorldEnvironment
	if world_env == null or world_env.environment == null:
		_fail("no WorldEnvironment under Main — nothing to ablate")
		return false
	_env = world_env.environment

	var world := main.get_node_or_null("World")
	if world == null:
		_fail("the world did not build (no World node)")
		return false
	for child in world.get_children():
		if child is MeshInstance3D and str(child.name) == "Terrain":
			var mi := child as MeshInstance3D
			_terrain_mat = mi.material_override as ShaderMaterial
			if _terrain_mat == null and mi.mesh != null:
				_terrain_mat = mi.mesh.surface_get_material(0) as ShaderMaterial
			break
	if _terrain_mat == null:
		_fail("the terrain carries no ShaderMaterial — cannot drive albedo_probe")
		return false
	# Prove the instrument is actually there. Setting a shader parameter that does
	# not exist is silently accepted by Godot, so without this the whole run would
	# report a flat zero delta for every condition — a broken instrument reading
	# exactly like an atmosphere that ignores albedo.
	var has_probe := false
	for uniform: Dictionary in _terrain_mat.shader.get_shader_uniform_list():
		if String(uniform.get("name", "")) == "albedo_probe":
			has_probe = true
			break
	if not has_probe:
		_fail("terrain.gdshader has no `albedo_probe` uniform — the instrument is missing")
		return false
	return true


func _run(cam: Camera3D) -> void:
	# Snapshot every value any condition touches, so each condition is measured
	# against the shipped atmosphere rather than against the previous ablation's
	# leftovers. Restoring after each row is what makes the rows independent.
	var shipped := {
		"fog_enabled": _env.fog_enabled,
		"fog_density": _env.fog_density,
		"fog_aerial_perspective": _env.fog_aerial_perspective,
		"fog_sky_affect": _env.fog_sky_affect,
		"ambient_light_energy": _env.ambient_light_energy,
		"tonemap_mode": _env.tonemap_mode,
		"tonemap_white": _env.tonemap_white,
		"tonemap_exposure": _env.tonemap_exposure,
		"adjustment_enabled": _env.adjustment_enabled,
		"volumetric_fog_enabled": _env.volumetric_fog_enabled,
	}

	# One row per candidate the issue names, plus the two controls. Each entry is
	# [label, {property: neutralised value}] — a data table rather than branching
	# code, so adding a candidate is a line and the report order is the read order.
	var conditions: Array = [
		["baseline (as shipped)", {}],
		["fog off entirely", {"fog_enabled": false}],
		["aerial perspective 0", {"fog_aerial_perspective": 0.0}],
		["fog density 0", {"fog_density": 0.0}],
		["volumetric fog off", {"volumetric_fog_enabled": false}],
		["ambient energy 0", {"ambient_light_energy": 0.0}],
		["tonemap LINEAR", {"tonemap_mode": Environment.TONE_MAPPER_LINEAR}],
		["tonemap white 2.0", {"tonemap_white": 2.0}],
		["colour adjustment off", {"adjustment_enabled": false}],
		["ALL OFF (ceiling)", {
			"fog_enabled": false,
			"volumetric_fog_enabled": false,
			"ambient_light_energy": 0.0,
			"tonemap_mode": Environment.TONE_MAPPER_LINEAR,
			"adjustment_enabled": false,
		}],
	]

	print("ABLATION — albedo ratio %.2fx, %d samples/box" % [REGION_RATIO, GRID_X * GRID_Y])
	print("| vantage | condition | luma @1.0x | luma @%.1fx | delta | vs baseline |" % REGION_RATIO)
	print("|---|---|---|---|---|---|")

	var failures: Array[String] = []
	for vantage: Array in VANTAGES:
		var vname: String = vantage[0]
		cam.global_position = vantage[1]
		cam.look_at(vantage[2], Vector3.UP)
		for i in SETTLE_FRAMES:
			cam.current = true
			await get_tree().process_frame

		var box: Array = GROUND_BOXES[vname]
		var baseline_delta := 0.0
		var ceiling_delta := 0.0

		for condition: Array in conditions:
			var label: String = condition[0]
			var overrides: Dictionary = condition[1]
			for key: String in overrides:
				_env.set(key, overrides[key])
			for i in SETTLE_FRAMES:
				await get_tree().process_frame

			var lo := await _mean_luma(box)
			_terrain_mat.set_shader_parameter("albedo_probe", REGION_RATIO)
			for i in SETTLE_FRAMES:
				await get_tree().process_frame
			var hi := await _mean_luma(box)
			_terrain_mat.set_shader_parameter("albedo_probe", 1.0)

			var delta := hi - lo
			if label.begins_with("baseline"):
				baseline_delta = delta
			if label.begins_with("ALL OFF"):
				ceiling_delta = delta
			var rel := "—"
			if baseline_delta > 0.0001 and not label.begins_with("baseline"):
				rel = "%+.0f%%" % ((delta / baseline_delta - 1.0) * 100.0)
			print("| %s | %s | %.4f | %.4f | **%.4f** | %s |" % [vname, label, lo, hi, delta, rel])

			# Restore before the next row so conditions never compound.
			for key: String in shipped:
				_env.set(key, shipped[key])
			for i in SETTLE_FRAMES:
				await get_tree().process_frame

		# The vacuity guard. With the whole atmosphere neutralised a 3.1x albedo
		# change must move this box hard; anything less means the box is not on
		# terrain, and then every delta above it is noise wearing a table's
		# clothes. Collected rather than thrown so both vantages get reported.
		if ceiling_delta < VACUITY_FLOOR:
			failures.append(("%s: ALL-OFF delta %.4f is below the %.2f vacuity floor — the sample box "
				+ "is not reading terrain, so this vantage's rows measure nothing")
				% [vname, ceiling_delta, VACUITY_FLOOR])
		else:
			var survives := 0.0
			if ceiling_delta > 0.0:
				survives = baseline_delta / ceiling_delta * 100.0
			print("| %s | **SURVIVES** | | | **%.4f / %.4f** | **%.1f%%** |"
				% [vname, baseline_delta, ceiling_delta, survives])

	if failures.is_empty():
		print("ABLATION PASS")
	else:
		for message: String in failures:
			push_error(message)
		print("ABLATION FAIL — %d vantage(s) failed the vacuity guard" % failures.size())


## Mean luminance over a dense grid inside a fractional box of the frame.
##
## A MEAN, not a spread: the question is where the whole ground band sits in
## value, and a spread would answer a different one (how varied it is) and would
## barely move when the entire band shifts together — which is exactly what an
## albedo change does.
func _mean_luma(box: Array) -> float:
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var x0: float = box[0] * img.get_width()
	var y0: float = box[2] * img.get_height()
	var span_x: float = (box[1] - box[0]) * img.get_width()
	var span_y: float = (box[3] - box[2]) * img.get_height()
	var total := 0.0
	for gy in GRID_Y:
		for gx in GRID_X:
			total += img.get_pixel(
				int(x0 + (gx + 0.5) * span_x / float(GRID_X)),
				int(y0 + (gy + 0.5) * span_y / float(GRID_Y))).get_luminance()
	return total / float(GRID_X * GRID_Y)


func _canonical(path: String) -> String:
	return ProjectSettings.globalize_path(path).simplify_path()


func _fail(message: String) -> void:
	push_error(message)
	print("ABLATION FAIL — %s" % message)
	get_tree().quit(1)
