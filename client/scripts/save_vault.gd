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
##
## Both of those judge the vault as it is at one instant, which is why every
## write is additionally taken under a cross-process LOCK (#262, see
## [method _acquire_lock]). Refuse-to-read handles a newer vault we can already
## see; the lock handles one ARRIVING while we are mid-write. Without it,
## read-merge-write is check-then-act: two clients can each read the same
## document, each merge their own change into it, and the slower writer's rename
## silently discards the faster one's progression. The lock is honest about its
## reach — it binds SaveVault writers, so it closes the client-versus-client case
## the no-resets law actually turns on. A foreign writer (cloud sync, a backup
## agent, a hand edit) never takes it, and for those the pre-rename re-check in
## [method _save_to_locked] remains the only, narrower, protection.

const DEFAULT_PATH := "user://vault.json"

## Environment override for the active vault path, mirroring CharacterStore's
## WAR_SAVE_PATH seam. Empty/unset means the shipped default — production never
## sets it; tests point it at a throwaway file so no test can damage a real
## player's progression.
const VAULT_PATH_ENV := "WAR_VAULT_PATH"

## The write lock's suffix. The lock is a DIRECTORY beside the vault, because
## `DirAccess.make_dir_absolute` is the only exclusive-create primitive Godot
## exposes: it is `mkdir`, which is atomic on every platform we ship and returns
## ERR_ALREADY_EXISTS rather than succeeding when the path is taken. A lock made
## from a plain `FileAccess.open` would be check-then-act all over again — two
## processes would both "create" it — which is precisely the approximation #262
## refused to accept. The directory is kept EMPTY: a non-empty directory cannot
## be removed in one call, and release must never be the step that fails.
const LOCK_SUFFIX := ".lock"

## How long a lock may go unreleased before another process may break it.
##
## The critical section is a validate, a small JSON serialise, a temp-file write
## and a rename — sub-millisecond in practice, and entirely local. 30s is roughly
## four orders of magnitude of headroom, which is the point: the two failure
## directions are NOT symmetric. Breaking a lock a live process still holds
## reopens the exact interleaving this lock exists to prevent, and that loss is
## permanent. Waiting too long merely refuses one write, and a refused write
## degrades to session-only — the vault's existing law, and cheap. So the timeout
## errs long deliberately; it exists only so a crashed process cannot wedge the
## vault forever, not to keep writes prompt.
const LOCK_STALE_SECONDS := 30

## Test-only override for [constant LOCK_STALE_SECONDS], mirroring the
## WAR_VAULT_PATH seam. Production never sets it; a test sets 0 so an existing
## lock is immediately stale and the recovery path can be proven without
## sleeping. Unset, empty, non-integer or negative values keep the shipped
## default, so a malformed value can never shorten the window in the field.
const LOCK_STALE_ENV := "WAR_VAULT_LOCK_STALE_SECONDS"

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
##
## Held under the cross-process write lock, so a direct save_to() is as safe as
## one reached through persist_attunement(). The lock is reentrant, so the
## nesting those helpers create costs nothing and cannot self-deadlock.
static func save_to(path: String, doc: Dictionary) -> bool:
	if not _acquire_lock(path):
		return false
	var wrote := _save_to_locked(path, doc)
	_release_lock(path)
	return wrote


## save_to()'s body, with the write lock already held. Split out so acquisition
## and release live on ONE path each: GDScript has no `defer`, and a lock leaked
## down some early-return branch would wedge the vault for LOCK_STALE_SECONDS.
static func _save_to_locked(path: String, doc: Dictionary) -> bool:
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
	# Against another CLIENT this is now belt-and-braces: the write lock (#262)
	# already excludes a competing SaveVault writer, so no second client can be
	# between our check and our rename. It is kept because the lock cannot cover
	# every writer. Cloud sync, a backup agent restoring a file, or the player
	# editing the vault by hand know nothing about our lock, and for those this
	# re-check remains the only thing standing between a downgrade write and
	# permanently destroyed progression. It narrows that window to the rename
	# syscall; it does not close it, and no in-process primitive can.
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


## Every write lock this PROCESS holds, lock path -> reentrancy depth.
##
## Reentrancy is what lets persist_attunement() hold the lock across its whole
## read-modify-write and still call save_to(), which takes the same lock. Without
## it the nested acquire would collide with our OWN directory and the write would
## refuse itself — a deadlock that looks exactly like healthy contention.
static var _held_locks: Dictionary = {}


## The write lock's directory path for the vault at `path`.
static func lock_path(path: String) -> String:
	return path + LOCK_SUFFIX


## The stale-lock timeout: the LOCK_STALE_ENV override when it is a non-negative
## integer, else the shipped default. Unset and malformed both fall through to
## the default, so the window can never be shortened by accident.
static func lock_stale_seconds() -> int:
	var raw := OS.get_environment(LOCK_STALE_ENV)
	if raw.is_valid_int():
		var seconds := int(raw)
		if seconds >= 0:
			return seconds
	return LOCK_STALE_SECONDS


