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

## What is actually matched: the BARE filename, not the full path.
##
## Deliberately the loosest token that still means "this file boots the scene",
## for two reasons. It catches every spelling — `load(...)`, `preload(...)`, a
## path assembled from a constant — where matching the full path only catches
## the one spelling in use today. And it is what makes stripping comments
## load-bearing: the doc comments in this repo write the bare `main.tscn`, so a
## guard matching the full path would ignore prose by accident rather than by
## design, and [constant COMMENT_ONLY_CONTROL] would pass while proving nothing.
const SCENE_TOKEN := "main.tscn"

## Reaching the main scene WITHOUT naming it: Godot hands back the configured
## main scene, so the file never contains [constant SCENE_TOKEN] at all. Third
## way a file counts as a booter — without it, indirection is a silent bypass.
const SETTING_TOKEN := "application/run/main_scene"

## Booting through the helper. A harness that uses it never names the scene at
## all — that is the point — so this is the second way a file counts as a booter.
const HELPER := "IsolatedBoot"

## Driving the seams directly. Legitimate when a harness must act BETWEEN the
## redirect and the boot: `vault_restore_boot_test` seeds vault fixtures there.
const SELF_ISOLATION := "SaveIsolation"

## 🔴 NAMING A CLASS IS NOT CALLING IT. Isolation happens in [method
## IsolatedBoot.boot] and [method SaveIsolation.begin] — constructing either and
## then loading the scene yourself redirects nothing. Matching only the class
## name let `IsolatedBoot.new(...)` followed by a raw `load(MAIN_SCENE)` pass as
## isolated: the substring that was supposed to prove isolation was satisfied by
## the very file that skipped it. So each claim requires its class AND its call.
const ISOLATION_CLAIMS := {
	HELPER: ".boot(",
	SELF_ISOLATION: ".begin(",
}

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

## The failure exit path a booter funnels through, and the guarantee it must
## assert there (#326).
##
## Redirecting the seams is only half the law: a run that DID touch the real
## save proves it by comparing the before/after bytes, and
## [method SaveIsolation.real_save_untouched] is the only thing that makes that
## comparison. A `_fail` that tears down with a bare `end()` clears the seams and
## deletes the probes, discarding the evidence — so an isolation breach exits
## reporting whatever gameplay assertion happened to fail first, which is the
## hardest possible state to diagnose and the same invisibility that let #309
## persist. Both isolation owners expose the call, so the law is one token for
## harnesses driving [SaveIsolation] and those going through [IsolatedBoot].
const FAIL_FUNC := "func _fail("
const GUARANTEE_CALL := "real_save_untouched("

## A synthetic harness asserting the guarantee on its PASS path and NOT on its
## failure path — the exact shape #326 found in five files.
##
## 🔴 This is the one misclassification that would make the law vacuous. Whole-
## file matching passes EVERY harness in this repo, including all five with the
## defect, because they all assert on the way out of a SUCCESSFUL run; that is
## precisely why the gap survived review. A guard that regressed to
## `code.contains(GUARANTEE_CALL)` would therefore go green over the defect it
## exists to catch.
##
## Synthetic rather than a real file on purpose: it pins the discrimination
## itself, so the control cannot be quietly voided by someone editing whichever
## harness it happened to point at.
const PASS_PATH_ONLY_FIXTURE := """func _ready() -> void:
	if not _save.real_save_untouched():
		_fail("the boot test touched the player's real save")
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	get_tree().quit(1)
"""


