class_name Armor
extends RefCounted
## The armour axis — the ONE place the design lets power grow, and therefore the
## one that needs mechanical guards most.
##
## `AGENTS.md` settles three laws that nothing enforced until now:
##  * "Loot is Elder-Scrolls-shaped: a sword is a sword … **Armour is the
##    exception** — real mitigation/lightness trade-offs: light = agile, heavy =
##    takes a hit."
##  * "Axis map, to keep balance legible: **weapons = horizontal** (your arsenal;
##    cosmetic variety only). **Armour = your role/agility axis, and the bounded
##    endgame vertical.** Keep them from blurring."
##  * "'no strict dominance' is **simulatable**, so it is an agent-ownable CI
##    guard rather than a matter of taste."
##
## The repo already models equipment as MESH (garments on a skeleton — the art
## layer). This models what armour DOES, and holds the laws above as checkable
## invariants so the trade-off curve stays a trade-off no matter who authors the
## next piece — the product law forbids power creep and there is no undo, so the
## guard must exist before the content does.
##
## PURE — no scene tree, no engine singletons, no `user://` — so it is
## deterministic and unit-testable, exactly like `Telegraph` and `Discovery`.
## Equipping a piece, applying it in combat resolution (server-authoritative),
## the data-driven JSON registry, and the endgame stat-normalisation rule are
## deferred children; this ships the LAWS.
##
## The three guards, each isolated so a violation names its own law:
##  * `find_strict_dominance` — no same-slot piece is `>=` on BOTH mitigation and
##    agility (and strictly greater on one). That is a flat upgrade, i.e. power
##    creep through the one door the design leaves ajar.
##  * `find_class_inversions` — a heavier weight class must genuinely mitigate
##    MORE and move LESS than a lighter one in the same slot, so the label stays
##    honest ("light = agile, heavy = takes a hit").
##  * `find_schema_violations` — the closed record, the closed slot/class sets,
##    and the BOUNDED ceiling. Armour carries no offence field at all, which is
##    the axis-non-blur law made mechanical.

## The closed slot set — where a piece is worn.
##
## VOCABULARY: these strings are the SAME vocabulary the art layer uses in the
## baked equipment registry (`equipment.json`), not a parallel one. The art layer
## is the incumbent — its slot strings are baked into shipped pieces and are
## reachable from persisted recipes (`CharacterFactory` reads
## `recipe["equipment"][slot]`) — so where the two ever disagree, the model
## yields. That is why the torso slot is `torso` and not `chest`: renaming a
## shipped slot string later would be a repurpose of an existing value, which the
## forward-only law forbids, while this model has no persisted data yet.
##
## SCOPE (deliberate): this set is where ARMOUR is worn, which since #251 is
## narrower than "every region the wardrobe has". A model-only slot stays
## expected, not a defect: `head` and `hands` were legal here before any piece
## was baked for them, because helmets and gauntlets are clearly intended (the
## seed table already models them) and appending a slot later is forward-only,
## whereas narrowing now and re-widening later is churn.
##
## What changed in #251: the art layer gained the rest of the specified wardrobe
## (#222), and some of those regions hold no armour at all — underwear sits in
## `pelvis`, and jewellery sits in `neck`/`ring_l`/`ring_r`/`trinket_1`/
## `trinket_2`. The old law read "every art-layer slot must be a legal armour
## slot", which would have forced each of those into this set — and every entry
## here owes `armor_axis_test` a light/medium/heavy seed piece, so satisfying it
## would have meant inventing mitigation and agility numbers for rings and
## underpants. That is not a naming detail: this is the ONE axis the product law
## lets grow, so widening it is a balance decision, and nothing in the
## maintainer's wardrobe direction asks for jewellery power. #222 lists that
## jewellery under "armor on top of it", which is a statement about RENDER
## ORDER — the `layer` a piece sits on — not about carrying armour stats.
##
## So the containment law is now stated on pieces rather than on the region
## list: every region that HOSTS AN ARMOUR-LAYER PIECE must be a legal armour
## slot. It still catches the drift #96 closed (a worn piece the model rejects),
## and it forces the jewellery question at the moment a necklace is actually
## baked — by whoever bakes it, with the piece in front of them — instead of
## being answered now by a vocabulary edit. Regions deliberately outside this
## set are named in `CharacterFactory.ACCESSORY_REGIONS`, so a TYPO still lands
## in neither set and turns CI red.
##
## `waist` joins this set now, and only it: a belt is armour in the ordinary
## sense and its light/medium/heavy trade-off is honest to author, so the
## headroom argument that admitted `head` and `hands` applies to it unchanged.
const SLOTS: Array[String] = ["head", "torso", "hands", "legs", "feet", "waist"]

## The closed weight-class set, lightest first. Index IS the class rank, so
## "heavier than" is a comparison, not a lookup table.
const WEIGHT_CLASSES: Array[String] = ["light", "medium", "heavy"]

## The EXACT fields an armour piece may carry: what it is, where it is worn, its
## class, and its two axis values. There is deliberately NO damage/power/offence
## field — a piece that carries one has blurred the horizontal weapon axis into
## the vertical armour axis, which `find_schema_violations` refuses.
const PIECE_KEYS: Array[String] = ["id", "slot", "weight_class", "mitigation", "agility"]

