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
## Against the EXPORTED client the scene argument is unavailable — the official
## export template refuses positional scene paths (compiled with
## disable_path_overrides) — so main.gd carries a WAR_CAPTURE=1 boot redirect
## into this scene instead:
##   WAR_CAPTURE=1 WAR_SHOT_DIR=/tmp/shots WAR_SAVE_PATH=/tmp/probe_save.json \
##     "World at Ruin.app/Contents/MacOS/World at Ruin"
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
## Frames to settle after a preset switch: it rebuilds the portrait rig, so an
## immediate shot photographs the previous body.
const UI_SETTLE_FRAMES := 30


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
		var cave_note := _size_note(img)
		print("CAPTURED %s -> %s (%dx%d, luma spread %.3f)%s" %
			[vantage_name, out, img.get_width(), img.get_height(), spread, cave_note])
		_write_note(dir, vantage_name, img, cave_note)
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
	scroll.scroll_vertical = int(scroll.get_v_scroll_bar().max_value)
	await get_tree().process_frame
	if scroll.scroll_vertical <= 0:
		_fail("the creator's control list did not scroll — its lower sections would go unphotographed")
		return
	if not await _shoot(dir, "first_run_lower", creator):
		return
	shots += 1
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

	print("CAPTURE PASS — %d first-run vantages written to %s" % [shots, dir])
	get_tree().quit(0)


## Captures one creator frame, re-checking the panel is really on screen first:
## a preset switch rebuilds the portrait and could take the panel with it, and a
## frame of bare world would otherwise be saved under a first-run name.
func _shoot(dir: String, frame: String, creator: CanvasLayer) -> bool:
	if _visible_panel_area(creator) <= 0.0:
		_fail("%s: the creator has no visible panel — the frame would be the world behind a transparent layer" % frame)
		return false
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


## The creator's scrolling control list.
func _find_scroll(node: Node) -> ScrollContainer:
	for child in node.get_children():
		if child is ScrollContainer:
			return child as ScrollContainer
		var found := _find_scroll(child)
		if found != null:
			return found
	return null



## Writes the frame's own provenance next to it, so the artifact carries what
## the log knows. Best-effort: failing to write a note must never fail a capture
## that succeeded.
## `ground` names the region the camera stands on, where that is meaningful —
## empty for the cave vantages, which are underground and belong to no region.
func _write_note(dir: String, frame: String, img: Image, note: String, ground: String = "") -> void:
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
	var verdict := terrain_contribution_verdict(pts, live_a, live_b, hidden)
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
static func terrain_contribution_verdict(points: Array[Vector2i], live_a: Image, live_b: Image, hidden: Image) -> Dictionary:
	var verdict := {
		"ok": false, "reason": "", "quiet": 0, "contributing": 0,
		"fraction": 0.0, "noise_p95": 0.0, "median_change": 0.0,
	}
	if points.size() < CONTRIB_MIN_POINTS:
		verdict["reason"] = "only %d bare-terrain samples (floor %d) — too few to measure contribution" % [points.size(), CONTRIB_MIN_POINTS]
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
		verdict["reason"] = "only %d of %d terrain samples were quiet across the live pair (floor %d) — too much frame motion to measure the terrain's contribution" % [quiet, points.size(), CONTRIB_MIN_QUIET]
		return verdict
	var fraction := float(contributing) / float(quiet)
	verdict["fraction"] = fraction
	if fraction < CONTRIB_MIN_FRACTION:
		verdict["reason"] = "hiding the terrain changed only %d of %d quiet terrain samples (%.0f%%, floor %.0f%%) — the terrain contributes no pixels, exactly what a transparent or discard-everything material renders" % [contributing, quiet, fraction * 100.0, CONTRIB_MIN_FRACTION * 100.0]
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


func _fail(message: String) -> void:
	push_error(message)
	print("CAPTURE FAIL — %s" % message)
	get_tree().quit(1)
