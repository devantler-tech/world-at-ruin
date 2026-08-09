#!/usr/bin/env bash
# Keep the published update manifest and its documented shape reference honest
# about each other.
#
# docs/design/client-update-manifest.example.json is cited as THE shape of the
# manifest by the distribution ADR, cd.yaml, update_manifest.gd and
# update_decision.gd — four places that send an implementer there to learn what
# the origin of record serves. Nothing compared the two, so the reference was
# free to drift from the emitter in either direction, silently:
#
#   * a field the emitter INVENTS that the reference never declared ships to
#     players in a contract no implementer was told about;
#   * a field the reference DECLARES that nothing emits is a promise the origin
#     never keeps — someone writes a reader for it and waits forever.
#
# So this guard pins both directions. The emitted field set must be a subset of
# the reference, and every reference field that is not emitted must be listed in
# update-manifest-deferred-fields.tsv with the reason it is withheld. Withholding
# delivery fields is correct while there is nothing to deliver (see the class
# comment on UpdateManifest); what is not correct is withholding them silently.
#
# The emitted set is read from the manifest literal in `UpdateManifest.build`
# rather than by running Godot, so this stays a cheap text check that needs no
# engine in CI.
set -euo pipefail

MANIFEST_SOURCE='client/scripts/update_manifest.gd'
SHAPE_REFERENCE='docs/design/client-update-manifest.example.json'
DEFERRED_LEDGER='tools/update-manifest-deferred-fields.tsv'
SCRATCH_DIR=''

