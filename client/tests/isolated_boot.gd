class_name IsolatedBoot
extends RefCounted
## The ONE way a test boots `main.tscn`.
##
## Booting the main scene runs the game's real launch path, which reads — and on
## the first-run path writes — every file the player's state lives in. A test
## that instantiates the scene itself has to remember to redirect each of those
## seams first, and seven harnesses did not (#309): they read and wrote the
## developer's real character save and progression vault on every local run.
##
## It only ever bit locally, and silently. CI runners are ephemeral so nothing
## there noticed, and a test killed mid-run left state behind that the next real
## launch inherited with no failure to trace it back to.
##
## So the fix is not "remember to isolate" — it is to make booting and isolating
## the SAME ACT. This owns a [SaveIsolation] and will not hand back a scene
## unless every seam took, which means a caller cannot obtain a booted scene and
## an unisolated save at the same time.
##
## It deliberately holds no seam knowledge of its own. [SaveIsolation] is the one
## place that lists them, so a seam added there (the vault, #249; the boot
## recovery ledger, #301) reaches every harness through this without a single
## test changing — which is the property that stops the eighth harness from
## being wrong by default.
##
## Usage — in a boot test's `_ready()`:
##     _boot = IsolatedBoot.new("user://<name>_boot_probe.json")
##     _main = _boot.boot()
##     if _main == null:
##         _fail("save isolation did not take — refusing to boot into the real save")
##         return
##     add_child(_main)
## and on every exit path assert the guarantee:
##     if not _boot.real_save_untouched():
##         _fail("the boot test touched the player's real save or vault")
##
## `boot_isolation_guard_test` fails the build if a test scene loads
## `main.tscn` without coming through here.

const MAIN_SCENE := "res://scenes/main.tscn"

var _save: SaveIsolation


func _init(probe_path: String) -> void:
	_save = SaveIsolation.new(probe_path)


## Redirect every save seam, then instantiate the main scene.
##
## Returns null — and boots nothing — when the redirect did not take, so a
## caller that ignores the result still cannot run the scene against the real
## save. Fail closed: treat null as a test failure, never as "boot anyway".
## The returned node is NOT parented; the caller adds it to the tree.
func boot() -> Node:
	if not _save.begin():
		return null
	return (load(MAIN_SCENE) as PackedScene).instantiate()


## True when every real save file is exactly as it was before the boot
## (existence AND bytes) — the isolation guarantee. Clears the seams and removes
## the probes whatever the answer.
func real_save_untouched() -> bool:
	return _save.real_save_untouched()


## Clear the seams and remove the probes (idempotent). Only needed on a path
## that never calls [method real_save_untouched], which does it too.
func end() -> void:
	_save.end()
