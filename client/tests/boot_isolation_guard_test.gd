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
## safe to run locally and deterministic in CI. The failure and success laws use
## a small indentation-and-token control-flow parse: receivers stay tied to the
## one active redirect owner, `_fail()` callers cannot fall through to success,
## and the false guarantee result has to reach breach handling on both outcomes.
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

## A quit, and the only argument that means SUCCESS.
##
## The contract is "assert the guarantee on EVERY exit path", so a second failing
## exit that bypasses `_fail` would satisfy the law above while leaving the actual
## invariant unmet — checking `_fail` alone would then be checking a function
## nothing calls. Every booter today funnels its single failing quit through
## `_fail`; this keeps it that way.
##
## 🔴 Matched by EXCLUDING the success form, never by listing failure forms.
## Scanning for the literal `quit(1)` would miss `quit(2)`, `quit(ERROR_CODE)` and
## every other nonzero spelling — an allow-list of failures can only ever be
## incomplete, while the success argument is exactly two spellings and both are
## right here. Godot's `quit()` defaults to 0, so a bare call is also success.
const QUIT_CALL := "quit("
const SUCCESS_QUIT_ARGS := ["0", ""]

## The verdicts [method _verdict] can return. Shared by the scan loop and by
## every negative control, so a law and its control cannot drift apart.
const VERDICT_UNLOCATABLE := "unlocatable"
const VERDICT_UNGUARDED := "unguarded"
const VERDICT_NONTERMINAL := "nonterminal"
const VERDICT_STRAY := "stray:"
const VERDICT_FALLTHROUGH := "fallthrough"
const VERDICT_SUCCESS_UNGUARDED := "success-unguarded"

## Callable spellings that invoke a method without a direct `name(` — normalised
## back to a direct call before scanning, so one scanner covers them all.
## ⚠️ `.bind(` is deliberately ABSENT. It returns a new Callable and invokes
## nothing, so normalising `quit.bind(1)` to `quit(1)` would report a function
## that merely BUILDS a callable as terminating — the same naming-is-not-calling
## error one rung down, introduced by an over-eager fix and caught in review.
const DEFERRED_CALL_FORMS := [".call_deferred(", ".call(", ".callv("]

## Tokens that read a boolean IN PLACE, so the guarantee's answer is acted on
## right where it is produced.
##
## 🔴 Calling it is still not enough. `real_save_untouched()` clears the seams as
## a side effect, so a harness can swap a bare `end()` for a bare
## `_save.real_save_untouched()`, tear down exactly as before, discard the answer,
## and satisfy a presence-only check while asserting nothing. That is the third
## rung of the same ladder this guard keeps climbing: naming a class is not
## calling it, naming the call in prose is not calling it, and calling it without
## reading the result is not asserting it.
##
## Assignment is deliberately NOT in this list. `var untouched = …` with nothing
## reading `untouched` discards the answer just as thoroughly, so an assignment
## is accepted only when the bound name is mentioned again — see [method
## _assigned_name] and its use above.
const CONDITION_TOKENS := ["if ", "not ", "return ", "assert(", "and ", "or ", "while "]

## Line prefixes that begin a new TOP-LEVEL declaration, ending a function body.
##
## Not merely "an unindented line": a multiline string inside `_fail` can put
## content at column zero, and treating that as a declaration would truncate the
## body and reject a correctly-guarded booter over string formatting alone.
const DECLARATION_STARTS := [
	"func ", "static func ", "const ", "var ", "static var ", "@", "class ",
	"class_name", "signal ", "enum ", "extends ",
]

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

## A `_fail` that only NAMES the guarantee inside a diagnostic string while still
## tearing down with a bare `end()`. Mentioning a call is not making one, and a
## plain substring match cannot tell the two apart — the same
## naming-is-not-calling confusion [constant ISOLATION_CLAIMS] already documents
## one law up. Its `_fail` also opens a multiline string whose content starts at
## column zero, so it doubles as the control for [constant DECLARATION_STARTS]:
## a body boundary that stopped at any unindented line would truncate here and
## reach the wrong verdict for the right-looking reason.
const STRING_ONLY_FIXTURE := """func _fail(message: String) -> void:
	if _save != null:
		_save.end()
	push_error(\"\"\"
remember to call real_save_untouched( on the way out
\"\"\")
	get_tree().quit(1)
"""

## A `_fail` naming the guarantee in a TRAILING comment. Same bypass as
## [constant STRING_ONLY_FIXTURE] through a different door: [method _code_of]
## strips only whole-line comments, so this survives into the matched text.
const COMMENT_ONLY_FAIL_FIXTURE := """func _fail(message: String) -> void:
	if _save != null:
		_save.end()  # real_save_untouched( is what this SHOULD call
	get_tree().quit(1)
"""

