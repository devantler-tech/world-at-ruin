class_name SaveVault
## The save vault (issue #249, parent #3): the player's PROGRESSION state, in
## its own versioned file alongside the character recipe.
##
## Why a separate file and not a bigger character.json — this is the whole
## design, and it is forced, not chosen:
##
## CharacterFactory.validate() treats the recipe as a CLOSED format: any
## top-level field it does not know is rejected outright ("refusing a
## half-truth"). That rule is correct for the recipe and it is already baked
## into every client that ever shipped, so it cannot be relaxed retroactively.
## It leaves no room to grow the save in place:
##  - a sibling key (`"progress": {...}`) inside character.json makes every
##    shipped CharacterFactory reject the WHOLE recipe;
##  - wrapping the recipe in an envelope is no safer — CharacterStore still
##    parses the JSON object, then CharacterFactory.build() finds no integer
##    recipe `version` and refuses it. The saved body stays unbuilt while the
##    manual editor remains a writable path (no-resets law).
##
## A separate file is the only shape an already-shipped client handles safely:
## it never looks at a file it does not know, so it neither rejects it nor
## deletes it. The character still loads on an old client; the vault simply
## sits untouched until a client that understands it runs again.
##
## The vault obeys the same forward-only laws as the recipe:
##  - keyed by stable STRINGS (respawn points are named, never indices or
##    coordinates), so a name that ever shipped keeps working forever;
##  - versioned, with `version` <= VAULT_READ_VERSION accepted forever and a
##    NEWER version refused rather than half-applied;
##  - additive-only: a shipped field is never removed or repurposed, and every
##    shipped version keeps a golden fixture (save_vault_guard_test).
##
## Two rules differ from CharacterStore, both deliberate:
##
##  1. A missing or refused vault DEGRADES to session-only behaviour and must
##     never block character load or open the creator. Losing a respawn point
##     costs the player one walk back to the shrine; losing the character is
##     unrecoverable. The vault is never allowed to become a way to strand one.
##
##  2. A vault that EXISTS but could not be read is READ-ONLY for the session
##     (see [method can_write]). Refusing to read it and then writing over it
##     would destroy progression a NEWER client wrote — the downgrade path the
##     separate-file design exists to survive. Refuse-to-read implies
##     refuse-to-write, always.

const DEFAULT_PATH := "user://vault.json"

## Environment override for the active vault path, mirroring CharacterStore's
## WAR_SAVE_PATH seam. Empty/unset means the shipped default — production never
## sets it; tests point it at a throwaway file so no test can damage a real
## player's progression.
const VAULT_PATH_ENV := "WAR_VAULT_PATH"

## Highest schema emitted by a production writer. v2 is used only when the
## document actually carries discovery state; an empty or attunement-only vault
## stays on v1 so old state is never rewritten merely to look current.
const VAULT_VERSION := 2

## The minimal vault shape. Kept separate from [constant VAULT_VERSION] because
## a fresh or attunement-only document has no v2 field to describe.
const BASE_VAULT_VERSION := 1

## Highest vault schema this build can READ. Kept separate from the production
## writer because v2 carried discovery state through its read-first bake before
## [constant VAULT_VERSION] was raised by the later contract release.
const VAULT_READ_VERSION := 2

## The vault format, exhaustively. Unknown top-level fields are refused for the
## same reason the recipe refuses them: a client that silently ignored a field
## would present a progression state that is not what the file says. New fields
## ship with a version bump and are listed in a VAULT_FIELDS_V<N> constant.
const VAULT_FIELDS_V1 := ["version", "comment", "attuned"]
const VAULT_FIELDS_V2 := ["version", "comment", "attuned", "discoveries"]

## The Wardens' Shrine, the first attunable respawn point. Names are forward-only
## (no-resets law): this string is shipped save data now and may never change
## meaning — only new names may be added.
const SHRINE_WARDENS := "wardens_shrine"

