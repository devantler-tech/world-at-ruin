extends Node
## Sticky comparison verdicts for pure regression scenes. Each scene owns its
## scenarios and success marker; the first failure prevents later comparisons.

var _failed := false


## Compare the caller's actual result with its independent expected value.
func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_fail("%s — expected %s, got %s" % [label, expected, actual])


## Keep the failure marker observable even if a caller later requests success.
func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
