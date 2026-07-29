#!/usr/bin/env bash
# Proves tools/preview-flags.sh resolves the opt-in capture's flag set, refuses
# every list it cannot trust, and is actually wired into the capture that needs it.
#
# Three layers, kept apart on purpose. The PARSER is driven through fixture lists,
# because that is where a malformed entry has to be caught. The EXPORT is driven
# by sourcing the real output under `set -a` and reading the environment back,
# because the shape the capture depends on is "these variables are set in the
# child process" — not "this text looks right". And the WIRING is asserted against
# ci.yaml, since a resolver that is correct but unwired passes every one of its
# own tests while the capture silently photographs the default path.
#
# The refusals matter more than the acceptance here. A list this script cannot
# trust must stop the capture, because the alternative is a run that exports
# nothing, photographs the DEFAULT surface, prints CAPTURE PASS and publishes
# frames that a reviewer reads as evidence for a treatment they do not show —
# the exact failure the opt-in pass exists to prevent (#528).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/tools/preview-flags.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"

failures=0
SCRATCH_DIR=''

t_fail() {
	printf 'preview flags test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

cleanup() {
	[ -n "$SCRATCH_DIR" ] && rm -rf "$SCRATCH_DIR"
}
trap cleanup EXIT

SCRATCH_DIR="$(mktemp -d)"

# Runs the resolver against a fixture list. Prints stdout; stderr is kept out of
# the way so a refusal's message does not look like test output.
run_flags() {
	local list="$1" mode="$2"
	WAR_PREVIEW_FLAGS_FILE="$list" "$SCRIPT" "$mode" 2>"$SCRATCH_DIR/stderr"
}

# --- Layer 1: the parser accepts a well-formed list --------------------------

cat >"$SCRATCH_DIR/good.txt" <<'EOF'
# a comment

WAR_GROUND_PLATES
   WAR_ASH_DRIFT
EOF

if out="$(run_flags "$SCRATCH_DIR/good.txt" --names)"; then
	expected="$(printf 'WAR_GROUND_PLATES\nWAR_ASH_DRIFT')"
	if [ "$out" != "$expected" ]; then
		t_fail "--names dropped or reordered entries: got [$out]"
	fi
else
	t_fail "a well-formed list was refused: $(cat "$SCRATCH_DIR/stderr")"
fi

if out="$(run_flags "$SCRATCH_DIR/good.txt" --env)"; then
	expected="$(printf 'WAR_GROUND_PLATES=1\nWAR_ASH_DRIFT=1')"
	if [ "$out" != "$expected" ]; then
		t_fail "--env did not emit NAME=1 per flag: got [$out]"
	fi
else
	t_fail "--env refused a well-formed list"
fi

# A list with no trailing newline must not lose its last entry — a truncated set
# is a silent capture of the default path for whatever fell off the end.
printf '# c\nWAR_GROUND_PLATES' >"$SCRATCH_DIR/no-newline.txt"
if out="$(run_flags "$SCRATCH_DIR/no-newline.txt" --names)"; then
	[ "$out" = "WAR_GROUND_PLATES" ] || t_fail "a final line with no trailing newline was dropped: got [$out]"
else
	t_fail "a list with no trailing newline was refused"
fi

# CRLF must not turn every name into WAR_FOO\r and fail for an invisible reason.
printf 'WAR_GROUND_PLATES\r\n' >"$SCRATCH_DIR/crlf.txt"
if out="$(run_flags "$SCRATCH_DIR/crlf.txt" --names)"; then
	[ "$out" = "WAR_GROUND_PLATES" ] || t_fail "a CRLF list was mangled: got [$out]"
else
	t_fail "a CRLF list was refused: $(cat "$SCRATCH_DIR/stderr")"
fi

# --- Layer 2: every untrustworthy list is REFUSED, with no output ------------
#
# Each of these would otherwise reach the capture as "no flags exported".

refuses() {
	local label="$1" list="$2"
	local out status=0
	out="$(run_flags "$list" --env)" || status=$?
	if [ "$status" -eq 0 ]; then
		t_fail "$label was accepted — the capture would photograph the default path"
		return
	fi
	# A refusal must emit NOTHING on stdout: the caller redirects this straight
	# into the file it sources and ships, so a partial set is worse than none.
	if [ -n "$out" ]; then
		t_fail "$label was refused but still printed [$out] — a truncated set would be exported"
	fi
	if [ ! -s "$SCRATCH_DIR/stderr" ]; then
		t_fail "$label was refused with no reason on stderr"
	fi
}

: >"$SCRATCH_DIR/empty.txt"
refuses "an empty list" "$SCRATCH_DIR/empty.txt"

printf '# only comments\n\n' >"$SCRATCH_DIR/comments-only.txt"
refuses "a comments-only list" "$SCRATCH_DIR/comments-only.txt"

refuses "a missing list" "$SCRATCH_DIR/does-not-exist.txt"

printf 'WAR_GROUND_PLATES\nWAR_GROUND_PLATES\n' >"$SCRATCH_DIR/dupe.txt"
refuses "a duplicated flag" "$SCRATCH_DIR/dupe.txt"

# The injection shapes. The caller SOURCES this output under `set -a`, so a name
# that escapes the pattern becomes shell rather than an assignment.
printf 'WAR_GROUND_PLATES=1; touch %s/pwned\n' "$SCRATCH_DIR" >"$SCRATCH_DIR/inject-cmd.txt"
refuses "a name carrying a shell command" "$SCRATCH_DIR/inject-cmd.txt"

# shellcheck disable=SC2016 # the UNEXPANDED $(...) is the payload under test
printf 'WAR_X$(touch %s/pwned)\n' "$SCRATCH_DIR" >"$SCRATCH_DIR/inject-subst.txt"
refuses "a name carrying a command substitution" "$SCRATCH_DIR/inject-subst.txt"

printf 'PATH\n' >"$SCRATCH_DIR/foreign.txt"
refuses "a non-WAR_ variable name" "$SCRATCH_DIR/foreign.txt"

printf 'war_ground_plates\n' >"$SCRATCH_DIR/lowercase.txt"
refuses "a lowercase name" "$SCRATCH_DIR/lowercase.txt"

printf 'WAR_A WAR_B\n' >"$SCRATCH_DIR/two-per-line.txt"
refuses "two names on one line" "$SCRATCH_DIR/two-per-line.txt"

if [ -e "$SCRATCH_DIR/pwned" ]; then
	t_fail "a rejected list still executed its payload — validation runs too late"
fi

# --- Layer 3: the emitted text actually EXPORTS ------------------------------
#
# The capture's contract is that the child godot process sees these variables.
# Asserting the text alone would pass even if `set -a` sourcing did not take.

run_flags "$SCRATCH_DIR/good.txt" --env >"$SCRATCH_DIR/flags.env"
observed="$(
	set -a
	# shellcheck source=/dev/null
	. "$SCRATCH_DIR/flags.env"
	set +a
	printf '%s' "$(env | grep -cE '^WAR_(GROUND_PLATES|ASH_DRIFT)=1$' || true)"
)"
[ "$observed" = "2" ] || t_fail "sourcing the emitted file under 'set -a' exported $observed of 2 flags"