fail() {
	printf 'update-manifest shape guard: FAIL — %s\n' "$1" >&2
	exit 1
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && [ -d "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}

# The dotted field paths of the manifest dictionary literal in `build()`.
#
# Anchored on `"manifest": {` at END of line: `build()` also returns several
# early `{"manifest": {}, "error": ...}` refusals, and anchoring on the bare key
# would latch onto the first of those and extract an empty manifest — which would
# make the subset check below pass vacuously forever.
emitted_paths() {
	local source="$1"
	awk '
		BEGIN { started = 0; depth = 0; np = 0; pending = "" }
		!started && /"manifest"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
			started = 1; depth = 1; next
		}
		started == 1 {
			line = $0
			sub(/#.*$/, "", line)
			n = length(line)
			for (i = 1; i <= n; i++) {
				c = substr(line, i, 1)
				if (c == "\"") {
					j = index(substr(line, i + 1), "\"")
					if (j == 0) break
					tok = substr(line, i + 1, j - 1)
					i += j
					if (substr(line, i + 1) ~ /^[[:space:]]*:/) pending = tok
				} else if (c == "{") {
					if (pending != "") { emit(pending); stack[np++] = pending; pending = "" }
					depth++
				} else if (c == "}") {
					if (pending != "") { emit(pending); pending = "" }
					depth--; if (np > 0) np--
					if (depth == 0) { started = 2; exit }
				} else if (c == ",") {
					if (pending != "") { emit(pending); pending = "" }
				}
			}
		}
		function emit(key,   p, k) {
			p = ""
			for (k = 0; k < np; k++) p = p stack[k] "."
			print p key
		}
	' "$source" | LC_ALL=C sort -u
}

# The dotted field paths of the shape reference, with array indices dropped so a
# repeated element contributes its field names once.
reference_paths() {
	local source="$1"
	jq -er '
		[paths | map(select(type == "string")) | join(".")]
		| unique | .[] | select(length > 0)
	' "$source" | LC_ALL=C sort -u
}

# A ledger entry covers the path it names and everything nested under it, so one
# row explains a whole withheld block (`key`, `pack.full`) instead of a line per
# leaf.
covers() {
	local path="$1" entry="$2"
	[ "$path" = "$entry" ] && return 0
	case "$path" in
	"$entry".*) return 0 ;;
	esac
	return 1
}

ledger_paths() {
	local source="$1"
	sed -e 's/#.*$//' "$source" |
		awk -F '\t' 'NF >= 2 && $1 != "" { print $1 }' |
		LC_ALL=C sort -u
}

main() {
	[ -f "$MANIFEST_SOURCE" ] || fail "$MANIFEST_SOURCE is missing"
	[ -f "$SHAPE_REFERENCE" ] || fail "$SHAPE_REFERENCE is missing"
	[ -f "$DEFERRED_LEDGER" ] || fail "$DEFERRED_LEDGER is missing"

	local anchors
	anchors="$(grep -c '"manifest"[[:space:]]*:[[:space:]]*{[[:space:]]*$' "$MANIFEST_SOURCE" || true)"
	[ "$anchors" -eq 1 ] ||
		fail "expected exactly one multi-line \"manifest\": { literal in $MANIFEST_SOURCE, found $anchors — the emitted field set cannot be read unambiguously"

	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT

	emitted_paths "$MANIFEST_SOURCE" >"$SCRATCH_DIR/emitted"
	reference_paths "$SHAPE_REFERENCE" >"$SCRATCH_DIR/reference" ||
		fail "$SHAPE_REFERENCE is not readable JSON"

	# Vacuity floor. An extractor that silently matched nothing would make the
	# subset check below trivially true, which is the one way this guard could
	# pass while proving nothing.
	[ -s "$SCRATCH_DIR/emitted" ] ||
		fail "no fields could be read from the manifest literal in $MANIFEST_SOURCE — the guard cannot prove anything about a shape it failed to parse"
	grep -qx 'schema' "$SCRATCH_DIR/emitted" ||
		fail "the manifest literal in $MANIFEST_SOURCE does not declare 'schema' — the field set was misparsed, or the manifest lost the field every client reads first"
	[ -s "$SCRATCH_DIR/reference" ] ||
		fail "no fields could be read from $SHAPE_REFERENCE"

	local undocumented
	undocumented="$(LC_ALL=C comm -23 "$SCRATCH_DIR/emitted" "$SCRATCH_DIR/reference")"
	if [ -n "$undocumented" ]; then
		fail "the manifest publishes $(printf '%s' "$undocumented" | tr '\n' ' ')— absent from $SHAPE_REFERENCE. Add the field to the shape reference so the contract an implementer reads matches what the origin serves."
	fi

	ledger_paths "$DEFERRED_LEDGER" >"$SCRATCH_DIR/ledger"
	[ -s "$SCRATCH_DIR/ledger" ] ||
		fail "$DEFERRED_LEDGER lists no fields — every withheld field must carry a reason"

	# Every reference field that is not emitted has to be covered by a ledger
	# entry: the entry itself, or an ancestor of it.
	local unaccounted='' covered_any="$SCRATCH_DIR/covered"
	: >"$covered_any"
	local path entry matched
	while IFS= read -r path; do
		if grep -qxF "$path" "$SCRATCH_DIR/emitted"; then
			continue
		fi
		matched=''
		while IFS= read -r entry; do
			if covers "$path" "$entry"; then
				matched="$entry"
				break
			fi
		done <"$SCRATCH_DIR/ledger"
		if [ -z "$matched" ]; then
			unaccounted="$unaccounted $path"
		else
			printf '%s\n' "$matched" >>"$covered_any"
		fi
	done <"$SCRATCH_DIR/reference"

	if [ -n "$unaccounted" ]; then
		fail "$SHAPE_REFERENCE declares$unaccounted, which this build does not publish and $DEFERRED_LEDGER does not explain. Either emit the field from $MANIFEST_SOURCE, or record why it is withheld — a documented field with no owner is a promise the origin never keeps."
	fi

	# A ledger entry that explains nothing is stale: the field graduated or was
	# renamed, and the row outlived it.
	local dead=''
	while IFS= read -r entry; do
		grep -qxF "$entry" "$covered_any" || dead="$dead $entry"
	done <"$SCRATCH_DIR/ledger"
	if [ -n "$dead" ]; then
		fail "$DEFERRED_LEDGER explains$dead, which $SHAPE_REFERENCE no longer declares as unpublished. Drop the stale row."
	fi

	printf 'update-manifest shape guard: PASS — %s published fields are all declared by the shape reference, and its %s withheld fields each carry a reason\n' \
		"$(wc -l <"$SCRATCH_DIR/emitted" | tr -d ' ')" \
		"$(wc -l <"$SCRATCH_DIR/ledger" | tr -d ' ')"
}

main "$@"