## Every discovery id this build can ORIGINATE. These names are persisted player
## data and therefore permanent: shipped_discoveries.txt anchors each id and its
## landmark meaning against the base revision, while the boot guard proves the
## mapping still resolves to the live POI.
const DISCOVERY_STARTER_CAVE := "starter_cave"
const DISCOVERY_WARDENS_SHRINE := SHRINE_WARDENS
const KNOWN_DISCOVERIES := [DISCOVERY_STARTER_CAVE, DISCOVERY_WARDENS_SHRINE]

## Every attunement name this build RECOGNISES — i.e. can still act on, not
## merely preserve. This is the live half of the forward-only guarantee, and it
## is what a golden fixture alone cannot prove.
##
## A byte round-trip shows a shipped name SURVIVES; it says nothing about the
## game still doing anything with it. Rename SHRINE_WARDENS and update main.gd
## together and every zero-loss guard stays green — the immutable golden still
## carries `wardens_shrine`, validation deliberately preserves names it does not
## know, and a boot test seeded from the renamed constant restores fine. Only
## existing v1 players notice, by waking in the cave forever.
##
## So the guard checks fixture names against THIS list, and CI anchors
## tests/data/shipped_attunements.txt append-only against the base revision.
## Removing or renaming a shipped name then fails twice: once in-game, once in
## CI. Adding a name is free; taking one away is the reviewable act.
const KNOWN_ATTUNEMENTS := [SHRINE_WARDENS]


## Whether this build can still act on `name` (not merely preserve it).
static func recognises(name: String) -> bool:
	return name in KNOWN_ATTUNEMENTS


## Whether this build can still register and act on a persisted discovery id.
static func recognises_discovery(name: String) -> bool:
	return name in KNOWN_DISCOVERIES


## The active vault path: the WAR_VAULT_PATH override when set, else the shipped
## default. Resolved fresh each call so a test can redirect before the game
## boots; inert in production.
static func vault_path() -> String:
	var override := OS.get_environment(VAULT_PATH_ENV)
	return override if not override.is_empty() else DEFAULT_PATH


static func exists() -> bool:
	return FileAccess.file_exists(vault_path())


## "" when the document is a vault this client fully understands, else a
## human-readable reason. Shape only: the ATTUNED NAMES are deliberately not
## checked against a known vocabulary, because an unrecognised name must be
## PRESERVED (see [method attune]) rather than treated as corruption — dropping
## it would silently discard progression on a round-trip.
static func validate(doc: Dictionary) -> String:
	var version = doc.get("version")
	if not (version is int or (version is float and version == floorf(version))):
		return "vault has no integer version"
	if int(version) < 1:
		return "vault version %d is not positive" % int(version)
	var schema := int(version)
	if schema > VAULT_READ_VERSION:
		return "vault version %d is newer than this client understands (%d)" % [schema, VAULT_READ_VERSION]
	var allowed_fields := VAULT_FIELDS_V1 if schema == 1 else VAULT_FIELDS_V2
	for field: String in doc:
		if field not in allowed_fields:
			return "unknown vault field '%s' — this client cannot apply it, refusing a half-truth" % field
	if doc.has("attuned"):
		if doc["attuned"] is not Array:
			return "attuned must be an array of respawn-point names"
		for name in (doc["attuned"] as Array):
			if name is not String:
				return "attuned entries must be strings (names are forward-only, never indices)"
	if doc.has("discoveries"):
		if doc["discoveries"] is not Array:
			return "discoveries must be an array of place names"
		for name in (doc["discoveries"] as Array):
			if name is not String:
				return "discoveries entries must be strings (names are forward-only, never indices)"
			if (name as String).is_empty():
				return "discoveries entries must be non-empty stable names"
	return ""