# The control for the line above: the same assertion must FAIL when the flags are
# absent, or it is measuring the ambient environment rather than the sourcing.
observed_control="$(env | grep -cE '^WAR_(GROUND_PLATES|ASH_DRIFT)=1$' || true)"
[ "$observed_control" = "0" ] || t_fail "WAR_ flags were already set in this environment — the export assertion proves nothing"

# --- Layer 4: the SHIPPED list, and the wiring that consumes it --------------

if ! "$SCRIPT" --check 2>"$SCRATCH_DIR/stderr"; then
	t_fail "the shipped tools/preview-flags.txt is not valid: $(cat "$SCRATCH_DIR/stderr")"
fi

# The plate treatment is the reason this pass exists. Losing it from the list
# would leave the capture green while #261 lost its only evidence.
if ! "$SCRIPT" --names | grep -qx 'WAR_GROUND_PLATES'; then
	t_fail "the shipped list no longer contains WAR_GROUND_PLATES — #261 would have no frame evidence"
fi

# Scenario-gated flags must NOT be here: they drive their own captures with their
# own cameras, so forcing them on globally changes those frames instead of adding
# evidence.
for scenario_flag in WAR_LAYERED_OUTFIT_PICKERS WAR_WALK_CYCLE WAR_RUN_CYCLE; do
	if "$SCRIPT" --names | grep -qx "$scenario_flag"; then
		t_fail "$scenario_flag is scenario-gated and must not be in the global preview list"
	fi
done

if [ ! -f "$WORKFLOW" ]; then
	t_fail "ci.yaml not found — the wiring layer proves nothing"
else
	# These three match COMMAND SHAPE, never a bare mention. An earlier draft
	# grepped for the plain path and passed with the step deleted, because this
	# file is also named in a comment two screens above — a guard a comment can
	# satisfy is not a guard. Anchoring on the line shape is what makes deleting
	# the wiring detectable.
	#
	# The capture must OBTAIN its flags from this resolver...
	if ! grep -qE '^[[:space:]]+tools/preview-flags\.sh --env[[:space:]]*>' "$WORKFLOW"; then
		t_fail "no capture step resolves its flags from tools/preview-flags.sh --env — the list is not wired to anything"
	fi
	# ...and the workflow must RUN this test, or the guard above is unenforced.
	if ! grep -qE '^[[:space:]]+run: \./tools/preview-flags\.test\.sh[[:space:]]*$' "$WORKFLOW"; then
		t_fail "ci.yaml has no 'run:' step invoking preview-flags.test.sh — this guard would not fire in CI"
	fi
	# No capture step may hard-code a flag the list owns, or the list is
	# decorative and the two can disagree. Checked over the WHOLE workflow, not
	# just the opt-in step: a copy of the assignment anywhere else is the same
	# drift, and a name-anchored search needs no fragile YAML-indentation regex.
	# Comments are stripped first: prose is allowed to NAME a flag while
	# explaining the mechanism, and only an actual assignment is drift.
	#
	# Into a FILE, never `grep -v … | grep -q …`. Under `pipefail` the downstream
	# `grep -q` exits on its first match, the upstream takes SIGPIPE, and the
	# pipeline reports FAILURE — so the match reads as "no hard-coded flag found"
	# and this guard silently stops firing. ci.yaml carries the same warning
	# about the same shape; this file reproduced the bug before adopting it.
	grep -vE '^[[:space:]]*#' "$WORKFLOW" >"$SCRATCH_DIR/workflow-nocomments" || true
	while IFS= read -r listed_flag; do
		if grep -q "${listed_flag}=1" "$SCRATCH_DIR/workflow-nocomments"; then
			t_fail "ci.yaml hard-codes ${listed_flag}=1 — tools/preview-flags.txt is not the source of truth"
		fi
	done < <("$SCRIPT" --names)
fi

if [ "$failures" -ne 0 ]; then
	printf 'preview flags test: %d failure(s)\n' "$failures" >&2
	exit 1
fi

printf 'preview flags test: OK\n'
