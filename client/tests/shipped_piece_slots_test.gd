extends Node
## Regression test for the shipped piece→slot mapping ledger (issue #122).
##
## #96 reconciled the armour and art-layer slot VOCABULARIES, and `armor_axis_test`
## pins that every art-layer slot is a legal `Armor.SLOTS` value. That is
## MEMBERSHIP — "is this a real slot?". This test pins the MAPPING — "is this
## piece still where players' saves say it is?" — which is a separate promise and
## the one that strands characters when it breaks.
##
## Why it matters: a recipe persists equipment as `slot -> piece`, and
## `CharacterFactory.validate()` refuses a recipe whose slot disagrees with the
## baked registry:
##
##     if String(registry["pieces"][piece_name]["slot"]) != slot:
##         return "piece '%s' does not go in slot '%s'" % [piece_name, slot]
##
## So moving `boots_worn` from `feet` to `legs` — both legal slots, so every
## existing guard stays green — would fail validation for every character whose
## recipe recorded `feet: boots_worn`. That is the no-resets law broken through
## the one door the vocabulary guard does not cover.
##
## The ledger is APPEND-ONLY: a newly baked piece adds a line; changing an
## existing line is the deprecation-bearing act the product law requires, not a
## quiet edit. This test also cross-checks the ledger against
## `shipped_equipment.txt`, so the two ledgers can never drift apart (two lists
## of the same pieces disagreeing is the very failure class being guarded here).
##
## Pure logic + the baked registry — no scene, no save, no boot — so it is safe
## to run locally and deterministic in CI.
##
## Run: godot --headless --path client res://tests/shipped_piece_slots_test.tscn

## The layer whose pieces owe the armour vocabulary a legal slot (#251). Named
## rather than written as a bare literal at each use, so the two places that
## depend on it cannot drift apart — and so the non-vacuity check below is
## visibly guarding THIS string.
const ARMOUR_LAYER := "armor"

const LEDGER := "res://tests/data/shipped_piece_slots.txt"
const LAYER_LEDGER := "res://tests/data/shipped_piece_layers.txt"
const SHIPPED_PIECES := "res://tests/data/shipped_equipment.txt"

var _failed := false


