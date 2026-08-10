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
		BEGIN { started = 0; depth = 0; np = 0; pending = ""; nout = 0; SQ = sprintf("%c", 39) }
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
					tok = ""; k = i + 1; closed = 0; escaped = 0
					while (k <= n) {
						ch = substr(line, k, 1)
						if (ch == "\\") { escaped = 1; k += 2; continue }
						if (ch == "\"") { closed = 1; break }
						tok = tok ch
						k++
					}
					if (!closed) {
						# The token never terminated on this line. Continuing would
						# scan the rest of the file as structure and emit paths under
						# the wrong parent with no error — the same silent drift the
						# escaped-quote handling above exists to prevent.
						print "D\tunterminated-string\t" tok
						exit
					}
					i = k
					if (substr(line, i + 1) ~ /^[[:space:]]*:/) {
						# The escape is DROPPED by the walk above, so `"\tschema"` and
						# `schema` both read as `schema` and dedup into one field while
						# JCS would publish two. Decoding escapes here would mean
						# reimplementing them; refusing says so instead.
						if (escaped) print "D\tescaped-key\t" tok
						# A `.` in a member NAME is indistinguishable from the path
						# separator once paths are flattened, so a top-level
						# `"save_schema.min"` collapses onto the nested one and dedups
						# away, leaving an undeclared field unchecked.
						if (index(tok, ".") > 0) print "D\tdotted-key\t" tok
						# An EMPTY member name is valid JSON and JCS publishes it, but it
						# is also the value this scanner uses to mean "no key pending",
						# so it would never be emitted at all.
						if (tok == "") print "D\tempty-key\t(empty)"
						# A RAW delimiter, as opposed to the escape handled above. The
						# rows this parser emits are tab-separated, so a literal tab in a
						# member name splits the row into extra columns and the name is
						# read as something else entirely.
						if (index(tok, "\t") > 0) print "D\traw-delimiter-key\t(tab)"
						pending = tok
					}
				} else if (c == SQ) {
					# SQ is the apostrophe, built from its code point because this awk
					# program lives inside a single-quoted shell string — writing the
					# character here would end that string.
					#
					# GDScript accepts single-quoted strings, so a member named that way
					# is valid and this scanner would not see it at all. Reached only
					# OUTSIDE a double-quoted token and outside a comment, both of which
					# are consumed before this branch.
					print "D\tsingle-quoted\t" substr(line, i, 24)
					exit
				} else if (c == "(") {
					# The value is a CALL, so any `[`/`{` after this belongs to its
					# arguments, not to the key. Without this, `build_targets([])`
					# would classify the call result as a literal collection the
					# parser can read — and it cannot read what the helper returns.
					if (pending != "") { emit(pending, "V"); pending = "" }
					# A parenthesised expression can also BE the key — `("x"): 1`, with
					# or without a leading identifier. Checked here rather than only
					# after an identifier, so the bare form is covered too.
					d3 = 0; bal = 0
					for (q = i; q <= n; q++) {
						cq = substr(line, q, 1)
						if (cq == "(") d3++
						else if (cq == ")") { d3--; if (d3 == 0) { bal = 1; break } }
					}
					if (!bal) print "D\tkey-expression\t(unterminated)"
					else if (substr(line, q + 1) ~ /^[[:space:]]*:/) print "D\tkey-expression\t" substr(line, i, (q - i) + 1)
				} else if (c == "{" || c == "[") {
					if (pending != "") { emit(pending, "C"); push(pending, nout - 1); pending = "" }
					else push("", -1)
					depth++
				} else if (c == "}" || c == "]") {
					if (pending != "") { emit(pending, "V"); pending = "" }
					depth--
					# A literal only classifies the value when it IS the whole value.
					# `[] if false else TARGETS` opens with one, and the runtime branch
					# can return populated targets whose fields never appear here — so
					# anything other than a separator after the closer downgrades the
					# key to unreadable.
					tail = substr(line, i + 1)
					sub(/^[[:space:]]+/, "", tail)
					# A collection followed by `:` was used AS A KEY — `["x"][0]: 1`,
					# whose brackets are otherwise just anonymous frames and produce no
					# diagnostic at all.
					if (tail ~ /^:/) print "D\tkey-expression\t(collection)"
					# The downgrade alone is not enough, so a diagnostic is emitted
					# beside it. `demote()` rewrites the kind of the OWNER row to `V`,
					# and that kind is read in exactly one place: the opaque-block check,
					# which only ever looks at entries the deferred ledger covers. A
					# composed block that no ledger row mentions — `"save_schema":
					# {...} if flag else OTHER` — therefore keeps every child path the
					# literal already emitted, and those children are then checked
					# against the shape reference as though they were the published
					# fields, while the build publishes whatever the expression
					# evaluates to. The diagnostic makes the case fail closed wherever
					# it appears, which is the same treatment `root-expression` gets
					# one branch below for the depth-zero form of the identical defect.
					# It also covers the frames `demote()` cannot reach at all: an
					# anonymous frame carries owner -1, so the downgrade is silently
					# dropped there even when a row would have read it.
					if (tail != "" && tail !~ /^[,}\]:]/ && tail !~ /^#/) {
						demote()
						print "D\tpartial-collection\t" substr(tail, 1, 24)
					}
					pop()
					if (depth == 0) {
						# The ROOT literal can be the first operand of an expression too —
						# `} if false else {...}` — and at depth zero there is no owner row
						# left to demote, so the scan would simply stop and validate a
						# dictionary the build never publishes.
						if (tail != "" && tail !~ /^[,}\]]/ && tail !~ /^#/) print "D\troot-expression\t" substr(tail, 1, 24)
						started = 2; exit
					}
				} else if (c == ",") {
					if (pending != "") { emit(pending, "V"); pending = "" }
				} else if (c ~ /[A-Za-z_]/) {
					# An identifier. Harmless as a VALUE (`SCHEMA`, `int(...)`), but as
					# a KEY it names a field this parser cannot resolve — GDScript
					# allows `SOME_CONST: 1`, and that field would ship completely
					# invisible to every check here. Fail closed on it rather than
					# report agreement about a shape we could not read.
					word = ""; k = i
					while (k <= n && substr(line, k, 1) ~ /[A-Za-z0-9_]/) { word = word substr(line, k, 1); k++ }
					rest = substr(line, k)
					if (rest ~ /^[[:space:]]*:/) print "D\tnonliteral-key\t" word
					# An identifier in VALUE position means the value did not begin with
					# a literal collection, so a `[`/`{` appearing later belongs to an
					# expression — `TARGETS + []`. Settle the key as unreadable HERE, or
					# that later bracket would classify the whole expression as a literal
					# this parser can read.
					else if (pending != "") { emit(pending, "V"); pending = "" }
					# A CALL used as a key — `StringName("x"): 1`. The identifier is
					# followed by `(` rather than `:`, and the quoted token inside is
					# followed by `)`, so neither branch sees a key while JCS publishes
					# whatever the call returns.
					else if (rest ~ /^\(/) {
						d2 = 0; balanced = 0
						for (q = k; q <= n; q++) {
							cq = substr(line, q, 1)
							if (cq == "(") d2++
							else if (cq == ")") { d2--; if (d2 == 0) { balanced = 1; break } }
						}
						# Unbalanced on this line means the expression continues onto the
						# next — `StringName(` … `): 1`. The scan is line-oriented, so it
						# cannot tell whether a key follows; refuse rather than skip.
						if (!balanced) print "D\tkey-expression\t" word "(unterminated)"
						else if (substr(line, q + 1) ~ /^[[:space:]]*:/) print "D\tkey-expression\t" word
					}
					i = k - 1
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
		# Frames remember which output row is their own key, so a collection that
		# turns out not to be the whole value can downgrade that row on close.
		function push(name, mark) { stack[np] = name; owner[np] = mark; np++ }
		function pop() { if (np > 0) np-- }
		function demote() { if (np > 0 && owner[np - 1] >= 0) kindout[owner[np - 1]] = "V" }
		function emit(key, kind,   p, k) {
			p = ""
			for (k = 0; k < np; k++) if (stack[k] != "") p = p stack[k] "."
			pathout[nout] = p key
			kindout[nout] = kind
			nout++
		}
		END {
			for (k = 0; k < nout; k++) print "P\t" pathout[k] "\t" kindout[k]
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

# Member names in the reference that the flattening cannot represent. A name
# containing the separator collapses onto a nested path — a top-level
# `save_schema.min` becomes the documented nested one and dedups away, so the
# reference could promise a field that is neither emitted nor ledgered and the
# reverse-direction check would never see it. An empty name vanishes entirely.
#
# A RECORD DELIMITER is the same problem one level down: paths travel between
# these checks as lines in a file, so a name carrying a newline splits into two
# rows and can match two unrelated existing paths — `"key\nsignature"` becomes
# the deferred `key` and `signature` and disappears.
reference_unrepresentable_keys() {
	local source="$1"
	jq -er '
		[paths | map(select(type == "string")) | .[]]
		| unique | .[]
		| select(
			length == 0
			or (index(".") != null)
			# Codepoints, not a regex class: NUL cannot be written into a jq regex,
			# and an escape misread as literal characters would match ordinary names.
			# 0 NUL, 9 tab, 10 newline, 13 carriage return.
			or (explode | any(. == 0 or . == 9 or . == 10 or . == 13))
		)
	' "$source" 2>/dev/null || true
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

	# The literal must be RETURNED DIRECTLY. Bound to a local first, it can be
	# mutated before it is returned — `built["manifest"]["x"] = 1` — and this scan
	# would still see only the original literal and report agreement. The emitter
	# test cannot catch that either: a builder-side addition changes the canonical
	# bytes it compares against, so both sides move together and it passes.
	local opener
	opener="$(awk '
		/"manifest"[[:space:]]*:[[:space:]]*\{[[:space:]]*$/ { print last; exit }
		/\{[[:space:]]*$/ { last = $0 }
	' "$MANIFEST_SOURCE")"
	# Matched as a STATEMENT, not a substring: `var returned_manifest := {`
	# contains "return" and is exactly the construct this refuses.
	if ! printf '%s' "$opener" | grep -qE '^[[:space:]]*return[[:space:]]*\{[[:space:]]*$'; then
		fail "the manifest literal in $MANIFEST_SOURCE is not returned directly — it opens under '$(printf '%s' "$opener" | sed 's/^[[:space:]]*//')'. A literal bound to a local can be mutated before it is returned, and neither this guard nor the emitter's canonical-form test would see the addition. Return the literal directly."
	fi

	# Every OTHER `"manifest":` in the file must carry an empty dictionary. The
	# scan reads one literal; an additional success branch returning a populated
	# manifest inline — the same shape `build()` already uses for its refusals —
	# would publish fields this guard never looks at.
	#
	# Stated as a WHITELIST over every dictionary-returning statement rather than
	# a search for other `"manifest"` keys. A blacklist has to anticipate each
	# spelling the key could take — single quotes, `StringName("manifest")`, any
	# other expression — and each one missed is a branch publishing an unchecked
	# manifest. A return is acceptable only if it is the scanned literal itself or
	# the exact empty-manifest refusal shape; anything else refuses by line.
	local unexpected_returns
	unexpected_returns="$(grep -nE '^[[:space:]]*return[[:space:]]*[({]' "$MANIFEST_SOURCE" |
		grep -vE '^[0-9]+:[[:space:]]*return[[:space:]]*\{[[:space:]]*$' |
		grep -vE '^[0-9]+:[[:space:]]*return[[:space:]]*\{"manifest":[[:space:]]*\{\},[[:space:]]*"error":' || true)"
	if [ -n "$unexpected_returns" ]; then
		fail "$MANIFEST_SOURCE returns a dictionary this guard does not read, at line(s) $(printf '%s' "$unexpected_returns" | cut -d: -f1 | tr '\n' ' '). Only the multi-line literal is scanned, so any other branch returning a populated manifest would publish fields unchecked. A return must be either that literal or the empty-manifest refusal form \`return {\"manifest\": {}, \"error\": …}\`."
	fi

	# …and exactly ONE of those returns may be the multi-line form. The exemption
	# above admits any `return {` at end of line, which would whitelist a SECOND
	# multi-line dictionary — one keyed by an expression, carrying a populated
	# manifest, and never visited by the scan because it has no literal anchor.
	local multiline_returns
	multiline_returns="$(grep -cE '^[[:space:]]*return[[:space:]]*\{[[:space:]]*$' "$MANIFEST_SOURCE" || true)"
	[ "$multiline_returns" -eq 1 ] ||
		fail "$MANIFEST_SOURCE has $multiline_returns multi-line dictionary returns; exactly one is readable here. A second would be exempted from the refusal-shape check above while the scan never visits it, so it could carry a populated manifest unchecked."

	SCRATCH_DIR="$(mktemp -d)"
	trap cleanup EXIT

	# Rows are TYPED — `D` for a parser diagnostic, `P` for a field path — rather
	# than distinguished by a reserved prefix on the path itself. A field legitimately
	# named `"!x"` would otherwise be indistinguishable from a diagnostic and get
	# filtered away as one.
	emitted_paths "$MANIFEST_SOURCE" >"$SCRATCH_DIR/raw-kinds"
	diagnosed() { awk -F '\t' -v want="$1" '$1 == "D" && $2 == want { printf "%s ", $3 }' "$SCRATCH_DIR/raw-kinds"; }

	local computed escaped_keys dotted empty_key key_expr
	computed="$(diagnosed nonliteral-key)"
	[ -z "$computed" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE keys a field on the identifier(s) ${computed}rather than a quoted name. This guard cannot resolve what field that publishes, so it would ship unchecked against $SHAPE_REFERENCE. Use a quoted key."
	key_expr="$(diagnosed key-expression)"
	[ -z "$key_expr" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE keys a field on the call(s) ${key_expr}(...). Only a direct quoted literal is readable here, so whatever the call returns would be published unchecked against $SHAPE_REFERENCE. Use a quoted key."
	escaped_keys="$(diagnosed escaped-key)"
	[ -z "$escaped_keys" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE names a field with an escape sequence (read here as ${escaped_keys}with the escape dropped). Two keys differing only by an escape would collapse into one here while the published JSON carries both, so the extra field would never be checked against $SHAPE_REFERENCE. Use a key with no escapes."
	dotted="$(diagnosed dotted-key)"
	[ -z "$dotted" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE names the field(s) ${dotted}with a '.' in the member name. Paths are compared flattened, so such a name is indistinguishable from a nested path and would collapse onto it — leaving an undeclared field unchecked against $SHAPE_REFERENCE. Use a name without a dot."
	empty_key="$(diagnosed empty-key)"
	[ -z "$empty_key" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE names a field with an EMPTY member name. It is publishable, but it is also the value this scanner uses to mean 'no key pending', so the field would never be emitted or checked. Give it a name."
	[ -z "$(diagnosed raw-delimiter-key)" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE names a field containing a RAW tab. The rows this guard emits are tab-separated, so such a name splits into extra columns and is read as a different field entirely. Use a name without one."
	[ -z "$(diagnosed root-expression)" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE is only the first operand of a larger expression. The scan validates the literal, but the build would publish whatever the expression evaluates to. Make the literal the whole value."
	[ -z "$(diagnosed single-quoted)" ] ||
		fail "the manifest literal in $MANIFEST_SOURCE contains a single-quoted string. GDScript accepts them as member names, and this guard reads only double-quoted keys, so such a field would ship entirely unseen. Use double quotes."
	[ -z "$(diagnosed unterminated-string)" ] ||
		fail "a quoted value in the manifest literal of $MANIFEST_SOURCE does not close on its own line. This guard reads the literal line by line, so it cannot tell where such a value ends — everything after it would be scanned as structure and attributed to the wrong field. Keep manifest values on one line."

	awk -F '\t' '$1 == "P" { print $2 "\t" $3 }' "$SCRATCH_DIR/raw-kinds" >"$SCRATCH_DIR/emitted-kinds"
	cut -f1 <"$SCRATCH_DIR/emitted-kinds" | LC_ALL=C sort -u >"$SCRATCH_DIR/emitted"

	local bad_ref_keys
	bad_ref_keys="$(reference_unrepresentable_keys "$SHAPE_REFERENCE" | tr '\n' ' ')"
	if [ -n "${bad_ref_keys// /}" ]; then
		fail "$SHAPE_REFERENCE declares the member name(s) ${bad_ref_keys}which this comparison cannot represent — a name carrying the path separator collapses onto the nested path of the same spelling, and an empty name disappears. The reference could then promise a field that is never checked. Rename it."
	fi
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

	# An EMPTY ledger is a valid end state, not a failure: it means every
	# documented field has graduated into publication, which is exactly what
	# removing the last row is supposed to achieve. A field that is withheld
	# without a row is caught below, by name, so nothing is lost by allowing it.
	ledger_paths "$DEFERRED_LEDGER" >"$SCRATCH_DIR/ledger"

	# Every reference field that is not emitted has to be covered by a ledger
	# entry: the entry itself, or an ancestor of it.
	local unaccounted='' covered_any="$SCRATCH_DIR/covered"
	: >"$covered_any"
	local path entry matched
	while IFS= read -r path; do
		if grep -qxF -- "$path" "$SCRATCH_DIR/emitted"; then
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

	# A row may only excuse a block this parser can still READ. That is the first
	# of the two ways a row stops being trustworthy, and they are complementary:
	# here the block is fed by an EXPRESSION — `rollback_targets: build_targets()`
	# — so it emits no descendants at all and the check below has nothing to catch,
	# while the row goes on excusing every documented one. The second way, a block
	# that is a literal but has started PUBLISHING those fields, is caught below.
	local opaque='' entry_kind
	while IFS= read -r entry; do
		grep -qxF -- "$entry" "$SCRATCH_DIR/emitted" || continue
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

	# The same defect as the two checks above, for a block NO ledger row mentions.
	# Both of those read the kind that `demote()` writes, and both consult it only
	# for ledger-covered entries — so `"save_schema": {...} if flag else OTHER`
	# passes them untouched while every child path the literal emitted is still
	# compared against the shape reference, reporting agreement about fields the
	# build never publishes. It is the depth-above-zero twin of `root-expression`.
	#
	# 🔴 DELIBERATELY LAST, AND THE ORDER IS THE POINT.
	#
	# This diagnostic fires on every composed closer, including the ones the two
	# checks above diagnose far more precisely — a covered block built by a call,
	# or opening with a literal. Raised in the diagnostics phase it would preempt
	# them and answer "make the collection the whole value" where the actual
	# problem is a ledger row excusing a block that stopped being readable. Running
	# it here leaves every specific message in front of it and catches exactly the
	# uncovered remainder that nothing else sees.
	[ -z "$(diagnosed partial-collection)" ] ||
		fail "a nested collection in the manifest literal of $MANIFEST_SOURCE is only the first operand of a larger expression. Its element fields are read from the literal while the build publishes whatever that expression evaluates to, so checking them against $SHAPE_REFERENCE proves nothing about what ships. Make the collection the whole value."

	# A ledger entry that explains nothing is stale: the field graduated or was
	# renamed, and the row outlived it.
	local dead=''
	while IFS= read -r entry; do
		grep -qxF -- "$entry" "$covered_any" || dead="$dead $entry"
	done <"$SCRATCH_DIR/ledger"
	if [ -n "$dead" ]; then
		fail "$DEFERRED_LEDGER explains$dead, which $SHAPE_REFERENCE no longer declares as unpublished. Drop the stale row."
	fi

	printf 'update-manifest shape guard: PASS — %s published fields are all declared by the shape reference, and its %s withheld fields each carry a reason\n' \
		"$(wc -l <"$SCRATCH_DIR/emitted" | tr -d ' ')" \
		"$(wc -l <"$SCRATCH_DIR/ledger" | tr -d ' ')"
}

main "$@"
