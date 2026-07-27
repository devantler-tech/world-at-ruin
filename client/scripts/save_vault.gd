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
##     That read-only latch is per-PATH and permanent, which is right while the
##     bytes are still there — and wrong once no client can read them at all. A
##     document that does not parse is progression nobody can recover, so leaving
##     it in place refuses every future write for the life of the install: the
##     player is told each session that the Reach may not remember, and the only
##     remedy is deleting a file inside user:// that the game never mentions. So
##     a vault NO CLIENT COULD OWN is set aside at boot instead — preserved, never
##     deleted — and a fresh one is started (#290, see
##     [method quarantine_unreadable]). The distinction is exactly the one between
##     "no client can read this" and "this client cannot read this", and it is
##     drawn at the VERSION (see [method _is_unownable]): a document declaring a
##     version is somebody's progression and is left untouched however far ahead
##     of this build it is, while one that is not an object at all, or carries no
##     usable integer version, was written by no client that ever shipped.
##
## Both of those judge the vault as it is at one instant, which is why every
## write is additionally taken under a cross-process LOCK (#262, see
## [method FileLock.acquire]). Refuse-to-read handles a newer vault we can already
## see; the lock handles one ARRIVING while we are mid-write. Without it,
## read-merge-write is check-then-act: two clients can each read the same
## document, each merge their own change into it, and the slower writer's rename
## silently discards the faster one's progression.
##
## Be precise about its reach, because it is narrower than "two clients cannot
## collide". A lock only excludes writers that TAKE it, so it holds between builds
## that carry this protocol and nothing more:
##  - a build from BEFORE this protocol — a retained or rollback client, which the
##    updater deliberately keeps runnable — writes this same file without creating
##    or checking the lock, and walks straight through it;
##  - a foreign writer (cloud sync, a backup agent, a hand edit) never takes it
##    either.
## For both, the pre-rename re-check in [method _save_to_locked] plus the
## refuse-a-newer-version rule are the protection, and they narrow the window to
## the rename rather than closing it. So this lock removes lost updates between
## lock-aware builds now, and only becomes a general guarantee once every
## still-runnable build carries it. Do not describe it as closing the
## differently-versioned case outright.

const DEFAULT_PATH := "user://vault.json"

## Environment override for the active vault path, mirroring CharacterStore's
## WAR_SAVE_PATH seam. Empty/unset means the shipped default — production never
## sets it; tests point it at a throwaway file so no test can damage a real
## player's progression.
const VAULT_PATH_ENV := "WAR_VAULT_PATH"

## Suffix for a vault set aside because no client could own it. What follows it is
## a per-attempt unique stamp, so a second corruption never overwrites the first —
## preserving the bytes is the entire point (#290), and a predictable name is a
## way to lose them (see [method _free_quarantine_path]).
const QUARANTINE_SUFFIX := ".unreadable-"

## How many unique destinations are tried before giving up. A bound rather than an
## unbounded search: if this many freshly-stamped names are all somehow taken,
## something is wrong that setting aside one more will not fix, and refusing is
## the only direction that cannot destroy bytes.
const QUARANTINE_MAX_ATTEMPTS := 100

## How long an unparseable vault must have sat UNCHANGED before it is set aside.
##
## Quarantine exists because bytes no client can parse otherwise wedge
## progression saving forever (#290). The one case where setting them aside is
## WRONG is a write still in flight: cloud sync or a backup restore can
## materialise a partial file and complete it moments later, and those partial
## bytes may be a NEWER client's progression. Quarantining them would let this
## build start a fresh v1 vault that the newer client later reads as
## authoritative — turning a transient partial write into permanent loss.
##
## An age threshold separates the two without any new persisted state. The
## failure directions are as lopsided as the lock's, and point the same way:
##  - setting aside a document that was about to be completed can cost a newer
##    client its progression, and nothing ever asks for quarantined bytes back;
##  - waiting longer merely leaves the player session-only for one more launch,
##    which is the vault's standing answer to doubt.
## So this errs long on purpose. It is a liveness HEURISTIC about whether some
## writer is still working, exactly like [constant FileLock.STALE_SECONDS], and it is
## not a mechanism for making recovery prompt.
##
## The alternative of requiring the same bytes across two boots was rejected: it
## needs a fourth persisted user:// file — with its own env seam and
## SaveIsolation redirect — to record a fact the file's own mtime already carries.
const QUARANTINE_MIN_AGE_SECONDS := 300