## A booter whose `_fail` is compliant but which also exits nonzero elsewhere,
## spelled with an argument the old literal `quit(1)` scan could not see.
##
## The apostrophe in the trailing comment is deliberate: it is the unmatched quote
## that a literal-pass-then-comment-pass lexer treats as an opening string, which
## blanks everything after it — including the `quit(2)` below — and hides the very
## stray exit this fixture exists to catch. See [method _executable].
const STRAY_NONZERO_QUIT_FIXTURE := """func _on_timeout() -> void:
	push_error("timed out")  # don't wait forever
	get_tree().quit(2)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(1)
"""

## A `_fail` that CALLS the guarantee but throws the answer away, using it purely
## as teardown in place of a bare `end()`. Seams cleared, evidence discarded,
## nothing asserted — see [constant CONDITION_TOKENS].
const IGNORED_RESULT_FIXTURE := """func _fail(message: String) -> void:
	if _save != null:
		_save.real_save_untouched()
	get_tree().quit(1)
"""

## The result stored under a name that only ever appears as a SUBSTRING later.
## `push_error(message)` contains "error"; the answer is still discarded.
const SUBSTRING_NAME_FIXTURE := """func _fail(message: String) -> void:
	var error = _save.real_save_untouched()
	push_error(message)
	get_tree().quit(1)
"""

## A `_fail` that only BUILDS a callable and never invokes it, so nothing exits.
## `Callable.bind()` returns a Callable; it does not call one.
const BIND_ONLY_FIXTURE := """func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	var later = get_tree().quit.bind(1)
"""

## A booter with no `_fail` at all. Its failure path cannot be located, so the
## guard cannot vouch for it and must say so rather than pass it silently.
const NO_FAIL_FIXTURE := """func _ready() -> void:
	if not _save.real_save_untouched():
		push_error("touched")
		get_tree().quit(1)
	get_tree().quit(0)
"""

## The subtler form of the same discard: the answer is STORED and then never
## read. An assignment looks like a use and is not one.
const IGNORED_ASSIGNMENT_FIXTURE := """func _fail(message: String) -> void:
	var untouched = _save.real_save_untouched()
	get_tree().quit(1)
"""

## Negating the result gives it the right meaning but still asserts nothing when
## the bound name is never read.
const IGNORED_NEGATED_ASSIGNMENT_FIXTURE := """func _fail(message: String) -> void:
	var breached = not _save.real_save_untouched()
	get_tree().quit(1)
"""

## A `_fail` that asserts correctly and then exits SUCCESS. Every other law here
## assumes `_fail` is the failure funnel; if it quits 0 the suite reports a pass
## on an assertion failure.
const NONTERMINAL_FAIL_FIXTURE := """func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(0)
"""

## A failing exit reached through a callable rather than a direct call. Contains
## no `quit(` at all, so a scanner that splits on that literal sees nothing.
const DEFERRED_QUIT_FIXTURE := """func _on_timeout() -> void:
	get_tree().quit.call_deferred(2)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(1)
"""

## A compliant `_fail` followed by a `static var` initializer holding a failing
## exit. If `static var ` is missing from [constant DECLARATION_STARTS] the body
## absorbs the initializer, and subtracting that body then deletes the stray exit
## from the scan — the guard goes green over two faults at once.
const STATIC_VAR_BOUNDARY_FIXTURE := """func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(1)


static var _late_exit := func() -> void:
	get_tree().quit(2)
"""

## A positive-only branch reads the result but ignores the breach case. The
## guarantee is satisfied only when false reaches the failure outcome.
const POSITIVE_ONLY_GUARANTEE_FIXTURE := """var _save: SaveIsolation


func _fail(message: String) -> void:
	if _save != null and _save.real_save_untouched():
		push_error("save stayed isolated")
	get_tree().quit(1)
"""

## A `not` elsewhere in the condition does not negate the guarantee. The guard
## must understand the call's own polarity rather than search its line prefix.
const MISLEADING_NOT_GUARANTEE_FIXTURE := """var _save: SaveIsolation


func _fail(message: String) -> void:
	var other_breach := false
	if not other_breach and _save.real_save_untouched():
		push_error("save stayed isolated")
	get_tree().quit(1)
"""

## The result comes from a SaveIsolation object, but not the one whose begin()
## owns the active redirects. Type alone cannot prove the live scope was clean.
const STALE_OWNER_GUARANTEE_FIXTURE := """var _active: SaveIsolation
var _stale: SaveIsolation


func _ready() -> void:
	_stale = SaveIsolation.new("user://stale.json")
	_stale.begin()
	_stale.real_save_untouched()
	_active = SaveIsolation.new("user://active.json")
	_active.begin()


func _fail(message: String) -> void:
	if _stale != null and not _stale.real_save_untouched():
		message += " breached"
	get_tree().quit(1)
"""

## SceneTree.quit() does not halt the frame. A caller that invokes _fail() and
## then remains able to reach quit(0) can repaint a real failure as success.
const FAIL_CALL_FALLTHROUGH_FIXTURE := """var _save: SaveIsolation


func _ready() -> void:
	if _save == null:
		_fail("save owner missing")
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(1)
"""

