extends Node
## Regression test for the wardrobe REGION vocabulary (#251, under epic #222).
##
## #222 specifies the wardrobe the game's visual progression is built on — you
## wake with almost nothing and earn the look — and the kit declared three body
## regions, so most of that list had nowhere to go. This declares the whole set
## up front, before the garments exist, which is deliberate: the region names are
## reachable from persisted recipes (`CharacterFactory` reads
## `recipe["equipment"][region]`), so settling them once is cheap and renaming
## one later is the forward-only law's most expensive kind of mistake.
##
## Declaring regions ahead of their art creates exactly two risks, and this pins
## both:
##
##  1. THE SPEC SILENTLY DRIFTS — a region named in #222 is dropped, or never
##     arrives, and nothing notices because no piece needs it yet. The wardrobe
##     is transcribed here as a table so the spec itself is the assertion.
##  2. AN EMPTY REGION LEAKS INTO THE UI — the creator builds one picker per
##     region, so nine piece-less regions would become nine dead rows on the
##     screen already faulted for reading as a debug panel (#227).
##
## Plus the forward-only guarantee that outranks both: the regions that shipped
## before this change must still be declared, under their original names.
##
## The ARMOUR half of the vocabulary (which regions may hold armour, and the
## closed-set law over them) lives in `armor_axis_test`; the piece→region
## promise lives in `shipped_piece_slots_test`. This test owns the region SET.
##
## Pure data + one pure static function — no scene, no save, no boot.
##
## Run: godot --headless --path client res://tests/equipment_regions_test.tscn

## The wardrobe #222 specifies, transcribed: garment -> the region it goes in.
## Kept as the spec's own words so a reader can check it against the issue.
## `eyewear` shares `head` with head armour on purpose — that is the occlusion
## case #246 built `occluded_by` for, and the reason the rule names LAYERS
## rather than pieces.
const WARDROBE := {
	"socks": "feet",
	"underpants": "pelvis",
	"pants": "legs",
	"shirt": "torso",
	"eyewear": "head",
	"boots": "feet",
	"leg armour": "legs",
	"chest armour": "torso",
	"head armour": "head",
	"belt": "waist",
	"gloves": "hands",
	"necklace": "neck",
	"ring (left)": "ring_l",
	"ring (right)": "ring_r",
	"trinket (first)": "trinket_1",
	"trinket (second)": "trinket_2",
}

## The regions that existed before #251. These are reachable from every save
## written so far, so they may never be renamed or dropped — only added to.
const INCUMBENT_REGIONS := ["torso", "legs", "feet"]

var _failed := false