## Test-only override for [constant QUARANTINE_MIN_AGE_SECONDS], mirroring
## [constant FileLock.STALE_ENV]. Production never sets it; a test sets 0 so a
## just-written probe is immediately eligible. Unset, empty, non-integer and
## negative values all keep the shipped default, so the window can never be
## SHORTENED by a malformed value — the direction that could destroy progression.
const QUARANTINE_MIN_AGE_ENV := "WAR_VAULT_QUARANTINE_MIN_AGE_SECONDS"

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
	if not FileLock.acquire(path):
		return false
	var wrote := _save_to_locked(path, doc)
	FileLock.release(path)
	return wrote


## save_to()'s body, with the write lock already held. Split out so acquisition
## and release live on ONE path each: GDScript has no `defer`, and a lock leaked
## down some early-return branch would wedge the vault for FileLock.STALE_SECONDS.
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
	# Prove we are STILL the lock's holder. A reclaimer that misjudged this live
	# lock as abandoned would have moved it away, and another writer could then
	# hold it legitimately. Replacing the vault while that is true is the one
	# outcome the lock exists to prevent, so a lost lock abandons the write.
	#
	# ⚠️ This is a point-in-time check, and it cannot be made otherwise here. A
	# holder that has already outlived the stale timeout can be reclaimed in the
	# interval between this returning true and the rename below, after which
	# another writer may hold the lock while this one still replaces the vault.
	# Closing that needs an OS-level lock held ACROSS the rename — `flock`, or an
	# equivalent — and Godot's FileAccess/DirAccess expose none, which is the same
	# wall #262 started at. What bounds it instead: the timeout is far longer than
	# any real critical section, the interval itself is a single syscall, and the
	# readability re-check above still refuses to replace a vault this build cannot
	# read, so the catastrophic case (a downgrade overwriting newer progression)
	# stays closed even when the benign one (a lost update between same-version
	# writers) slips through. Detecting that properly wants a compare-and-swap on
	# the vault's own bytes rather than a lock — tracked separately.
	if not FileLock.owns(path):
		push_error("SaveVault: lost the write lock for %s while writing — refusing to replace it" % path)
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


## The quarantine window in seconds: the QUARANTINE_MIN_AGE_ENV override when it
## is a non-negative integer, else the shipped default. Unset and malformed both
## fall through to the default, so the window can never be shortened by accident.
static func quarantine_min_age_seconds() -> int:
	var raw := OS.get_environment(QUARANTINE_MIN_AGE_ENV)
	if raw.is_valid_int():
		var seconds := int(raw)
		if seconds >= 0:
			return seconds
	return QUARANTINE_MIN_AGE_SECONDS


## Whether the document at `path` is one NO client could own.
##
## Deliberately narrower than "load_from() refused it", and the line is drawn at
## the VERSION rather than at validity:
##  - not a JSON object at all — no vault is an array or a scalar in any version,
##    so nothing could ever have written it as progression;
##  - a JSON object carrying no usable integer version (`{}`, `{"version":"bad"}`,
##    `{"version":0}`) — `version` is the whole forward-only contract, the one
##    field whose meaning is fixed across every schema, so a document without one
##    was written by no client that ever shipped and can be read by none that
##    ever will.
##
## Everything else is left exactly where it is, including a document that FAILS
## validation while declaring a version this build knows. A version is a claim of
## ownership by some client, and this build does not adjudicate that claim: the
## cost of being wrong is destroyed progression, while the cost of being cautious
## is a shape that essentially only arises from hand-editing staying read-only.
##
## A file that cannot be OPENED is not judged: that is a permission or locking
## fault about this process, not about the bytes, and moving a file we could not
## read would be acting on a guess.
static func _is_unownable(path: String) -> bool:
	var data = _read_document(path)
	if data == null:
		return false
	return _is_unownable_bytes(data)


