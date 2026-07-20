extends Node
## Guard: no test may boot the main scene without redirecting the save seams
## (#309).
##
## Booting `main.tscn` runs the game's real launch path, which reads — and on the
## first-run path writes — the player's character save and progression vault.
## Two harnesses did that against the real files on every local run. It never
## showed up in CI (ephemeral runners) and never failed loudly: a test killed
## mid-run just left state the next real launch inherited.
##
## Conventions do not survive the eighth harness, so this makes the rule
## mechanical: a test whose CODE instantiates the main scene must go through
## [IsolatedBoot] (preferred — booting and isolating become one act) or drive
## [SaveIsolation] itself, which is what `vault_restore_boot_test` does because
## it has to seed vault fixtures between the redirect and the boot. Either way
## the seams are redirected by the one class that knows what they are, so a seam
## added there reaches every harness without a test changing.
##
## 🔴 IT MATCHES CODE, NEVER PROSE — and that distinction is the whole point.
## #309 was filed off a plain grep for `main.tscn` across `client/tests/`, which
## reported SEVEN unisolated harnesses. Five of those seven never boot the scene
## at all: they say so in a doc comment ("Pure and headless: builds WorldGen
## directly (never main.tscn)"), and the grep matched the sentence denying it.
## A guard built that way would go red on five correct files, and the obvious
## way to quiet it would be to delete honest documentation. So comment lines are
## stripped before matching, and [constant COMMENT_ONLY_CONTROL] keeps a
## permanent negative control on exactly that confusion.
##
## Pure logic only — reads test sources, boots nothing, writes nothing — so it is
## safe to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/boot_isolation_guard_test.tscn

const TESTS_DIR := "res://tests"

## The scene whose instantiation demands isolation.
const MAIN_SCENE := "res://scenes/main.tscn"

## Booting through the helper. A harness that uses it never names the scene at
## all — that is the point — so this is the second way a file counts as a booter.
const HELPER := "IsolatedBoot"

## Driving the seams directly. Legitimate when a harness must act BETWEEN the
## redirect and the boot: `vault_restore_boot_test` seeds vault fixtures there.
const SELF_ISOLATION := "SaveIsolation"

## Not harnesses. `isolated_boot.gd` names the scene because it is the helper
## that loads it, and this guard names it because it is the string it matches on.
const EXEMPT := ["isolated_boot.gd", "boot_isolation_guard_test.gd"]

## Booters known to exist today. A scan finding fewer than this has broken
## (wrong directory, unreadable files, a changed scene path) — without this
## floor a guard that silently reads nothing reports a clean build.
const MIN_BOOTERS := 7

## A file that mentions the main scene ONLY in a comment. Pins the prose-vs-code
## distinction above as an executable control: if the guard ever regresses to
## plain text matching, this file gets classified as a booter and the test
## fails. Named explicitly so that deleting its doc comment cannot quietly turn
## the control vacuous — it fails loudly instead.
const COMMENT_ONLY_CONTROL := "world_gen_determinism_test.gd"


func _ready() -> void:
	var sources := _test_sources()
	if sources.is_empty():
		_fail("scanned %s and found no .gd files — the guard is reading the wrong place" % TESTS_DIR)
		return

	var booters := PackedStringArray()
	var unisolated := PackedStringArray()
	for file: String in sources:
		if file in EXEMPT:
			continue
		var source := _read(TESTS_DIR + "/" + file)
		if source.is_empty():
			_fail("could not read %s — a file the guard cannot read is a file it cannot vouch for" % file)
			return
		var code := _code_of(source)
		# Two ways to boot: name the scene and load it yourself, or go through
		# the helper (which names it for you). Both count; only the first can
		# be unisolated, because the helper cannot hand back an unisolated scene.
		var names_scene := code.contains(MAIN_SCENE)
		var uses_helper := code.contains(HELPER)
		if not names_scene and not uses_helper:
			continue
		booters.append(file)
		if names_scene and not uses_helper and not code.contains(SELF_ISOLATION):
			unisolated.append(file)

	# --- the law ---
	if not unisolated.is_empty():
		_fail(("%d test(s) instantiate %s without redirecting the save seams: %s — boot through "
			+ "IsolatedBoot so the run can never reach the player's real save or vault (#309)")
			% [unisolated.size(), MAIN_SCENE, ", ".join(unisolated)])
		return

	# --- the guard is not passing vacuously ---
	if booters.size() < MIN_BOOTERS:
		_fail(("found only %d test(s) booting %s, expected at least %d — the scan is broken, and a "
			+ "broken scan reports a clean build") % [booters.size(), MAIN_SCENE, MIN_BOOTERS])
		return

	# --- negative control: prose is not code ---
	if COMMENT_ONLY_CONTROL not in sources:
		_fail(("the comment-only control %s is gone — restore it or point the control at another "
			+ "file that mentions the main scene only in a comment, or the prose-vs-code "
			+ "distinction stops being tested") % COMMENT_ONLY_CONTROL)
		return
	var control := _read(TESTS_DIR + "/" + COMMENT_ONLY_CONTROL)
	if not control.contains(MAIN_SCENE.get_file()):
		_fail(("the control %s no longer mentions the main scene at all, so it cannot prove the "
			+ "guard ignores prose — repoint COMMENT_ONLY_CONTROL") % COMMENT_ONLY_CONTROL)
		return
	if _code_of(control).contains(MAIN_SCENE):
		_fail(("the control %s reads as a booter — it should mention the main scene only in a "
			+ "comment; either it now really boots the scene, or comment stripping has regressed")
			% COMMENT_ONLY_CONTROL)
		return
	if COMMENT_ONLY_CONTROL in booters:
		_fail(("the guard classified %s as a booter from its doc comment alone — this is the exact "
			+ "false positive #309's proposed grep would have shipped") % COMMENT_ONLY_CONTROL)
		return

	print("TEST PASS — %d test(s) boot %s, all isolated; prose-only mention in %s correctly ignored"
		% [booters.size(), MAIN_SCENE, COMMENT_ONLY_CONTROL])
	get_tree().quit(0)


## Every `.gd` under the tests directory, sorted so a failure names the same
## file run to run.
func _test_sources() -> PackedStringArray:
	var dir := DirAccess.open(TESTS_DIR)
	if dir == null:
		return PackedStringArray()
	var found := PackedStringArray()
	for file: String in dir.get_files():
		# Godot reports imported/remapped resources with a trailing extension;
		# take the underlying script either way.
		var script_name := file.trim_suffix(".remap").trim_suffix(".uid")
		if script_name.ends_with(".gd") and script_name not in found:
			found.append(script_name)
	found.sort()
	return found


func _read(path: String) -> String:
	var handle := FileAccess.open(path, FileAccess.READ)
	if handle == null:
		return ""
	return handle.get_as_text()


## The source with whole-line comments removed, so a doc comment describing the
## main scene is not mistaken for code that boots it.
##
## Limitation, stated rather than hidden: a comment TRAILING code on the same
## line is not stripped, so `foo() # see main.tscn` would still read as a
## booter. That errs toward demanding isolation, which is the safe direction,
## and no file in the repo does it.
func _code_of(source: String) -> String:
	var code := PackedStringArray()
	for line: String in source.split("\n"):
		if not line.strip_edges().begins_with("#"):
			code.append(line)
	return "\n".join(code)


func _fail(message: String) -> void:
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