func _ready() -> void:
	var registry := CharacterFactory.equipment_registry()
	var declared: Array = registry.get("slots", [])
	# A missing/unreadable registry would make every check below pass VACUOUSLY —
	# a broken reader looks exactly like a satisfied contract.
	_check(declared.is_empty(), false, "the baked equipment registry actually loaded (an empty one would pass vacuously)")
	if _failed:
		return

	# --- 1. FORWARD-ONLY: every region that has shipped is still declared ---
	for region: String in INCUMBENT_REGIONS:
		_check(region in declared, true,
			"forward-only: region '%s' shipped before #251 and is still declared (renaming or dropping it strands every save that used it)" % region)
	if _failed:
		return

	# --- 2. THE SPEC IS COVERED: every wardrobe garment has somewhere to go ---
	for garment: String in WARDROBE:
		var region: String = WARDROBE[garment]
		_check(region in declared, true,
			"wardrobe: '%s' goes in region '%s', which the kit must declare (#222)" % [garment, region])
	if _failed:
		return

	# --- 3. THE PAIRS ARE DISTINCT REGIONS, not one region holding two ---
	# A region holds one piece per layer (#246) and a recipe persists
	# region -> piece, so a shared region could not record WHICH ring is which.
	# That is the membership-vs-mapping trap #96 and #122 both turned on.
	_check(WARDROBE["ring (left)"] != WARDROBE["ring (right)"], true,
		"pairs: the two rings occupy distinct regions, so a save can say which is which")
	_check(WARDROBE["trinket (first)"] != WARDROBE["trinket (second)"], true,
		"pairs: the two trinkets occupy distinct regions, so a save can say which is which")

	# --- 4. NO DUPLICATE REGIONS: a repeat would give one region two pickers ---
	var seen := {}
	for region: Variant in declared:
		var name := str(region)
		_check(name in seen, false, "the region list declares '%s' exactly once" % name)
		seen[name] = true
	if _failed:
		return

	# --- 5. THE CREATOR OFFERS ONLY REGIONS SOMETHING FITS IN ---
	# Checked through the real static rule the UI calls, not a copy of it.
	var pickable := CharacterCreator.pickable_regions(registry)
	for region: String in pickable:
		_check(_piece_count(registry, region) > 0, true,
			"creator: offers region '%s' only because a piece is baked for it" % region)
	for region: Variant in declared:
		if _piece_count(registry, str(region)) > 0:
			_check(str(region) in pickable, true,
				"creator: region '%s' holds a piece, so it must be offered" % str(region))
		else:
			_check(str(region) in pickable, false,
				"creator: region '%s' holds nothing yet, so it must NOT become a dead row (#227)" % str(region))
	if _failed:
		return
	# Non-vacuity: the rule is meaningless unless it is actually FILTERING today.
	# If every declared region held a piece, checks above would pass while the
	# filter did nothing — and the nine-dead-rows regression would be invisible.
	_check(pickable.size() < declared.size(), true,
		"creator: the rule actually filters (%d of %d regions are offered; an unfiltered pass would prove nothing)" % [pickable.size(), declared.size()])
	_check(pickable.is_empty(), false, "creator: at least one region is still offered (an empty outfit section would also 'filter')")
	if _failed:
		return

	# --- 6. NEGATIVE CONTROLS, each isolated to ONE behaviour ---
	# a) a declared region gains a piece -> it becomes pickable.
	var with_piece := {
		"slots": ["torso", "neck"],
		"pieces": {"cord_pendant": {"slot": "neck", "layer": "clothing"}},
	}
	_check("neck" in CharacterCreator.pickable_regions(with_piece), true,
		"control: a region holding a piece IS offered (proves the filter is piece-driven, not a hardcoded allow-list)")
	# b) the same region with no piece -> not pickable. Without (b), a rule that
	# simply returned every declared region would pass (a) identically.
	var without_piece := {"slots": ["torso", "neck"], "pieces": {}}
	_check("neck" in CharacterCreator.pickable_regions(without_piece), false,
		"control: the same region with nothing baked is NOT offered")
	# c) declared ORDER is preserved, not sorted — the kit decides the row order,
	# and an alphabetical sort would silently reorder the player's outfit list.
	var ordered := {
		"slots": ["torso", "legs", "feet"],
		"pieces": {
			"a_shirt": {"slot": "torso", "layer": "clothing"},
			"b_pants": {"slot": "legs", "layer": "clothing"},
			"c_shoes": {"slot": "feet", "layer": "clothing"},
		},
	}
	var declared_order: Array[String] = ["torso", "legs", "feet"]
	_check(CharacterCreator.pickable_regions(ordered) == declared_order, true,
		"control: offered regions keep the kit's declared order (a sort would read ['feet','legs','torso'])")
	if _failed:
		return

	print("TEST PASS — wardrobe regions hold (%d declared, %d incumbent still present, %d garments in #222 all placed, %d offered by the creator and %d deliberately empty)"
		% [declared.size(), INCUMBENT_REGIONS.size(), WARDROBE.size(), pickable.size(), declared.size() - pickable.size()])
	get_tree().quit(0)


func _piece_count(registry: Dictionary, region: String) -> int:
	var n := 0
	var pieces: Dictionary = registry.get("pieces", {})
	for piece_name: String in pieces:
		if String((pieces[piece_name] as Dictionary).get("slot", "")) == region:
			n += 1
	return n


func _check(actual: bool, expected: bool, label: String) -> void:
	if _failed:
		return
	if actual != expected:
		_failed = true
		var message := "%s — expected %s, got %s" % [label, expected, actual]
		push_error(message)
		print("TEST FAIL — %s" % message)
		get_tree().quit(1)
