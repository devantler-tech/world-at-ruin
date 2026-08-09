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

# The dotted field paths of the manifest dictionary literal in `build()`, each
# tagged with the KIND of value it carries: `C` when the key opens a literal
# collection the parser then walks, `V` for anything else (a scalar, a constant,
# or a call).
#
# Anchored on `"manifest": {` at END of line: `build()` also returns several
# early `{"manifest": {}, "error": ...}` refusals, and anchoring on the bare key
# would latch onto the first of those and extract an empty manifest — which would
# make the subset check below pass vacuously forever.
#
# Frames carry a NAME and are pushed for `{` and `[` alike. An array's elements
# are anonymous frames, so an array key stays on the stack across ALL of its
# elements: popping it with the first element's `}` would emit the second
# element's fields at the manifest root, and the guard would reject a valid
# multi-element `rollback_targets` catalogue as undocumented.
emitted_paths() {
	local source="$1"
	awk '
		BEGIN { started = 0; depth = 0; np = 0; pending = ""; nout = 0 }
		!started && /"manifest"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ {
			started = 1; depth = 1; next
		}
		started == 1 {
			line = $0
			n = length(line)
			for (i = 1; i <= n; i++) {
				c = substr(line, i, 1)
				if (c == "\"") {
					# Walked rather than found with index(), so a BACKSLASH-ESCAPED
					# quote inside the string does not end the token early. Ending it
					# early leaves the remainder of the string being scanned as
					# structure, where its `,`/`}`/`]`/`#` desynchronize depth and
					# fields are emitted under the wrong parent — silently.
					tok = ""; k = i + 1; closed = 0
					while (k <= n) {
						ch = substr(line, k, 1)
						if (ch == "\\") { k += 2; continue }
						if (ch == "\"") { closed = 1; break }
						tok = tok ch
						k++
					}
					if (!closed) break
					i = k
					if (substr(line, i + 1) ~ /^[[:space:]]*:/) pending = tok
				} else if (c == "{" || c == "[") {
					if (pending != "") { emit(pending, "C"); push(pending, nout); pending = "" }
					else push("", nout)
					depth++
				} else if (c == "}" || c == "]") {
					if (pending != "") { emit(pending, "V"); pending = "" }
					depth--; pop()
					if (depth == 0) { started = 2; exit }
				} else if (c == ",") {
					if (pending != "") { emit(pending, "V"); pending = "" }
				} else if (c == "#") {
					# A comment runs to end of line. Handled HERE rather than by
					# stripping the line first: a `#` inside a quoted value is
					# consumed by the quote branch above, so stripping ahead of the
					# scan would cut a string short, drop the terminating `,`/`}`/`]`
					# with it, and desynchronize depth — emitting paths under the
					# wrong parent with no error at all.
					break
				}
			}
		}
		function push(name, mark) { stack[np] = name; np++ }
		function pop() { if (np > 0) np-- }
		function emit(key, kind,   p, k) {
			p = ""
			for (k = 0; k < np; k++) if (stack[k] != "") p = p stack[k] "."
			pathout[nout] = p key
			kindout[nout] = kind
			nout++
		}
		END {
			for (k = 0; k < nout; k++) print pathout[k] "\t" kindout[k]
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

# A row is `<path><TAB><reason>`. The reason must carry non-whitespace text: a
# bare `signature<TAB>` would otherwise satisfy a field-count test and let an
# omission be silenced by an empty explanation, which is the one thing the ledger
# exists to prevent.
ledger_rows_without_reason() {
	local source="$1"
	sed -e 's/^[[:space:]]*#.*$//' "$source" |
		awk '
			/^[[:space:]]*$/ { next }
			{
				rest = $0
				if (sub(/^[^\t]*\t/, "", rest) == 0) rest = ""
				path = $0
				sub(/\t.*$/, "", path)
				if (path ~ /^[[:space:]]*$/) next
				if (rest !~ /[^[:space:]]/) print path
			}
		'
}

ledger_paths() {
	local source="$1"
	sed -e 's/^[[:space:]]*#.*$//' "$source" |
		awk -F '\t' 'NF >= 2 && $1 != "" && $2 ~ /[^[:space:]]/ { print $1 }' |
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

	emitted_paths "$MANIFEST_SOURCE" >"$SCRATCH_DIR/emitted-kinds"
	cut -f1 <"$SCRATCH_DIR/emitted-kinds" | LC_ALL=C sort -u >"$SCRATCH_DIR/emitted"
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

	local reasonless
	reasonless="$(ledger_rows_without_reason "$DEFERRED_LEDGER" | tr '\n' ' ')"
	if [ -n "${reasonless// /}" ]; then
		fail "$DEFERRED_LEDGER withholds ${reasonless}with no explanation. An empty reason silences a field without accounting for it, which is the one thing this ledger exists to prevent."
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
		# EVERY covering entry is recorded, not just the first. Stopping at the
		# first match would leave a second, equally-correct row unrecorded, and
		# the stale-row check below would then refuse while naming a row that is
		# right — reachable as soon as a broad `pack` row joins `pack.full`.
		while IFS= read -r entry; do
			if covers "$path" "$entry"; then
				matched="$entry"
				printf '%s\n' "$entry" >>"$covered_any"
			fi
		done <"$SCRATCH_DIR/ledger"
		if [ -z "$matched" ]; then
			unaccounted="$unaccounted $path"
		fi
	done <"$SCRATCH_DIR/reference"

	if [ -n "$unaccounted" ]; then
		fail "$SHAPE_REFERENCE declares$unaccounted, which this build does not publish and $DEFERRED_LEDGER does not explain. Either emit the field from $MANIFEST_SOURCE, or record why it is withheld — a documented field with no owner is a promise the origin never keeps."
	fi

	LC_ALL=C sort -u "$covered_any" >"$SCRATCH_DIR/covered-unique"

	# A ledger row excusing a block's contents is only trustworthy while that
	# block is an EMPTY LITERAL this parser can see into. The moment the key is
	# fed by an expression — `rollback_targets: build_targets()` — its real
	# element fields become invisible here, while the row goes on excusing every
	# documented descendant. The guard would then pass most confidently at the
	# exact moment delivery switched on. Refuse instead, and say what to do.
	local opaque='' entry_kind
	while IFS= read -r entry; do
		grep -qxF "$entry" "$SCRATCH_DIR/emitted" || continue
		entry_kind="$(awk -F '\t' -v p="$entry" '$1 == p { print $2; exit }' "$SCRATCH_DIR/emitted-kinds")"
		[ "$entry_kind" = "C" ] || opaque="$opaque $entry"
	done <"$SCRATCH_DIR/covered-unique"
	if [ -n "$opaque" ]; then
		fail "$DEFERRED_LEDGER defers the contents of$opaque, but $MANIFEST_SOURCE no longer builds it as a literal this guard can read. Its element fields are now invisible here while the row still excuses them. Either build it as a literal, or extend this guard to inspect the emitted manifest before that block starts shipping data."
	fi

	# A row may only excuse fields that are actually WITHHELD. The moment the
	# block starts publishing one of them, the row is excusing a field that is
	# shipping — so the guard would report agreement about content nobody checked,
	# most confidently at the moment delivery switched on. Covering the entry
	# itself is fine and expected: `rollback_targets` ships as an empty array
	# while every element field stays withheld.
	local shipped=''
	while IFS= read -r entry; do
		while IFS= read -r path; do
			[ "$path" = "$entry" ] && continue
			covers "$path" "$entry" || continue
			shipped="$shipped $path"
		done <"$SCRATCH_DIR/emitted"
	done <"$SCRATCH_DIR/covered-unique"
	if [ -n "$shipped" ]; then
		fail "$DEFERRED_LEDGER excuses$shipped, but $MANIFEST_SOURCE publishes those fields. A row may only defer what is actually withheld — drop it so the published contents are checked against $SHAPE_REFERENCE."
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