## The vault stored at path, or null when none exists, it cannot be parsed, or
## it fails validation. Null is a normal, non-fatal outcome: the caller runs
## session-only. Every rejection is pushed as an error so a broken vault is
## loud in logs rather than a silent progression loss.
static func load_from(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return _refuse(path, "cannot read %s" % path)
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if parsed is not Dictionary:
		return _refuse(path, "%s is not a JSON object" % path)
	var reason := validate(parsed)
	if reason != "":
		return _refuse(path, "refusing %s — %s" % [path, reason])
	return parsed


## Latch `path` as refused, log why, and return null.
##
## EVERY rejection of an existing file latches here, not only the ones reached
## through can_write(). The boot path calls load_saved() directly: if that
## rejected a newer vault without latching, and cloud sync or another client
## then removed the file, the next attunement would see an absent, never-refused
## path and happily write a v1 document that syncs back over the newer
## progression. The refusal has to attach to the PATH at the moment of refusal,
## not to the file still being there when someone later asks.
static func _refuse(path: String, message: String) -> Variant:
	push_error("SaveVault: " + message)
	_refused[path] = true
	return null


## Atomic: write a sibling temp file, then rename over the target — the same
## crash-safety the character save has. A half-written vault would read as
## corrupt on the next boot and (correctly) lock itself read-only, so the
## rename matters here too.
static func save_to(path: String, doc: Dictionary) -> bool:
	var reason := validate(doc)
	if reason != "":
		push_error("SaveVault: refusing to write an invalid vault — %s" % reason)
		return false
	var tmp_path := path + ".tmp"
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		push_error("SaveVault: cannot write %s" % tmp_path)
		return false
	file.store_string(JSON.stringify(doc, "  "))
	file.close()
	# Re-check readability IMMEDIATELY before the replace. A caller's earlier
	# can_write() is a point-in-time answer, and everything between it and here
	# — building the document, serialising, writing the temp file — is time in
	# which another process (a newer client sharing this user:// directory, or
	# cloud sync) can land a vault this build cannot read. Replacing it then
	# would destroy progression permanently.
	#
	# This NARROWS the window to the rename itself; it does not close it. Godot's
	# FileAccess exposes no advisory lock or atomic compare-and-swap, so a true
	# fix needs a lock file with O_EXCL semantics or an equivalent — tracked in
	# #262 rather than approximated badly here.
	if not can_write(path):
		push_error("SaveVault: %s became unreadable while writing — refusing to replace it" % path)
		DirAccess.remove_absolute(ProjectSettings.globalize_path(tmp_path))
		return false
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(tmp_path), ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("SaveVault: atomic replace failed (%d)" % err)
		return false
	return true


## Paths refused at least once this session. A refusal is LATCHED rather than
## re-derived from the file's current state, because the file can change under
## us: cloud sync, a second client, or the player deleting it can all make an
## unreadable vault vanish mid-session. Re-deriving would then answer "writable"
## and let this build write a v1 document that syncs back over the newer
## progression it just refused to read — exactly what refusing was protecting.
##
## Once refused, always refused, for the life of the process. Restarting is the
## deliberate act that re-examines the file, and by then whichever client owns
## that vault has had its chance to run.
static var _refused: Dictionary = {}


## Whether it is safe to write the vault at `path`. False when the path has been
## refused this session, or when a file is present but unreadable — a vault from
## a NEWER client, or a corrupt one. Writing then would replace progression this
## build cannot even read, which is the one way the separate-file design could
## still lose player state. Absent AND never-refused is writable: that is a first
## attunement, not a loss.
static func can_write(path: String) -> bool:
	if _refused.has(path):
		return false
	if not FileAccess.file_exists(path):
		return true
	# load_from() latches any rejection of an existing file (see _refuse), so a
	# failure here has already marked the path.
	return load_from(path) != null


## Forget every latched refusal. FOR TESTS ONLY — a test exercises several vault
## states through one throwaway path in a single process, and a latch that
## outlived the case would make every later case read as refused. Production
## never calls this: the latch is meant to outlive everything but a restart.
static func clear_refusals_for_test() -> void:
	_refused.clear()


## A minimal v1 vault — the starting document for a player who has never stored
## discovery state. Old state is never restamped merely to look current.
static func empty() -> Dictionary:
	return { "version": BASE_VAULT_VERSION, "attuned": [] }


## The attuned respawn-point names in `doc`, in shipped order.
static func attuned(doc: Dictionary) -> Array:
	var names := []
	for name in doc.get("attuned", []):
		names.append(String(name))
	return names


static func is_attuned(doc: Dictionary, name: String) -> bool:
	return name in attuned(doc)


## `doc` with `name` attuned. Returns a COPY with every other field carried
## through untouched, including any field or name this build does not itself
## use — a round-trip may never be a way to quietly drop progression. Attuning
## something already attuned is a no-op, so the list stays append-only and
## cannot accumulate duplicates.
static func attune(doc: Dictionary, name: String) -> Dictionary:
	var next: Dictionary = doc.duplicate(true)
	if not next.has("attuned"):
		next["attuned"] = []
	if name not in (next["attuned"] as Array):
		(next["attuned"] as Array).append(name)
	return next


## `doc` with every valid name in `names` added to its append-only discovery
## set. A v1 document contracts to v2 only when at least one discovery exists;
## an empty set leaves old state byte-shaped as v1. Existing v2 names this build
## does not register are preserved, because a rollback write may never erase
## progression introduced by a newer client.
static func record_discoveries(doc: Dictionary, names: Array) -> Dictionary:
	var reason := validate(doc)
	if not reason.is_empty():
		push_error("SaveVault: refusing to add discoveries to an invalid vault — %s" % reason)
		return {}
	var next: Dictionary = doc.duplicate(true)
	var merged: Array[String] = []
	for raw: Variant in next.get("discoveries", []):
		if raw is String and not (raw as String).is_empty() and raw not in merged:
			merged.append(raw)
	for raw: Variant in names:
		if raw is not String or (raw as String).is_empty():
			push_error("SaveVault: refusing an invalid discovery name")
			return {}
		if raw in merged:
			continue
		# Unknown names that were already in the document are rollback state and
		# remain above. Unknown names newly supplied by this build are different:
		# accepting one would originate permanent progression with no registered
		# landmark or append-only contract (a typo could never be repaired).
		if not recognises_discovery(raw):
			push_error("SaveVault: refusing to originate unknown discovery '%s'" % raw)
			return {}
		merged.append(raw)
	if merged.is_empty() and not next.has("discoveries"):
		return next
	merged.sort()
	next["version"] = VAULT_VERSION
	next["discoveries"] = merged
	return next


static func load_saved() -> Variant:
	return load_from(vault_path())


## Load the vault, or start an empty one when there is none. Returns null ONLY
## when a vault exists and could not be read — the read-only case, where the
## caller must run session-only and never write.
static func load_or_empty() -> Variant:
	if not exists():
		return empty()
	return load_saved()


## Attune `name` and persist it, at the active vault path. Returns true when the
## vault on disk now records it. False means the session keeps the attunement
## but the disk does not — the caller should carry on rather than fail the boot.
static func persist_attunement(name: String) -> bool:
	var path := vault_path()
	if not can_write(path):
		push_error("SaveVault: %s exists but is unreadable — refusing to overwrite it" % path)
		return false
	var current = load_or_empty()
	if current is not Dictionary:
		return false
	return save_to(path, attune(current, name))


## Add the live tracker's complete found set and persist it at the active vault
## path. False degrades to session-only discovery; it never blocks play and it
## never replaces a vault this build refused to read.
static func persist_discoveries(names: Array) -> bool:
	var path := vault_path()
	if not can_write(path):
		push_error("SaveVault: %s exists but is unreadable — refusing to overwrite it" % path)
		return false
	var current = load_or_empty()
	if current is not Dictionary:
		return false
	var next := record_discoveries(current, names)
	if next.is_empty():
		return false
	return save_to(path, next)