## The failure funnel is compliant, but the successful exit never checks the
## active owner. Every booter must assert the guarantee on both outcomes.
const SUCCESS_PATH_UNGUARDED_FIXTURE := """var _save: SaveIsolation


func _ready() -> void:
	_save = SaveIsolation.new("user://success-path.json")
	_save.begin()
	if _save == null:
		_fail("save owner missing")
		return
	get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
	get_tree().quit(1)
"""

## Equal indentation is not dominance when statements live under sibling
## branches. The clean assertion below cannot vouch for the later success path.
const SIBLING_BRANCH_SUCCESS_FIXTURE := """var _save: SaveIsolation


func _ready() -> void:
	_save = SaveIsolation.new("user://sibling-branch.json")
	_save.begin()
	if OS.has_feature("guard-branch"):
		if not _save.real_save_untouched():
			_fail("save isolation breached")
			return
	if OS.has_feature("success-branch"):
		get_tree().quit(0)


func _fail(message: String) -> void:
	if _save != null and not _save.real_save_untouched():
		message += " breached"
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
	var stray_exit := PackedStringArray()
	var nonterminal := PackedStringArray()
	var fallthrough := PackedStringArray()
	var success_unguarded := PackedStringArray()
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
		# Literals are blanked first, so naming the call in a message is not
		# mistaken for making it (STRING_ONLY_FIXTURE).
		var verdict := _verdict(code)
		match verdict:
			VERDICT_UNLOCATABLE: unlocatable.append(file)
			VERDICT_UNGUARDED: unguarded.append(file)
			VERDICT_NONTERMINAL: nonterminal.append(file)
			VERDICT_FALLTHROUGH: fallthrough.append(file)
			VERDICT_SUCCESS_UNGUARDED: success_unguarded.append(file)
			_:
				if verdict.begins_with(VERDICT_STRAY):
					stray_exit.append("%s (quit(%s))"
						% [file, verdict.trim_prefix(VERDICT_STRAY)])

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

	if not nonterminal.is_empty():
		_fail(("%d booter(s) have a `%s` that does not exit with a failure status: %s — a `_fail` "
			+ "that quits 0, or does not quit at all, is not a failure funnel, and every other law "
			+ "here assumes it is one: an assertion failure would report success or hang (#326)")
			% [nonterminal.size(), FAIL_FUNC, ", ".join(nonterminal)])
		return
	if not fallthrough.is_empty():
		_fail(("%d booter(s) can continue from `%s` into a success exit: %s — SceneTree.quit() "
			+ "does not halt the current frame, so return from the caller's path before a later "
			+ "quit(0) can overwrite the failure status")
			% [fallthrough.size(), FAIL_FUNC, ", ".join(fallthrough)])
		return
	if not success_unguarded.is_empty():
		_fail(("%d booter(s) reach a success exit without asserting the active isolation owner: "
			+ "%s — every quit(0) path must handle a false real_save_untouched() result before "
			+ "reporting success")
			% [success_unguarded.size(), ", ".join(success_unguarded)])
		return
	if not stray_exit.is_empty():
		_fail(("%d booter(s) exit failing WITHOUT going through `%s`: %s — a nonzero quit outside "
			+ "that body skips the isolation check entirely, so the guarantee is asserted on one "
			+ "exit path and not the others. Route every failing exit through `_fail` (#326)")
			% [stray_exit.size(), FAIL_FUNC, ", ".join(stray_exit)])
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
	if _verdict(PASS_PATH_ONLY_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a harness that asserts the guarantee ONLY on its pass path — the "
			+ "failure-path classification has widened to whole-file matching, which passes every "
			+ "harness in this repo including the five this law was written for (#326)"))
		return

	# --- negative control: naming the call in a string is not calling it ---
	if not STRING_ONLY_FIXTURE.contains(GUARANTEE_CALL):
		_fail("the string-only fixture no longer names the guarantee, so it cannot prove that a "
			+ "mention is rejected — restore it")
		return
	if _fail_body(_executable(STRING_ONLY_FIXTURE)).is_empty():
		_fail(("the string-only fixture's `_fail` body vanished — the body boundary is stopping at "
			+ "the multiline string inside it rather than at a real declaration, so a correctly "
			+ "guarded booter would be rejected over string formatting alone"))
		return

	# --- negative control: naming the call in a COMMENT is not calling it ---
	if not COMMENT_ONLY_FAIL_FIXTURE.contains(GUARANTEE_CALL):
		_fail("the comment-only fixture no longer names the guarantee — restore it")
		return
	if _verdict(COMMENT_ONLY_FAIL_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a `_fail` that names the guarantee only in a TRAILING comment — "
			+ "comment stripping has regressed. `_code_of` keeps trailing comments on purpose, which "
			+ "is safe for booter detection and a bypass here (#326)"))
		return

	# --- negative control: calling the guarantee is not asserting it ---
	if not IGNORED_RESULT_FIXTURE.contains(GUARANTEE_CALL):
		_fail("the ignored-result fixture no longer calls the guarantee — restore it")
		return
	if _verdict(IGNORED_RESULT_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a `_fail` that calls the guarantee and DISCARDS its answer — "
			+ "using it as a bare teardown clears the seams exactly as `end()` did while asserting "
			+ "nothing, so presence alone cannot be the test (#326)"))
		return

	# --- negative control: a substring is not an identifier ---
	if _verdict(SUBSTRING_NAME_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a `_fail` whose stored result is only matched as a SUBSTRING of a "
			+ "later token (`error` inside `push_error`) — the answer is never read (#326)"))
		return

	# --- negative control: binding a callable is not calling it ---
	if _verdict(BIND_ONLY_FIXTURE) != VERDICT_NONTERMINAL:
		_fail(("the guard treated `quit.bind(1)` as a terminating exit — `Callable.bind()` returns a "
			+ "callable and invokes nothing, so that `_fail` never sets a failure status (#326)"))
		return

	# --- negative control: a booter with no locatable failure path ---
	if _verdict(NO_FAIL_FIXTURE) != VERDICT_UNLOCATABLE:
		_fail(("the guard vouched for a booter with no `%s` at all — a failure path it cannot find "
			+ "is one it cannot check, and every law here assumes that body exists") % FAIL_FUNC)
		return

	# --- negative control: storing the answer is not reading it ---
	if _verdict(IGNORED_ASSIGNMENT_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a `_fail` that assigns the guarantee's result to a variable it "
			+ "never reads — an assignment token alone cannot stand for a use (#326)"))
		return
	if _verdict(IGNORED_NEGATED_ASSIGNMENT_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a negated guarantee stored in a variable that is never read — "
			+ "`not` gives the value breach semantics but does not assert it"))
		return

	# --- negative control: `_fail` must itself exit nonzero ---
	if _verdict(NONTERMINAL_FAIL_FIXTURE) != VERDICT_NONTERMINAL:
		_fail(("the non-terminal fixture reads as exiting nonzero — the `_fail`-terminates check "
			+ "cannot detect a `_fail` that quits 0, so an assertion failure would report success"))
		return

	# --- negative control: a callable quit is still a quit ---
	var deferred_stray := _verdict(DEFERRED_QUIT_FIXTURE).trim_prefix(VERDICT_STRAY)
	if deferred_stray != "2":
		_fail(("the stray-exit scan missed `quit.call_deferred(2)` (got '%s') — a failing exit "
			+ "reached through a callable contains no `quit(` and bypasses the isolation "
			+ "assertion (#326)") % deferred_stray)
		return

	# --- negative control: `static var` ends a function body ---
	var sv_stray := _verdict(STATIC_VAR_BOUNDARY_FIXTURE).trim_prefix(VERDICT_STRAY)
	if sv_stray != "2":
		_fail(("a `static var` initializer after `_fail` was absorbed into its body (stray exit "
			+ "read '%s', expected '2') — the body boundary must treat `static var` as a "
			+ "declaration, or subtracting the body also hides the exit") % sv_stray)
		return

	# --- negative control: the clean case cannot stand in for breach handling ---
	if _verdict(POSITIVE_ONLY_GUARANTEE_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a positive-only `real_save_untouched()` branch — printing when "
			+ "the save is clean does not handle the false breach case"))
		return
	if _verdict(MISLEADING_NOT_GUARANTEE_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted a positive-only guarantee because an unrelated operand was "
			+ "negated earlier in the condition — polarity must belong to the guarantee call"))
		return

	# --- negative control: the guarantee must come from the active owner ---
	if _verdict(STALE_OWNER_GUARANTEE_FIXTURE) != VERDICT_UNGUARDED:
		_fail(("the guard accepted `real_save_untouched()` from a stale SaveIsolation instance — "
			+ "the receiver must be the object whose begin()/boot() owns the active redirects"))
		return

	# --- negative control: `_fail()` must stop its caller's path ---
	if _verdict(FAIL_CALL_FALLTHROUGH_FIXTURE) != VERDICT_FALLTHROUGH:
		_fail(("the guard accepted a `_fail()` call that falls through to quit(0) — "
			+ "SceneTree.quit() does not stop the current frame, so success can overwrite failure"))
		return

	# --- negative control: every booter checks the successful exit too ---
	if _verdict(SUCCESS_PATH_UNGUARDED_FIXTURE) != VERDICT_SUCCESS_UNGUARDED:
		_fail(("the guard accepted a booter whose `_fail` is guarded but whose success path reaches "
			+ "quit(0) without asserting the active isolation owner's guarantee"))
		return
	if _verdict(SIBLING_BRANCH_SUCCESS_FIXTURE) != VERDICT_SUCCESS_UNGUARDED:
		_fail(("the guard accepted a guarantee in one sibling branch as dominating quit(0) in "
			+ "another — equal indentation does not imply shared control flow"))
		return

	# --- negative control: a nonzero quit is not only `quit(1)` ---
	var stray_control := _verdict(STRAY_NONZERO_QUIT_FIXTURE).trim_prefix(VERDICT_STRAY)
	if stray_control != "2":
		_fail(("the stray-exit scan no longer recognises `quit(2)` outside `_fail` (got '%s') — it "
			+ "has narrowed to specific failure spellings instead of excluding the success form, so "
			+ "any other nonzero exit bypasses the isolation assertion (#326)") % stray_control)
		return

	# --- negative control: a column-zero line is not automatically a declaration ---
	# Pinned on the helper directly, because the fixture above CANNOT prove it:
	# blanking literals already removes the column-zero content, so a boundary
	# that stopped at any unindented line would still reach the right verdict
	# there — for the wrong reason. This is the only check that distinguishes the
	# two rules.
	if _starts_declaration("still_inside_the_body()"):
		_fail(("the body boundary treats any column-zero line as a declaration — a multiline string "
			+ "inside `_fail` would truncate the body and reject a correctly guarded booter over "
			+ "string formatting alone (DECLARATION_STARTS)"))
		return
	if not _starts_declaration("func _ready() -> void:"):
		_fail("the body boundary no longer recognises a real declaration, so a `_fail` body would "
			+ "run past the end of its function and pick up unrelated code")
		return
	if _guards_failure_path(STRING_ONLY_FIXTURE):
		_fail(("the guard accepted a `_fail` that only NAMES the guarantee in a diagnostic string "
			+ "while still tearing down with a bare end() — mentioning a call is not making one, "
			+ "the same confusion ISOLATION_CLAIMS guards one law up"))
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

	print(("TEST PASS — %d test(s) boot %s through one active isolation owner, every failure and "
		+ "success exit handles a false guarantee, and no `_fail()` call falls through to success; "
		+ "prose-only mention in %s is ignored and pass-path-only code is rejected "
		+ "(%d booter(s) assert on the pass path too)")
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


## THE single per-file verdict: "" when the file is compliant, otherwise which
## law it breaks ([constant VERDICT_STRAY] carries the offending quit argument).
##
## 🔴 Every control below runs its fixture through THIS function, and that is the
## whole reason it exists. Before it, each control tested a detector in isolation
## — so deleting a law's CALL SITE from the scan loop left every control green,
## including deletion of this PR's core `unguarded` law. Detectors were pinned;
## the wiring that consults them was not. Routing both the loop and the controls
## through one verdict closes that: a branch removed here fails the fixture that
## expects it.
func _verdict(code: String) -> String:
	var executable := _executable(code)
	var fail_body := _fail_body(executable)
	if fail_body.is_empty():
		return VERDICT_UNLOCATABLE
	if not _guards_failure_path(code):
		return VERDICT_UNGUARDED
	# A `_fail` that exits 0 — or does not exit at all — is not a failure funnel,
	# and every other law here assumes it is one.
	if _nonzero_quit(fail_body).is_empty():
		return VERDICT_NONTERMINAL
	if _fail_call_falls_through(executable):
		return VERDICT_FALLTHROUGH
	if not _success_paths_guarded(executable):
		return VERDICT_SUCCESS_UNGUARDED
	# A guarded `_fail` proves nothing if some other path also exits failing
	# without going through it.
	var stray := _nonzero_quit(executable.replace(fail_body, ""))
	return "" if stray.is_empty() else VERDICT_STRAY + stray


## Whether any `_fail()` caller can keep running until a success quit in the
## same function. This is an indentation-and-token control-flow parse, not a
## "next line must be return" shape: a call at a function's end is terminal,
## and a call in one branch does not execute a sibling else/elif branch.
func _fail_call_falls_through(code: String) -> bool:
	var lines := code.split("\n")
	var current_function := ""
	for i in lines.size():
		var line: String = lines[i]
		if _starts_function(line):
			current_function = _function_name(line)
			continue
		if _starts_declaration(line):
			current_function = ""
		if current_function.is_empty() or current_function == "_fail":
			continue
		var call_at := line.find("_fail(")
		if call_at < 0:
			continue
		var before := line.substr(0, call_at)
		if _mentions_identifier(before, "return"):
			continue
		var function_end := _function_end(lines, i)
		var statement_end := _statement_end(lines, i, function_end)
		var call_indent := _indent_of(line)
		var j := statement_end + 1
		while j < function_end:
			var following: String = lines[j]
			var trimmed := following.strip_edges()
			if trimmed.is_empty():
				j += 1
				continue
			var indent := _indent_of(following)
			if indent < call_indent and (trimmed.begins_with("else:")
					or trimmed.begins_with("elif ")):
				j = _block_end(lines, j, function_end)
				continue
			if indent <= call_indent and _starts_return(trimmed):
				break
			if _has_success_quit(following):
				return true
			j += 1
	return false


func _starts_function(line: String) -> bool:
	return not line.begins_with(" ") and not line.begins_with("\t") \
		and (line.begins_with("func ") or line.begins_with("static func "))


func _function_name(line: String) -> String:
	var declaration := line.trim_prefix("static ").trim_prefix("func ")
	var open := declaration.find("(")
	return declaration.substr(0, open).strip_edges() if open >= 0 else ""


func _function_end(lines: PackedStringArray, from: int) -> int:
	for i in range(from + 1, lines.size()):
		if _starts_declaration(lines[i]):
			return i
	return lines.size()


func _statement_end(lines: PackedStringArray, start: int, limit: int) -> int:
	var depth := 0
	for i in range(start, limit):
		for ch: String in lines[i]:
			if ch == "(":
				depth += 1
			elif ch == ")":
				depth -= 1
		if depth <= 0:
			return i
	return limit - 1


func _block_end(lines: PackedStringArray, start: int, limit: int) -> int:
	var block_indent := _indent_of(lines[start])
	for i in range(start + 1, limit):
		var line: String = lines[i]
		if line.strip_edges().is_empty():
			continue
		if _indent_of(line) <= block_indent:
			return i
	return limit


func _indent_of(line: String) -> int:
	var indent := 0
	for ch: String in line:
		if ch == "\t":
			indent += 1
		elif ch == " ":
			indent += 1
		else:
			break
	return indent


func _starts_return(line: String) -> bool:
	return line == "return" or line.begins_with("return ")


func _has_success_quit(line: String) -> bool:
	var direct := line
	for form: String in DEFERRED_CALL_FORMS:
		direct = direct.replace(form, "(")
	var parts := direct.split(QUIT_CALL)
	for i in range(1, parts.size()):
		var close := (parts[i] as String).find(")")
		if close < 0:
			continue
		var arg := (parts[i] as String).substr(0, close).strip_edges()
		if arg in SUCCESS_QUIT_ARGS:
			return true
	return false


## Does this code assert the isolation guarantee on its FAILURE path?
##
## THE single classification point, deliberately: [constant
## PASS_PATH_ONLY_FIXTURE] is judged by this same function, so widening it to a
## whole-file match makes that control fail immediately instead of silently
## passing every harness in the repo.
func _guards_failure_path(code: String) -> bool:
	var executable := _executable(code)
	var active_owners := _active_isolation_owners(executable)
	if active_owners.size() > 1:
		return false
	var lines := _fail_body(executable).split("\n")
	for i in lines.size():
		var line: String = lines[i]
		if not line.contains(GUARANTEE_CALL):
			continue
		var receiver := _call_receiver(line, "." + GUARANTEE_CALL)
		# Full harnesses identify the active redirect owner by the receiver that
		# actually invokes begin()/boot(). A same-typed stale object proves
		# nothing about the live scope. Partial synthetic fixtures without a
		# setup path keep exercising their narrower classification law.
		if not active_owners.is_empty() and receiver not in active_owners:
			continue
		var before := line.substr(0, line.find(GUARANTEE_CALL))
		# `true` means clean; the assertion has to route the FALSE result into
		# the failure outcome. Merely reading the positive case is observational
		# logging, not breach handling.
		if not _call_is_negated(line, "." + GUARANTEE_CALL):
			continue
		# Stored in a variable. That counts only if a LATER line reads it:
		# `var untouched = not _save.real_save_untouched()` with no further
		# mention still discards the answer.
		var name := _assigned_name(before)
		if not name.is_empty():
			for j in range(i + 1, lines.size()):
				if _mentions_identifier(lines[j], name):
					return true
			continue
		# Used directly in a condition — the answer is read on this line.
		# 🔴 Word-boundary matched, not `contains`: `var error = ` ends with
		# "or ", so a substring test reads an ordinary assignment as a boolean
		# operator. Found by this file's own SUBSTRING_NAME_FIXTURE.
		for token: String in CONDITION_TOKENS:
			if _mentions_identifier(before, token.strip_edges()):
				return true
	return false


## Every success quit in a full booter is immediately dominated by a negative
## guarantee check on the same active owner. Partial unit fixtures without a
## begin()/boot() setup keep testing their narrower failure-path laws.
func _success_paths_guarded(code: String) -> bool:
	var active_owners := _active_isolation_owners(code)
	if active_owners.is_empty():
		return true
	if active_owners.size() > 1:
		return false
	var lines := code.split("\n")
	var current_function := ""
	var function_start := 0
	for i in lines.size():
		var line: String = lines[i]
		if _starts_function(line):
			current_function = _function_name(line)
			function_start = i
			continue
		if _starts_declaration(line):
			current_function = ""
		if current_function.is_empty() or current_function == "_fail" \
				or not _has_success_quit(line):
			continue
		if not _success_exit_has_guard(lines, function_start, i, active_owners):
			return false
	return true


func _success_exit_has_guard(
		lines: PackedStringArray,
		function_start: int,
		success_line: int,
		active_owners: PackedStringArray,
) -> bool:
	var success_indent := _indent_of(lines[success_line])
	for i in range(success_line - 1, function_start, -1):
		var line: String = lines[i]
		if _indent_of(line) > success_indent or not line.contains(GUARANTEE_CALL) \
				or not _scope_dominates(lines, function_start, i, success_line):
			continue
		var receiver := _call_receiver(line, "." + GUARANTEE_CALL)
		if receiver not in active_owners \
				or not _call_is_negated(line, "." + GUARANTEE_CALL) \
				or not line.strip_edges().begins_with("if "):
			continue
		var block_end := _block_end(lines, i, success_line + 1)
		var calls_fail := false
		var returns := false
		for j in range(i + 1, block_end):
			var branch_line := lines[j].strip_edges()
			calls_fail = calls_fail or branch_line.contains("_fail(")
			returns = returns or _starts_return(branch_line)
		if calls_fail and returns:
			return true
	return false


## A statement dominates a later statement only when it lives in the same
## active block ancestry or an enclosing one. Indentation alone cannot
## distinguish two sibling branches whose nested statements share a column.
func _scope_dominates(
		lines: PackedStringArray,
		function_start: int,
		guard_line: int,
		success_line: int,
) -> bool:
	var guard_scope := _block_ancestry(lines, function_start, guard_line)
	var success_scope := _block_ancestry(lines, function_start, success_line)
	if guard_scope.size() > success_scope.size():
		return false
	for i in guard_scope.size():
		if guard_scope[i] != success_scope[i]:
			return false
	return true


func _block_ancestry(
		lines: PackedStringArray,
		function_start: int,
		target_line: int,
) -> PackedInt32Array:
	var ancestry := PackedInt32Array()
	for i in range(function_start + 1, target_line):
		var line: String = lines[i]
		var trimmed := line.strip_edges()
		if trimmed.is_empty():
			continue
		var indent := _indent_of(line)
		while not ancestry.is_empty() and indent <= _indent_of(lines[ancestry[-1]]):
			ancestry.remove_at(ancestry.size() - 1)
		if trimmed.ends_with(":"):
			ancestry.append(i)
	var target_indent := _indent_of(lines[target_line])
	while not ancestry.is_empty() and target_indent <= _indent_of(lines[ancestry[-1]]):
		ancestry.remove_at(ancestry.size() - 1)
	return ancestry


## Receivers that actually invoke an isolation boundary in executable code.
## The caller still checks the class/call pair through [_claims_isolation]; this
## list adds the object identity that the old bare-token match discarded.
func _active_isolation_owners(code: String) -> PackedStringArray:
	var owners := PackedStringArray()
	for line: String in code.split("\n"):
		for owner: String in ISOLATION_CLAIMS:
			var receiver := _call_receiver(line, ISOLATION_CLAIMS[owner])
			if not receiver.is_empty() and receiver not in owners:
				owners.append(receiver)
	return owners


## The simple identifier immediately receiving `call`, or "" for a computed
## receiver. Isolation owners in this corpus are named fields by design; a
## computed receiver cannot be tied across begin()/boot() and teardown safely.
func _call_receiver(line: String, call: String) -> String:
	var call_at := line.find(call)
	if call_at <= 0:
		return ""
	var start := call_at - 1
	while start >= 0 and _is_ident_char(line[start]):
		start -= 1
	var receiver := line.substr(start + 1, call_at - start - 1)
	return receiver if receiver.is_valid_identifier() else ""


## Whether unary `not` applies to this call itself. An unrelated `not` earlier
## in the expression does not change the guarantee's polarity. Parentheses
## between the operator and receiver are transparent; paired negations cancel.
func _call_is_negated(line: String, call: String) -> bool:
	var call_at := line.find(call)
	if call_at <= 0:
		return false
	var receiver_start := call_at - 1
	while receiver_start >= 0 and _is_ident_char(line[receiver_start]):
		receiver_start -= 1
	var prefix := line.substr(0, receiver_start + 1).strip_edges()
	var negations := 0
	while not prefix.is_empty():
		while prefix.ends_with("("):
			prefix = prefix.trim_suffix("(").strip_edges()
		if not prefix.ends_with("not"):
			break
		var not_start := prefix.length() - "not".length()
		if not_start > 0 and _is_ident_char(prefix[not_start - 1]):
			break
		negations += 1
		prefix = prefix.substr(0, not_start).strip_edges()
	return negations % 2 == 1


## Does `line` use `name` as a whole identifier?
##
## 🔴 A substring test is not good enough and was a real bug here:
## `var error = _save.real_save_untouched()` followed by `push_error(message)`
## contains "error" and would read as a use, so the result stayed unread while
## the guard went green. Identifier characters on either side disqualify a match.
func _mentions_identifier(line: String, name: String) -> bool:
	var at := line.find(name)
	while at >= 0:
		var before_ok := at == 0 or not _is_ident_char(line[at - 1])
		var end := at + name.length()
		var after_ok := end >= line.length() or not _is_ident_char(line[end])
		if before_ok and after_ok:
			return true
		at = line.find(name, at + 1)
	return false


func _is_ident_char(ch: String) -> bool:
	return ch == "_" or ch.is_valid_identifier() or ch.is_valid_int()


## The variable an assignment prefix binds to, or "" when the prefix is not an
## assignment. Handles `x =`, `var x =` and `var x: T :=`.
func _assigned_name(before: String) -> String:
	var eq := before.find("=")
	if eq < 0:
		return ""
	var lhs := before.substr(0, eq).strip_edges().trim_suffix(":")
	lhs = lhs.trim_prefix("var ").trim_prefix("static var ").strip_edges()
	# Drop an explicit type annotation: `x: bool` binds `x`.
	var colon := lhs.find(":")
	if colon >= 0:
		lhs = lhs.substr(0, colon).strip_edges()
	return lhs if lhs.is_valid_identifier() else ""


## `code` reduced to what actually RUNS: string contents blanked, then comments
## removed. Both are needed, and only together.
##
## 🔴 The comment pass must come AFTER the literal pass, never before: a `#`
## inside a string is not a comment, and stripping comments first would truncate
## at it and destroy the rest of the line.
##
## ⚠️ Scoped to the failure-path law, NOT used by booter detection — the same
## asymmetry as the literal blanking inside [method _executable], and for a
## sharper reason. [method
## _code_of] deliberately keeps a TRAILING comment, and its doc calls that
## "err[ing] toward demanding isolation, which is the safe direction". That is
## true when the token being matched means "this file boots" — a stray mention
## demands isolation. It inverts here: a trailing `# real_save_untouched(` would
## make an UNGUARDED `_fail` read as guarded, so the same leniency that is safe
## one law up is a bypass in this one. Same limitation, opposite direction.
## 🔴 ONE pass, not two. Stripping literals and then comments looks equivalent and
## is not: an apostrophe in a trailing comment — `foo()  # don't wait` — opens a
## string literal that never closes, so the blanking runs on past the newline and
## erases real code below it. A `get_tree().quit(2)` a few lines down then
## vanishes from [method _nonzero_quit] and the stray exit it represents goes
## unreported while this guard stays green. The reverse order fails too, because
## a `#` inside a string is not a comment. Only a single lexer that knows which
## state it is in gets both right.
func _executable(code: String) -> String:
	var out := ""
	var i := 0
	var quote := ""
	var triple := false
	var in_comment := false
	while i < code.length():
		var ch := code[i]
		if in_comment:
			# A comment runs to end-of-line and nothing inside it is code —
			# quotes included, which is the whole point of this branch.
			if ch == "\n":
				in_comment = false
				out += "\n"
			else:
				out += " "
			i += 1
			continue
		if quote.is_empty():
			if ch == "#":
				in_comment = true
				out += " "
				i += 1
				continue
			if ch == "\"" or ch == "'":
				triple = code.substr(i, 3) == ch.repeat(3)
				quote = ch
				out += "   " if triple else " "
				i += 3 if triple else 1
				continue
			out += ch
			i += 1
			continue
		# Inside a literal: a backslash escapes the next character, so a `\"`
		# must not be mistaken for the closing quote.
		if not triple and ch == "\\":
			out += "  "
			i += 2
			continue
		var closes := code.substr(i, 3) == quote.repeat(3) if triple else ch == quote
		if closes:
			out += "   " if triple else " "
			i += 3 if triple else 1
			quote = ""
			continue
		out += "\n" if ch == "\n" else " "
		i += 1
	return out


## The argument of the first non-success `quit(...)` in `region`, or "" when every
## quit there is a success quit. Used on the code OUTSIDE `_fail`.
##
## Returns the offending argument rather than a bool so the failure message can
## name it — a guard that says only "something is wrong" costs the next person a
## bisect.
func _nonzero_quit(region: String) -> String:
	# `quit.call_deferred(2)` is a real failing exit that contains no `quit(`.
	# Normalising the callable forms back to a direct call keeps ONE scanner
	# instead of a growing list of spellings to match.
	var direct := region
	for form: String in DEFERRED_CALL_FORMS:
		direct = direct.replace(form, "(")
	var parts := direct.split(QUIT_CALL)
	for i in range(1, parts.size()):
		var rest: String = parts[i]
		var close := rest.find(")")
		if close < 0:
			continue
		var arg := rest.substr(0, close).strip_edges()
		if arg not in SUCCESS_QUIT_ARGS:
			return arg
	return ""


## Does this line begin a new top-level declaration? See [constant
## DECLARATION_STARTS] for why "unindented" alone is not the test.
func _starts_declaration(line: String) -> bool:
	if line.is_empty() or line.begins_with("\t") or line.begins_with(" "):
		return false
	for token: String in DECLARATION_STARTS:
		if line.begins_with(token):
			return true
	return false


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
		if _starts_declaration(line):
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