## The document's raw bytes, or null when it cannot be opened.
##
## Quarantine judges and re-verifies from BYTES rather than re-reading through a
## parser each time, because the bytes are the identity of the document being
## moved (see [method _quarantine_locked]). Null and an empty array are different
## answers: a zero-length file is a real, unownable document, while an unopenable
## one is a fault about this process and must not be judged at all.
static func _read_document(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var data := file.get_buffer(file.get_length())
	file.close()
	return data


## Whether `data` is a document no client could own — see [method _is_unownable].
static func _is_unownable_bytes(data: PackedByteArray) -> bool:
	var parsed = JSON.parse_string(data.get_string_from_utf8())
	if parsed is not Dictionary:
		return true
	# The same integer test validate() applies, so the two can never disagree
	# about what counts as a version.
	var version = (parsed as Dictionary).get("version")
	if version is int or (version is float and version == floorf(version)):
		return int(version) < 1
	return true


## Set aside a vault no client can read so it stops wedging progression saving,
## and return the path its bytes were preserved at ("" when nothing was moved).
##
## Called once on the boot path, before the vault is read. It is deliberately NOT
## part of load_from(): reading must stay free of side effects, and the
## readability re-check inside [method _save_to_locked] runs at the most
## dangerous possible moment — mid-write, holding the lock — where moving the
## file would be catastrophic rather than helpful.
##
## The cheap checks run before the lock only so a healthy boot does not create a
## lock directory it has no use for; every condition is re-derived under the
## lock, which is the authoritative pass.
static func quarantine_unreadable(path: String) -> String:
	if not FileAccess.file_exists(path):
		return ""
	if not _is_unownable(path):
		return ""
	if not FileLock.acquire(path):
		return ""
	var moved := _quarantine_locked(path)
	FileLock.release(path)
	return moved


## quarantine_unreadable()'s body, with the write lock held.
static func _quarantine_locked(path: String) -> String:
	# Re-derive every condition: the pre-checks are an optimisation, and another
	# writer may have replaced this file with a perfectly good vault since.
	if not FileAccess.file_exists(path):
		return ""
	# Capture the exact bytes being judged. Everything below re-verifies against
	# THIS array, because the bytes are what identifies the document — see the
	# pre-rename check.
	var observed = _read_document(path)
	if observed == null:
		return ""
	if not _is_unownable_bytes(observed):
		return ""
	var modified := int(FileAccess.get_modified_time(path))
	if modified <= 0:
		# No usable timestamp means no way to tell an abandoned document from one
		# still being written. Leave it: session-only play is recoverable, a
		# premature quarantine of a newer client's progression is not.
		return ""
	if int(Time.get_unix_time_from_system()) - modified < quarantine_min_age_seconds():
		return ""
	var target := _free_quarantine_path(path)
	if target.is_empty():
		push_error(
			"SaveVault: could not find a free destination beside %s in %d attempts — refusing to set it aside"
			% [path, QUARANTINE_MAX_ATTEMPTS])
		return ""
	# Judge the document one last time, IMMEDIATELY before the rename — the same
	# discipline, and for the same reason, as the readability re-check in
	# [method _save_to_locked]. Everything above (the timestamp read, the free-slot
	# search) is time in which a writer that does not take our lock — cloud sync, a
	# backup restore, a pre-lock build the updater deliberately keeps runnable —
	# can land a real vault at this path. Moving THAT aside would destroy exactly
	# the progression quarantine exists to protect, and would then clear the latch
	# and start a fresh older vault on top of it.
	#
	# This narrows the window to the rename syscall; it cannot close it, for the
	# same reason that re-check cannot, and no in-process primitive can.
	# Prove it is the SAME document whose age was judged, BY ITS BYTES. Unownability
	# alone is not enough: a foreign writer can replace stale corrupt bytes with
	# freshly arriving, still-unparseable ones — a newer client's write caught
	# mid-flight — and that file would inherit the OLD file's staleness verdict,
	# bypassing the age gate exactly where it matters most.
	#
	# The timestamp cannot carry that proof on its own. Copy and sync tools
	# routinely PRESERVE modification time while replacing content (`cp -p`,
	# `rsync -t`), so an mtime match is consistent with a completely different
	# document. Comparing the bytes is what actually establishes identity, and it
	# re-derives unownability for free.
	var current = _read_document(path)
	if current == null or (current as PackedByteArray) != (observed as PackedByteArray):
		push_warning(
			"SaveVault: %s changed while it was being set aside — leaving it for the next launch" % path)
		return ""
	# mtime is still checked, and it is NOT redundant: identical bytes rewritten a
	# moment ago are a live writer at work, not the abandoned document whose age
	# passed the gate.
	if int(FileAccess.get_modified_time(path)) != modified:
		push_warning(
			"SaveVault: %s was rewritten while it was being set aside — leaving it" % path)
		return ""
	var err := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(target))
	if err != OK:
		push_error(
			"SaveVault: could not set aside the unreadable vault at %s (error %d)" % [path, err])
		return ""
	# The latch existed to stop this build writing over progression it could not
	# read. Those bytes are now preserved at `target` and the path holds nothing,
	# so there is nothing left to protect — and leaving the latch set would keep
	# the player wedged for the rest of the session, which is the defect this
	# closes.
	_refused.erase(path)
	push_warning(
		"SaveVault: set aside an unreadable vault — %s is preserved at %s" % [path, target])
	return target