## Take the cross-process write lock for the vault at `path`.
##
## `mkdir` decides the race: exactly one caller creates the directory, every
## other gets ERR_ALREADY_EXISTS — threads, processes, or two differently-
## versioned clients sharing one user:// directory alike. Failing to acquire is
## not an error the player should feel: the caller degrades to session-only,
## which is the vault's standing answer to doubt.
static func _acquire_lock(path: String) -> bool:
	var lock := lock_path(path)
	var depth := int(_held_locks.get(lock, 0))
	if depth > 0:
		_held_locks[lock] = depth + 1
		return true
	var absolute := ProjectSettings.globalize_path(lock)
	var err := DirAccess.make_dir_absolute(absolute)
	if err == ERR_ALREADY_EXISTS and _lock_is_stale(lock):
		# A crashed process left it behind. Remove-then-recreate stays safe under
		# contention: if two processes both judge it stale, both remove (one is a
		# no-op) and both then race mkdir, which exactly one still wins.
		push_warning("SaveVault: breaking a stale vault write lock at %s" % lock)
		DirAccess.remove_absolute(absolute)
		err = DirAccess.make_dir_absolute(absolute)
	if err == ERR_ALREADY_EXISTS:
		push_error(
			"SaveVault: another process holds the vault write lock at %s — refusing to write" % lock)
		return false
	if err != OK:
		# Anything else is an environment fault, not contention — an unwritable or
		# missing parent directory, say. Both refuse the write, but reporting them
		# as contention would send whoever reads this log hunting a race that is
		# not happening.
		push_error(
			"SaveVault: cannot create the vault write lock at %s (error %d) — refusing to write"
			% [lock, err])
		return false
	_held_locks[lock] = 1
	return true


## Whether the lock at `lock` has gone unreleased past the stale timeout.
##
## Every uncertain answer here is NOT-stale, because the two mistakes are not
## equally bad. Breaking a lock a live writer still holds reopens the exact
## interleaving this exists to prevent and destroys progression permanently;
## declining to break one merely refuses a write, which degrades to session-only
## — the vault's standing answer to doubt.
##
## So an unreadable timestamp (0, as Godot reports for a path it cannot stat, or
## a lock that vanished under us) reads as FRESH rather than stale. Reading it
## the other way would be far worse than it looks: on any platform where a
## directory's mtime could not be read, EVERY lock would be instantly stealable
## and the lock would silently degrade to no lock at all, with nothing failing to
## show it. The cost of this direction is bounded — one refused write, retried on
## the next attempt once the directory is really gone.
##
## A clock that jumped backwards yields a negative age and likewise reads as
## fresh, for the same reason.
static func _lock_is_stale(lock: String) -> bool:
	var created := int(FileAccess.get_modified_time(lock))
	if created <= 0:
		return false
	return int(Time.get_unix_time_from_system()) - created >= lock_stale_seconds()


## Release one level of this process's lock for `path`, removing the directory
## when the outermost holder lets go. Releasing a lock we do not hold is a no-op
## rather than an error: it must be safe to call on any failure path without
## first proving acquisition got that far.
static func _release_lock(path: String) -> void:
	var lock := lock_path(path)
	var depth := int(_held_locks.get(lock, 0))
	if depth <= 0:
		return
	if depth > 1:
		_held_locks[lock] = depth - 1
		return
	_held_locks.erase(lock)
	DirAccess.remove_absolute(ProjectSettings.globalize_path(lock))


## Drop every lock this process holds. FOR TESTS ONLY, mirroring
## clear_refusals_for_test(): one test drives several contention cases through a
## single throwaway path and has to get back to a known state between them.
static func clear_locks_for_test() -> void:
	for lock: String in _held_locks.keys():
		DirAccess.remove_absolute(ProjectSettings.globalize_path(lock))
	_held_locks.clear()


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
	if not _acquire_lock(path):
		return false
	var stored := _persist_attunement_locked(path, name)
	_release_lock(path)
	return stored


## persist_attunement()'s read-modify-write, with the lock already held.
##
## The lock spans the WHOLE sequence — can_write, load, merge, save — not just
## the write. That is the point of #262: reading a vault, merging into it and
## writing the result is only correct if nothing else replaced the file in
## between, and a lock taken at the write alone would still have re-introduced
## the check-then-act it was meant to remove.
static func _persist_attunement_locked(path: String, name: String) -> bool:
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
	if not _acquire_lock(path):
		return false
	var stored := _persist_discoveries_locked(path, names)
	_release_lock(path)
	return stored


## persist_discoveries()'s read-modify-write, with the lock already held — the
## discovery half of the same whole-sequence guarantee as
## [method _persist_attunement_locked]. Discoveries merge into the set already on
## disk, so an interleaved write here does not just lose the new name, it can
## drop names a newer client had recorded.
static func _persist_discoveries_locked(path: String, names: Array) -> bool:
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
