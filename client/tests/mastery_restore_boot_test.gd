extends Node
## Real-boot proof for the retained vault-v5 mastery reader (issue #655).
##
## A pure SaveVault/Mastery test can prove both pieces in isolation while the
## shipped scene silently ignores the accepted state. These two isolated boots
## prove the production wiring: an empty boot originates no reader-only mastery,
## then a seeded v5 boot applies every track and the standing bloodstain without
## letting ordinary older writers discard the opaque snapshot.

const ASSERT_TICK := 30
const PROBE_PATH := "user://mastery_restore_boot_probe.json"
const MAIN_SCENE_PATH := "res://scenes/main.tscn"
const MASTERY_PROBE := {
	"weapons": {
		"future_blade": {"banked": 200, "unbanked": 37},
		"staff": {"banked": 0, "unbanked": 75},
	},
	"bloodstain": {"future_blade": 12},
}

var _ticks := 0
var _seeded := false
var _main: Node
var _save: SaveIsolation
var _failed := false


func _ready() -> void:
	_begin_boot(false)


func _physics_process(_delta: float) -> void:
	if _failed or _main == null:
		return
	_ticks += 1
	if _ticks < ASSERT_TICK:
		return
	set_physics_process(false)
	_assert_boot()


func _begin_boot(seeded: bool) -> void:
	_seeded = seeded
	_ticks = 0
	set_physics_process(true)
	if _main != null:
		_main.queue_free()
		_main = null
	_save = SaveIsolation.new(PROBE_PATH)
	if not _save.begin():
		_fail("save isolation did not take — refusing to boot into the real save")
		return
	SaveVault.clear_refusals_for_test()
	if seeded:
		var expanded := {
			"version": 5,
			"attuned": [],
			"discoveries": ["starter_cave"],
			"reward_claims": ["starter_cave"],
			"quests": {"future_quest": {"future_objective": 11}},
			"mastery": MASTERY_PROBE.duplicate(true),
		}
		if not SaveVault.save_to(SaveVault.vault_path(), expanded):
			_fail("could not seed the vault-v5 mastery probe")
			return
	_main = (load(MAIN_SCENE_PATH) as PackedScene).instantiate()
	add_child(_main)


func _assert_boot() -> void:
	var mastery := _mastery_tracker()
	if mastery == null:
		return
	var vault = SaveVault.load_saved()
	if not _seeded:
		if not mastery.weapons().is_empty() or not mastery.bloodstain().is_empty():
			_fail("the empty control boot invented mastery state")
			return
		if vault is Dictionary and (vault.has("mastery")
				or int(vault.get("version", -1)) > SaveVault.VAULT_VERSION):
			_fail("an ordinary production boot originated reader-only mastery: %s" % str(vault))
			return
		if not _save.real_save_untouched():
			_fail("the mastery control boot touched the player's real save or vault")
			return
		_save = null
		_begin_boot(true)
		return

	if mastery.weapons() != ["future_blade", "staff"] \
			or mastery.banked("future_blade") != 200 \
			or mastery.unbanked("future_blade") != 37 \
			or mastery.banked("staff") != 0 \
			or mastery.unbanked("staff") != 75 \
			or mastery.bloodstain() != {"future_blade": 12}:
		_fail("the production boot did not restore the complete mastery snapshot")
		return
	if vault is not Dictionary \
			or int(vault.get("version", -1)) != 5 \
			or vault.get("mastery", {}) != JSON.parse_string(JSON.stringify(MASTERY_PROBE)):
		_fail("ordinary boot writers dropped or changed retained mastery: %s" % str(vault))
		return
	if not _save.real_save_untouched():
		_fail("the mastery reader boot touched the player's real save or vault")
		return
	_save = null
	print("TEST PASS — the production boot restores vault-v5 mastery while ordinary boots remain on the v4 writer")
	get_tree().quit(0)


func _mastery_tracker() -> Mastery:
	for property: Dictionary in _main.get_property_list():
		if String(property.get("name", "")) == "_mastery":
			var tracker: Variant = _main.get("_mastery")
			if tracker is Mastery:
				return tracker as Mastery
	_fail("CAPABILITY 7 IS PARSER-ONLY: the production boot owns no Mastery ledger")
	return null


func _fail(message: String) -> void:
	if _failed:
		return
	_failed = true
	if _save != null:
		var isolation_breached := not _save.real_save_untouched()
		_save = null
		if isolation_breached:
			message += " — AND the run touched the player's real save, vault or recovery ledger"
	push_error("TEST FAIL — " + message)
	get_tree().quit(1)


func _exit_tree() -> void:
	if _save != null:
		if not _save.real_save_untouched():
			push_error("mastery restore boot test teardown detected a real player-data mutation")
		_save = null
