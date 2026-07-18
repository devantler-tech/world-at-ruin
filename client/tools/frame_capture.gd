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

	var cave_count := await _capture_cave(cam, dir, main)
	if cave_count < 0:
		return

	print("CAPTURE PASS — %d vantages written to %s" % [VANTAGES.size() + cave_count, dir])
	get_tree().quit(0)


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
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
			[vantage_name, out, img.get_width(), img.get_height(), spread, _size_note(img)])
		captured += 1
	return captured


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
func _under_rock(cam: Camera3D) -> bool:
	var space := cam.get_world_3d().direct_space_state
	var from := cam.global_position
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.UP * 60.0)
	query.collide_with_areas = false
	return not space.intersect_ray(query).is_empty()


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