func _ready() -> void:
	var sources := _test_sources()
	if sources.is_empty():
		_fail("scanned %s and found no .gd files — the guard is reading the wrong place" % TESTS_DIR)
		return

	var booters := PackedStringArray()
	var unisolated := PackedStringArray()
	var unguarded := PackedStringArray()
	var unlocatable := PackedStringArray()
	for file: String in sources:
		if file in EXEMPT:
			continue
		var source := _read(TESTS_DIR + "/" + file)
		if source.is_empty():
			_fail("could not read %s — a file the guard cannot read is a file it cannot vouch for" % file)
			return
		var code := _code_of(source)
		# Three ways to reach the scene: name it and load it yourself, ask Godot
		# for the configured one, or go through the helper (which names it for
		# you). All three count as booting; none of them is self-evidently safe.
		var reaches_scene := (code.contains(SCENE_TOKEN) or code.contains(SETTING_TOKEN)
			or code.contains(HELPER))
		if not reaches_scene:
			continue
		booters.append(file)
		if not _claims_isolation(code):
			unisolated.append(file)
		# The failure path is checked separately from the file as a whole — see
		# PASS_PATH_ONLY_FIXTURE for why that scoping is the load-bearing part.
		var fail_body := _fail_body(code)
		if fail_body.is_empty():
			unlocatable.append(file)
		elif not _guards_failure_path(code):
			unguarded.append(file)

	# --- the law ---
	if not unisolated.is_empty():
		_fail(("%d test(s) reach %s without redirecting the save seams: %s — call IsolatedBoot.boot() "
			+ "(or SaveIsolation.begin() when you must act between the redirect and the boot) so the "
			+ "run can never touch the player's real save or vault. Naming the class is not enough; "
			+ "the call is what redirects (#309)")
			% [unisolated.size(), MAIN_SCENE, ", ".join(unisolated)])
		return

	# --- the same law, on the way out (#326) ---
	if not unlocatable.is_empty():
		_fail(("%d booter(s) have no `%s` body this guard can locate: %s — the failure path is where "
			+ "an isolation breach would be reported, so a booter whose failure path cannot be found "
			+ "is one this guard cannot vouch for. Funnel failures through `_fail`, or teach this "
			+ "guard the new shape")
			% [unlocatable.size(), FAIL_FUNC, ", ".join(unlocatable)])
		return
	if not unguarded.is_empty():
		_fail(("%d booter(s) tear down on failure without asserting the isolation guarantee: %s — call "
			+ "%s on the failure path too (it clears the seams itself, so it replaces the bare "
			+ "`end()` rather than adding a second teardown). Otherwise a run that touched the "
			+ "player's real save discards that evidence and exits reporting an unrelated gameplay "
			+ "failure instead (#326)")
			% [unguarded.size(), ", ".join(unguarded), GUARANTEE_CALL])
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
	if not control.contains(SCENE_TOKEN):
		_fail(("the control %s no longer mentions the main scene at all, so it cannot prove the "
			+ "guard ignores prose — repoint COMMENT_ONLY_CONTROL") % COMMENT_ONLY_CONTROL)
		return
	if _code_of(control).contains(SCENE_TOKEN):
		_fail(("the control %s reads as a booter — it should mention the main scene only in a "
			+ "comment; either it now really boots the scene, or comment stripping has regressed")
			% COMMENT_ONLY_CONTROL)
		return
	if COMMENT_ONLY_CONTROL in booters:
		_fail(("the guard classified %s as a booter from its doc comment alone — this is the exact "
			+ "false positive #309's proposed grep would have shipped") % COMMENT_ONLY_CONTROL)
		return

	# --- negative control: pass-path code does not satisfy the failure-path law ---
	if not PASS_PATH_ONLY_FIXTURE.contains(GUARANTEE_CALL):
		_fail(("the pass-path fixture no longer asserts the guarantee at all, so it cannot prove "
			+ "whole-file matching would be vacuous — restore it to a harness that asserts on the "
			+ "PASS path only"))
		return
	var fixture_body := _fail_body(PASS_PATH_ONLY_FIXTURE)
	if fixture_body.is_empty():
		_fail("the pass-path fixture's `_fail` body could not be located — body extraction is broken")
		return
	if _guards_failure_path(PASS_PATH_ONLY_FIXTURE):
		_fail(("the guard accepted a harness that asserts the guarantee ONLY on its pass path — the "
			+ "failure-path classification has widened to whole-file matching, which passes every "
			+ "harness in this repo including the five this law was written for (#326)"))
		return

	# --- and the real corpus is the shape that makes the scoping matter ---
	var pass_path_assertors := 0
	for file: String in booters:
		var code := _code_of(_read(TESTS_DIR + "/" + file))
		if code.replace(_fail_body(code), "").contains(GUARANTEE_CALL):
			pass_path_assertors += 1
	if pass_path_assertors == 0:
		_fail(("no booter asserts the guarantee outside its `_fail` body — the corpus no longer has "
			+ "the shape that makes whole-file matching vacuous, so the scoping above is untested "
			+ "against real files"))
		return

	print(("TEST PASS — %d test(s) boot %s, all isolated and all asserting the guarantee on their "
		+ "failure path; prose-only mention in %s correctly ignored, and pass-path-only code is "
		+ "correctly rejected (%d booter(s) assert on the pass path too)")
		% [booters.size(), MAIN_SCENE, COMMENT_ONLY_CONTROL, pass_path_assertors])
	get_tree().quit(0)


## Does this code actually redirect the seams, rather than merely mention the
## class that would? Requires the class AND its isolating call, because holding
## a constructed [IsolatedBoot] while loading the scene yourself isolates
## nothing — see [constant ISOLATION_CLAIMS].
func _claims_isolation(code: String) -> bool:
	for owner: String in ISOLATION_CLAIMS:
		if code.contains(owner) and code.contains(ISOLATION_CLAIMS[owner]):
			return true
	return false


## Does this code assert the isolation guarantee on its FAILURE path?
##
## THE single classification point, deliberately: [constant
## PASS_PATH_ONLY_FIXTURE] is judged by this same function, so widening it to a
## whole-file match makes that control fail immediately instead of silently
## passing every harness in the repo.
func _guards_failure_path(code: String) -> bool:
	return _fail_body(code).contains(GUARANTEE_CALL)


## The body of the `_fail` function in already-comment-stripped `code`, or ""
## when the file declares none.
##
## Scoped to the function rather than the file on purpose: every booter here
## asserts the guarantee on its PASS path, so a file-wide match is satisfied by
## code that never runs when the test fails — see [constant
## PASS_PATH_ONLY_FIXTURE].
##
## The body ends at the next TOP-LEVEL declaration, which in GDScript is the
## next non-empty line starting at column 0. Nested blocks stay in, because they
## are indented; a trailing `_fail` at end-of-file ends at EOF.
##
## Limitation, stated rather than hidden: only the FIRST `_fail` declaration is
## read. GDScript cannot overload, so a second one is a redefinition error the
## engine rejects before this guard ever runs.
func _fail_body(code: String) -> String:
	var body := PackedStringArray()
	var inside := false
	for line: String in code.split("\n"):
		if not inside:
			if line.begins_with(FAIL_FUNC):
				inside = true
			continue
		if not line.is_empty() and not (line.begins_with("\t") or line.begins_with(" ")):
			break
		body.append(line)
	return "\n".join(body) if inside else ""


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