func _ready() -> void:
	var registry := CharacterFactory.equipment_registry()
	var pieces: Dictionary = (registry.get("pieces", {}) as Dictionary).duplicate()
	# The append-only ledgers below describe persisted recipe vocabulary. Base
	# pieces are kit-owned, never written into a save, and have their own
	# unremovable contract in base_layer_test.
	for piece_name: String in registry.get("base_pieces", []):
		pieces.erase(piece_name)
	# Non-vacuity: an unreadable registry would make every assertion below pass
	# without comparing anything — "a broken scanner reads like a clean one".
	if pieces.is_empty():
		_fail("the baked equipment registry is empty or unreadable — every check below would pass vacuously")
		return

	var ledger := _ledger(LEDGER, "slot")
	if ledger.is_empty():
		_fail("the piece→slot ledger at %s is missing or empty — every check below would pass vacuously" % LEDGER)
		return

	var layers := _ledger(LAYER_LEDGER, "layer")
	if layers.is_empty():
		_fail("the piece→layer ledger at %s is missing or empty — every layer check below would pass vacuously" % LAYER_LEDGER)
		return

	# 1. THE MAPPING: every ledgered piece still sits where it shipped.
	for piece_name: String in ledger:
		if piece_name not in pieces:
			_fail("SHIPPED PIECE '%s' VANISHED from the registry (no-resets law)" % piece_name)
			return
		var piece: Dictionary = pieces[piece_name]
		var actual := String(piece.get("slot", ""))
		var promised: String = ledger[piece_name]
		if actual != promised:
			_fail(("SHIPPED PIECE '%s' MOVED SLOT: ledgered '%s', registry now '%s'. " +
				"A recipe persists equipment as slot->piece and CharacterFactory.validate() " +
				"rejects a mismatch, so every save recording '%s: %s' is now stranded. " +
				"Moving a shipped piece needs a player-visible deprecation, never a quiet re-bake.")
				% [piece_name, promised, actual, promised, piece_name])
			return

	# 2. THE LEDGER CANNOT FALL BEHIND: every baked piece is recorded, so a newly
	#    added piece must be ledgered rather than silently entering unguarded.
	for piece_name: String in pieces:
		if piece_name not in ledger:
			_fail(("baked piece '%s' is not in %s — every shipped piece must record the slot it is worn on, " +
				"or its slot is free to change and strand saves later")
				% [piece_name, LEDGER])
			return

	# 3. NO DRIFT BETWEEN THE TWO LEDGERS: shipped_equipment.txt pins that a piece
	#    still exists, this one pins where it sits. Two lists of the same pieces
	#    that can disagree is the exact failure class this test exists to prevent.
	var shipped := _shipped_piece_names()
	if shipped.is_empty():
		_fail("%s is missing or empty — the cross-ledger check would pass vacuously" % SHIPPED_PIECES)
		return
	for piece_name: String in shipped:
		if piece_name not in ledger:
			_fail("piece '%s' is in %s but has no slot recorded in %s — the ledgers have drifted"
				% [piece_name, SHIPPED_PIECES, LEDGER])
			return
	# ...and the other way. Checking one direction only would let a new baked piece
	# satisfy this ledger (forced above) while never reaching shipped_equipment.txt,
	# leaving the existing forward-only guard blind to a piece players can save.
	for piece_name: String in ledger:
		if piece_name not in shipped:
			_fail(("piece '%s' has a slot recorded in %s but is missing from %s — the ledgers have drifted; " +
				"a player-saveable piece must be covered by BOTH guards")
				% [piece_name, LEDGER, SHIPPED_PIECES])
			return

	# 4. Every ledgered slot is a region the vocabulary #96 reconciled still
	#    knows: a legal armour slot, or one of the regions #251 declared as
	#    deliberately armour-free (underwear, jewellery). Armour CONTAINMENT —
	#    that an armour-LAYER piece only ever sits on an armour slot — is checked
	#    below, once the layer ledger is in hand, because it is the layer that
	#    decides which half of the vocabulary a piece owes.
	for piece_name: String in ledger:
		var slot: String = ledger[piece_name]
		if slot not in Armor.SLOTS and slot not in CharacterFactory.ACCESSORY_REGIONS:
			_fail(("ledgered slot '%s' (piece '%s') is neither a legal armour slot %s nor a named " +
				"accessory region %s")
				% [slot, piece_name, str(Armor.SLOTS), str(CharacterFactory.ACCESSORY_REGIONS)])
			return

	# 5. THE LAYER MAPPING (#246): every ledgered piece is still worn on the
	#    layer it shipped on. A flip is not cosmetic — the kit refuses a region
	#    holding two pieces of one layer, so moving `boots_worn` to `clothing`
	#    makes every save recording boots over cloth shoes fail validation.
	for piece_name: String in layers:
		if piece_name not in pieces:
			_fail("SHIPPED PIECE '%s' VANISHED from the registry (no-resets law)" % piece_name)
			return
		var actual := String((pieces[piece_name] as Dictionary).get("layer", ""))
		var promised: String = layers[piece_name]
		if actual != promised:
			_fail(("SHIPPED PIECE '%s' CHANGED LAYER: ledgered '%s', registry now '%s'. " +
				"A region holds one piece per layer, so every save that recorded this piece " +
				"alongside another in the same region now fails validation. Layer is not written " +
				"into saves, so nothing in a save file would reveal this — changing it needs a " +
				"player-visible deprecation, never a quiet re-bake.")
				% [piece_name, promised, actual])
			return

	# 6. THE LAYER LEDGER CANNOT FALL BEHIND: a newly baked piece must record its
	#    layer, or its layer is free to change unguarded.
	for piece_name: String in pieces:
		if piece_name not in layers:
			_fail(("baked piece '%s' is not in %s — every shipped piece must record the layer it is " +
				"worn on, or its layer is free to change and strand saves later")
				% [piece_name, LAYER_LEDGER])
			return

	# 7. Every ledgered layer is one the runtime can actually place. A ledger
	#    promising a layer outside the closed set would pin a piece the kit
	#    refuses to build at all.
	for piece_name: String in layers:
		var layer: String = layers[piece_name]
		if layer not in CharacterFactory.LAYERS:
			_fail("ledgered layer '%s' (piece '%s') is not in the closed set %s"
				% [layer, piece_name, str(CharacterFactory.LAYERS)])
			return

	# 7b. ARMOUR CONTAINMENT ON THE LEDGER (#251): a piece ledgered on the armour
	#    layer must be ledgered into a legal armour slot. Check 4 deliberately
	#    admits the armour-free accessory regions, so without this a ledgered
	#    necklace could claim the armour layer and no ledger check would object.
	#    `armor_axis_test` pins the same law against the baked registry; this pins
	#    it against the append-only promise, which is what outlives a re-bake.
	#
	#    NON-VACUITY FIRST: the loop below is a filter, so with no armour-layer
	#    piece in the ledger it would report success having checked nothing —
	#    the same "a broken scanner reads exactly like a clean one" trap the
	#    registry half of this law guards against. It also pins the literal
	#    "armor" used below: if the layer vocabulary were renamed, the filter
	#    would match nothing and this guard would go silently green rather than
	#    failing loudly. Checks 7 and 8 pin the layer SET, but neither pins that
	#    this particular string is still a member of it.
	var armour_ledgered := 0
	for piece_name: String in layers:
		if layers[piece_name] == ARMOUR_LAYER and piece_name in ledger:
			armour_ledgered += 1
	if armour_ledgered == 0:
		_fail(("no ledgered piece is on the '%s' layer, so the armour-containment check below would " +
			"pass having verified nothing. Either the layer vocabulary moved (check %s) or the " +
			"ledgers fell out of step — both are defects, not an empty-but-valid state")
			% [ARMOUR_LAYER, str(CharacterFactory.LAYERS)])
		return

	for piece_name: String in layers:
		if layers[piece_name] != ARMOUR_LAYER:
			continue
		if piece_name not in ledger:
			continue
		var armoured_slot: String = ledger[piece_name]
		if armoured_slot not in Armor.SLOTS:
			_fail(("piece '%s' is ledgered on the ARMOUR layer in region '%s', which is not a legal " +
				"armour slot %s — baking armour for a region means adding it to Armor.SLOTS with its " +
				"seed pieces, which is a balance decision, not a vocabulary edit")
				% [piece_name, armoured_slot, str(Armor.SLOTS)])
			return

	# 8. The kit and the code agree on what the layers ARE. The registry carries
	#    its own `layers` list; if it and CharacterFactory.LAYERS drift, render
	#    order silently stops matching the kit's declared intent.
	var kit_layers: Array = registry.get("layers", [])
	if kit_layers != CharacterFactory.LAYERS:
		_fail(("the baked registry declares layers %s but the runtime places %s — " +
			"render order would no longer match the kit's declared intent")
			% [str(kit_layers), str(CharacterFactory.LAYERS)])
		return

	print("TEST PASS — shipped piece→slot AND piece→layer mappings hold (%d slot-ledgered, %d layer-ledgered, %d baked, cross-checked against %s; a legal slot move or a layer flip would strand saves and now turns CI red)"
		% [ledger.size(), layers.size(), pieces.size(), SHIPPED_PIECES])
	get_tree().quit(0)