## The bounded endgame vertical: mitigation may never exceed this, so "harder and
## harder content" scales DIFFICULTY, never armour power. Agility is bounded for
## the same reason on the other axis.
const MITIGATION_CAP := 100.0
const AGILITY_CAP := 100.0

## Seed pieces — SCAFFOLDING, deliberately NOT balance-tuned. They exist so the
## guards run over real data in CI: adding a strictly-dominant, mislabelled, or
## over-cap piece here turns the build red. Within every slot mitigation rises
## and agility falls across light → medium → heavy, which is the trade-off curve
## the design describes.
const SEED_PIECES: Array[Dictionary] = [
	{"id": "ashen_hood", "slot": "head", "weight_class": "light", "mitigation": 8.0, "agility": 88.0},
	{"id": "warden_coif", "slot": "head", "weight_class": "medium", "mitigation": 18.0, "agility": 62.0},
	{"id": "cinder_helm", "slot": "head", "weight_class": "heavy", "mitigation": 28.0, "agility": 40.0},
	{"id": "ashen_wrap", "slot": "torso", "weight_class": "light", "mitigation": 20.0, "agility": 85.0},
	{"id": "warden_hauberk", "slot": "torso", "weight_class": "medium", "mitigation": 42.0, "agility": 58.0},
	{"id": "cinder_plate", "slot": "torso", "weight_class": "heavy", "mitigation": 64.0, "agility": 32.0},
	{"id": "ashen_bindings", "slot": "hands", "weight_class": "light", "mitigation": 6.0, "agility": 90.0},
	{"id": "warden_gloves", "slot": "hands", "weight_class": "medium", "mitigation": 13.0, "agility": 66.0},
	{"id": "cinder_gauntlets", "slot": "hands", "weight_class": "heavy", "mitigation": 20.0, "agility": 44.0},
	{"id": "ashen_leggings", "slot": "legs", "weight_class": "light", "mitigation": 14.0, "agility": 86.0},
	{"id": "warden_greaves", "slot": "legs", "weight_class": "medium", "mitigation": 30.0, "agility": 60.0},
	{"id": "cinder_tassets", "slot": "legs", "weight_class": "heavy", "mitigation": 46.0, "agility": 36.0},
	{"id": "ashen_boots", "slot": "feet", "weight_class": "light", "mitigation": 7.0, "agility": 89.0},
	{"id": "warden_sabatons", "slot": "feet", "weight_class": "medium", "mitigation": 15.0, "agility": 64.0},
	{"id": "cinder_stompers", "slot": "feet", "weight_class": "heavy", "mitigation": 23.0, "agility": 42.0},
	{"id": "ashen_sash", "slot": "waist", "weight_class": "light", "mitigation": 5.0, "agility": 91.0},
	{"id": "warden_belt", "slot": "waist", "weight_class": "medium", "mitigation": 11.0, "agility": 68.0},
	{"id": "cinder_girdle", "slot": "waist", "weight_class": "heavy", "mitigation": 17.0, "agility": 46.0},
]


## Flag every same-slot pair where one piece is at least as good on BOTH axes and
## strictly better on one — a strict upgrade, which is power creep. Two pieces
## with identical numbers are duplicates, not creep, so they are not flagged
## here. Only well-formed pieces take part, so a malformed record trips the
## schema guard alone. Output is sorted, so the result never depends on the order
## the pieces were supplied in.
static func find_strict_dominance(pieces: Array) -> Array[String]:
	var problems: Array[String] = []
	var valid := _wellformed(pieces)
	for i in valid.size():
		for j in valid.size():
			if i == j:
				continue
			var a := valid[i]
			var b := valid[j]
			if a["slot"] != b["slot"]:
				continue
			var am := float(a["mitigation"])
			var aa := float(a["agility"])
			var bm := float(b["mitigation"])
			var ba := float(b["agility"])
			if am >= bm and aa >= ba and (am > bm or aa > ba):
				problems.append("'%s' strictly dominates '%s' in slot '%s' (mitigation %.1f>=%.1f, agility %.1f>=%.1f) — armour must trade, never simply upgrade" %
					[str(a["id"]), str(b["id"]), str(a["slot"]), am, bm, aa, ba])
	problems.sort()
	return problems


