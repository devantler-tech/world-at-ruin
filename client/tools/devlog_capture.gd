extends Node
## Render the in-game dev log to a PNG, for the evidence a player-visible
## dev-log change has to attach.
##
## `frame_capture.tscn` shoots fixed world vantages, so it cannot depict the F1
## panel — the log is a `Control` over the world, and no vantage frames it. A
## dev-log change is player-visible all the same, so it needs its own frame or
## the evidence rule has no way to be satisfied for this surface.
##
## SCROLLED TO THE BOTTOM on purpose. The log runs newest-first, so the top of
## the panel is whatever shipped most recently and the oldest entries — the ones
## a change to the historical block actually alters — are off-screen. A shot of
## the default scroll position would be a frame of the log rather than a frame
## of the change, which is the failure the evidence rule exists to prevent.
##
## Run (must be WINDOWED — a headless run renders nothing at all):
##   WAR_SHOT_DIR=/tmp/devlog godot --path client res://tools/devlog_capture.tscn
##
## Writes `<WAR_SHOT_DIR>/devlog-bottom.png` at the shipped viewport size.

## The shipped viewport (`project.godot`'s `window/size/viewport_*`), so the
## frame shows the layout a player gets rather than whatever window the harness
## happened to open.
const WINDOW := Vector2i(1600, 900)

## Frames to settle before reading the viewport. The panel builds its text on
## first open and the scroll bar's range only becomes valid once the label has
## laid that text out, so a read on the first frame captures an unscrolled panel.
const SETTLE_FRAMES := 4


func _ready() -> void:
	var dir := OS.get_environment("WAR_SHOT_DIR")
	if dir.is_empty():
		_fail("WAR_SHOT_DIR is not set — nowhere to write the frame")
		return
	if DisplayServer.get_name() == "headless":
		_fail("running headless — a headless run renders nothing; use a windowed run")
		return

	get_tree().root.size = WINDOW
	var hud := Hud.new()
	add_child(hud)
	await get_tree().process_frame

	# The same two steps F1 performs, driven directly: the capture has no input
	# dispatch, and going through `_unhandled_input` would make the frame depend
	# on the input map rather than on the log.
	hud._devlog_label.text = hud._render_devlog()
	hud._devlog_panel.visible = true
	for i in SETTLE_FRAMES:
		await get_tree().process_frame

	var bar := hud._devlog_label.get_v_scroll_bar()
	if bar == null:
		_fail("the dev-log label has no vertical scroll bar — cannot reach the oldest entries")
		return
	# `max_value` is the CONTENT extent, not the last reachable offset, so the
	# bottom of the log sits one page below it.
	hud._devlog_label.scroll_to_line(hud._devlog_label.get_line_count() - 1)
	for i in SETTLE_FRAMES:
		await get_tree().process_frame

	var img := get_viewport().get_texture().get_image()
	var out := dir.path_join("devlog-bottom.png")
	var err := img.save_png(out)
	if err != OK:
		_fail("could not write %s (error %d)" % [out, err])
		return
	print("CAPTURE OK — %s (%dx%d)" % [out, img.get_width(), img.get_height()])
	get_tree().quit(0)


func _fail(message: String) -> void:
	push_error(message)
	print("CAPTURE FAIL — %s" % message)
	get_tree().quit(1)