## A `<piece> <value>` ledger as `piece -> value` — used for both the slot and
## the layer ledger, which have identical shape and identical failure modes, so
## they share one reader rather than two that can drift. `what` names the second
## column for the failure messages. Blank lines and `#` comments are ignored; a
## malformed line fails loudly rather than being skipped, so a typo can never
## quietly drop a piece out of the guard.
func _ledger(path: String, what: String) -> Dictionary:
	var out: Dictionary = {}
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line == "" or line.begins_with("#"):
			continue
		var parts := line.split(" ", false)
		if parts.size() != 2:
			_fail("malformed ledger line in %s: '%s' (expected '<piece> <%s>')" % [path, line, what])
			return {}
		# A DUPLICATE piece is refused, not last-write-wins. Appending a second row
		# (`boots_worn legs` under an existing `boots_worn feet`) looks append-only
		# but silently re-points the promise: the mapping check would then pin the
		# duplicate and pass against a moved registry, while saves holding the
		# ORIGINAL slot still fail validation. The first shipped value is immutable.
		if parts[0] in out:
			_fail(("duplicate piece '%s' in %s (already promised %s '%s', row says '%s') — " +
				"a second row silently re-points a shipped promise; the first shipped %s is immutable, " +
				"so moving a piece needs a player-visible deprecation, not an extra line")
				% [parts[0], path, what, out[parts[0]], parts[1], what])
			return {}
		out[parts[0]] = parts[1]
	return out


## Every piece name from the existing shipped-pieces ledger.
func _shipped_piece_names() -> PackedStringArray:
	var out := PackedStringArray()
	var f := FileAccess.open(SHIPPED_PIECES, FileAccess.READ)
	if f == null:
		return out
	while not f.eof_reached():
		var line := f.get_line().strip_edges()
		if line != "" and not line.begins_with("#"):
			out.append(line)
	return out


func _fail(message: String) -> void:
	_failed = true
	push_error(message)
	print("TEST FAIL — %s" % message)
	get_tree().quit(1)