## Flag every same-slot pair whose weight classes contradict their numbers: a
## heavier class must mitigate strictly MORE and move strictly LESS than a
## lighter one ("light = agile, heavy = takes a hit"). This keeps the class label
## honest — a "heavy" that is the most agile piece in its slot is a lie to the
## player even when it dominates nothing. Sorted, well-formed pieces only.
static func find_class_inversions(pieces: Array) -> Array[String]:
	var problems: Array[String] = []
	var valid := _wellformed(pieces)
	for i in valid.size():
		for j in range(i + 1, valid.size()):
			var a := valid[i]
			var b := valid[j]
			if a["slot"] != b["slot"]:
				continue
			var rank_a := WEIGHT_CLASSES.find(str(a["weight_class"]))
			var rank_b := WEIGHT_CLASSES.find(str(b["weight_class"]))
			if rank_a == rank_b:
				continue
			var heavier := a if rank_a > rank_b else b
			var lighter := b if rank_a > rank_b else a
			var hm := float(heavier["mitigation"])
			var ha := float(heavier["agility"])
			var lm := float(lighter["mitigation"])
			var la := float(lighter["agility"])
			if hm <= lm:
				problems.append("'%s' (%s) does not mitigate more than the lighter '%s' (%s) in slot '%s' (%.1f <= %.1f) — the class label must be honest" %
					[str(heavier["id"]), str(heavier["weight_class"]), str(lighter["id"]), str(lighter["weight_class"]), str(heavier["slot"]), hm, lm])
			if ha >= la:
				problems.append("'%s' (%s) is not less agile than the lighter '%s' (%s) in slot '%s' (%.1f >= %.1f) — the class label must be honest" %
					[str(heavier["id"]), str(heavier["weight_class"]), str(lighter["id"]), str(lighter["weight_class"]), str(heavier["slot"]), ha, la])
	problems.sort()
	return problems


## Audit records against the closed armour schema: exactly PIECE_KEYS (no
## smuggled offence field, none missing), a unique non-empty id, a slot and
## weight class from the closed sets, and both axis values finite and within
## their caps (the bounded endgame vertical). Sorted; empty means clean.
static func find_schema_violations(pieces: Array) -> Array[String]:
	var problems: Array[String] = []
	var seen: Dictionary = {}
	for i in pieces.size():
		var raw: Variant = pieces[i]
		if not (raw is Dictionary):
			problems.append("piece %d is not a Dictionary" % i)
			continue
		var p := raw as Dictionary
		var extra: Array[String] = []
		for k: Variant in p.keys():
			if not (k in PIECE_KEYS):
				extra.append(str(k))
		var missing: Array[String] = []
		for k: String in PIECE_KEYS:
			if not p.has(k):
				missing.append(k)
		if not extra.is_empty() or not missing.is_empty():
			problems.append("piece %d schema mismatch (extra=%s missing=%s) — armour carries only %s, never an offence field" %
				[i, extra, missing, PIECE_KEYS])
			continue
		var id_value := str(p["id"])
		if id_value.is_empty():
			problems.append("piece %d has an empty id" % i)
		elif seen.has(id_value):
			problems.append("duplicate piece id '%s'" % id_value)
		else:
			seen[id_value] = true
		if not (p["slot"] in SLOTS):
			problems.append("piece '%s' slot '%s' is not in the closed set %s" % [id_value, str(p["slot"]), SLOTS])
		if not (p["weight_class"] in WEIGHT_CLASSES):
			problems.append("piece '%s' weight_class '%s' is not in the closed set %s" % [id_value, str(p["weight_class"]), WEIGHT_CLASSES])
		problems.append_array(_check_axis(id_value, "mitigation", p["mitigation"], MITIGATION_CAP))
		problems.append_array(_check_axis(id_value, "agility", p["agility"], AGILITY_CAP))
	problems.sort()
	return problems


## One axis value: a finite number within [0, cap]. The cap is what bounds the
## endgame vertical, so exceeding it is a product-law violation, not a tuning
## choice.
static func _check_axis(id_value: String, axis: String, value: Variant, cap: float) -> Array[String]:
	var out: Array[String] = []
	if not (value is float or value is int):
		out.append("piece '%s' %s is not a number" % [id_value, axis])
		return out
	var v := float(value)
	if not is_finite(v):
		out.append("piece '%s' %s is not finite" % [id_value, axis])
	elif v < 0.0 or v > cap:
		out.append("piece '%s' %s %.1f is outside [0, %.1f] — the armour vertical is bounded" % [id_value, axis, v, cap])
	return out


## Whether a record satisfies the whole schema (shape, closed sets, finite
## in-range axes). The pairwise guards run only over these, so a malformed or
## over-cap piece trips the schema guard ALONE and each law reports independently.
static func is_wellformed(piece: Variant) -> bool:
	if not (piece is Dictionary):
		return false
	var p := piece as Dictionary
	if p.keys().size() != PIECE_KEYS.size():
		return false
	for k: String in PIECE_KEYS:
		if not p.has(k):
			return false
	if str(p["id"]).is_empty():
		return false
	if not (p["slot"] in SLOTS) or not (p["weight_class"] in WEIGHT_CLASSES):
		return false
	return _axis_ok(p["mitigation"], MITIGATION_CAP) and _axis_ok(p["agility"], AGILITY_CAP)


static func _axis_ok(value: Variant, cap: float) -> bool:
	if not (value is float or value is int):
		return false
	var v := float(value)
	return is_finite(v) and v >= 0.0 and v <= cap


## The subset of `pieces` that is well-formed, in the order supplied.
static func _wellformed(pieces: Array) -> Array[Dictionary]:
	var out: Array[Dictionary] = []
	for raw: Variant in pieces:
		if is_wellformed(raw):
			out.append(raw as Dictionary)
	return out