## A free quarantine destination beside `path`, or "" if one cannot be found.
##
## The name is UNIQUE PER ATTEMPT (pid + microseconds), not an index, and that is
## a safety property rather than tidiness. `rename()` REPLACES its destination
## silently, so any name a second party could also derive is a way to destroy
## bytes this feature promises to preserve: with `unreadable-0`, a sync agent or
## recovery tool creating that exact path between the vacancy check and the
## rename would have its file overwritten — and no vacancy check can close that,
## because Godot exposes no exclusive-create for FILES (only `make_dir_absolute`,
## which cannot be a rename target). A name a foreign writer cannot predict
## sidesteps the race instead of trying to win it.
##
## This is the same per-attempt naming, for the same reason, as the reclaim
## target in [method FileLock._reclaim_if_abandoned].
##
## The vacancy check is kept as cheap defence: it also rejects a DIRECTORY, which
## `FileAccess.file_exists()` reports as absent and which a rename cannot replace.
## A fresh microsecond on each attempt means a retry genuinely changes the name.
static func _free_quarantine_path(path: String) -> String:
	for _attempt in range(QUARANTINE_MAX_ATTEMPTS):
		var candidate := "%s%s%d-%d" % [
			path, QUARANTINE_SUFFIX, OS.get_process_id(), Time.get_ticks_usec()]
		if _slot_is_free(candidate):
			return candidate
	return ""


## Whether nothing at all occupies `candidate`.
##
## A DIRECTORY counts as occupied, not just a file. `FileAccess.file_exists()`
## answers false for a directory, so a sync restore or a manual recovery that
## left one named like a quarantine slot would be chosen as free — the rename
## onto it then fails, and because the search is deterministic every later launch
## picks the SAME slot and fails identically. That is a permanent wedge, which is
## the one outcome this whole change exists to remove.
static func _slot_is_free(candidate: String) -> bool:
	if FileAccess.file_exists(candidate):
		return false
	return not DirAccess.dir_exists_absolute(ProjectSettings.globalize_path(candidate))


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
	if not FileLock.acquire(path):
		return false
	var stored := _persist_attunement_locked(path, name)
	FileLock.release(path)
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
	if not FileLock.acquire(path):
		return false
	var stored := _persist_discoveries_locked(path, names)
	FileLock.release(path)
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
