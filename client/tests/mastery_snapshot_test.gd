extends Node
## A persistence listener must see only complete economic transitions. Emitting
## from reclaim's internal accrual would save both returned points and the still
## reclaimable stain, duplicating value after a process loss.

var _failed := false
var _observed: Array[Dictionary] = []


func _ready() -> void:
	var ledger := Mastery.new()
	if not ledger.has_method("snapshot") or not ledger.has_signal("changed"):
		_fail("mastery cannot publish complete snapshots after real mutations")
		return
	ledger.connect("changed", func() -> void:
		_observed.append(ledger.call("snapshot")))
	ledger.accrue("sword", 250)
	ledger.accrue("staff", 90)
	_check(_observed.size() == 2, "each actual accrual publishes once")
	_check(_observed.back() == {
		"weapons": {"sword": {"banked": 200, "unbanked": 50},
			"staff": {"banked": 0, "unbanked": 90}}, "bloodstain": {},
	}, "snapshot lost banking or an independent weapon")
	ledger.die(50)
	_check(_observed.size() == 3, "death did not publish one complete transfer")
	_check(_observed.back()["bloodstain"] == {"staff": 45, "sword": 25},
		"death snapshot lost the standing bloodstain")
	_check(ledger.reclaim() == 70, "reclaim changed its conserved outcome")
	_check(_observed.size() == 4, "reclaim published intermediate per-weapon states")
	_check(_observed.back()["bloodstain"] == {},
		"reclaim published returned points while the stain was still reclaimable")
	_check(_observed.back()["weapons"]["sword"] == {"banked": 200, "unbanked": 50},
		"reclaim snapshot lost returned points")
	ledger.accrue("", 10)
	ledger.accrue("sword", 0)
	ledger.accrue("sword", -1)
	ledger.die(0)
	ledger.reclaim()
	_check(_observed.size() == 4, "a no-op originated a persistence event")
	var snapshot: Dictionary = ledger.call("snapshot")
	snapshot["weapons"]["sword"]["banked"] = 0
	_check(ledger.banked("sword") == 200, "snapshot aliases live player state")
	_check(ledger.restore(_observed.back()), "restore refused a real mutation snapshot")
	_check(_observed.size() == 4, "restore replayed a mutation event")
	_check_numeric_boundary()
	if _failed:
		return
	print("TEST PASS — complete mastery snapshots publish once per mutation without inflation")
	get_tree().quit(0)


func _check_numeric_boundary() -> void:
	var ledger := Mastery.new()
	var near_ceiling := {
		"weapons": {"sword": {"banked": 9007199254740900, "unbanked": 90}},
		"bloodstain": {"sword": 20},
	}
	_check(ledger.restore(near_ceiling), "historical valid ceiling fixture was refused")
	var before: Dictionary = ledger.call("snapshot")
	ledger.accrue("sword", 9223372036854775807)
	_check(ledger.call("snapshot") == before, "large award overflowed persistable mastery")
	ledger.accrue("sword", 10)
	_check(ledger.call("snapshot") == before, "award produced a banked value beyond JSON precision")
	_check(ledger.reclaim() == 0, "unpersistable reclaim was reported as successful")
	_check(ledger.call("snapshot") == before, "refused reclaim destroyed part of the standing stain")
	ledger.die(100)
	_check(ledger.reclaim() == 90, "a valid reclaim at the precision boundary was refused")
	_check(Mastery.snapshot_refusal_reason(ledger.call("snapshot")).is_empty(),
		"ordinary death and reclaim produced an unreadable save")


func _check(condition: bool, message: String) -> void:
	if not condition:
		_fail(message)


func _fail(message: String) -> void:
	_failed = true
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)
