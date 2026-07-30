#!/usr/bin/env bash
# Proves tools/manifest-sequence.sh derives an anti-replay mark that is
# MONOTONIC IN RELEASE ORDER, refuses every version it cannot order, and is
# actually wired into the CD step that publishes it.
#
# THE PROPERTY UNDER TEST IS THE ORDERING, NOT ANY SINGLE VALUE. Asserting that
# 0.1.17 maps to 1000017 would pin an encoding and prove nothing about what the
# mark is for: a client refuses any manifest at or below the highest mark it has
# accepted, so the only thing that has to hold is that a later release always
# yields a strictly greater number. The version list below is therefore walked
# pairwise and each step must increase — an encoding change is free, an ordering
# regression is not.
#
# THE REFUSALS CARRY EQUAL WEIGHT. A version this script cannot order must stop
# the publication, because the alternative is a mark that silently collides or
# inverts and strands every client that recorded the higher one. Each refusal
# case is paired with a positive control in the same list, so a script that
# rejected EVERYTHING — the way a broken regex would — fails here instead of
# looking flawless.
#
# AND THE WIRING IS ASSERTED AGAINST cd.yaml, because a correct derivation that
# CD does not call passes every test above while the workflow goes on sampling a
# clock, which is the exact defect this script was written to remove.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="${ROOT}/tools/manifest-sequence.sh"
failures=0

fail() {
	echo "  FAIL: $*" >&2
	failures=$((failures + 1))
}

# --- ordering: the property the mark exists for ---

# Deliberately crosses every carry boundary a positional encoding can get wrong:
# patch rollover, minor rollover, and a major bump whose minor/patch DECREASE.
# That last pair is the one a naive concatenation gets wrong.
versions=(
	0.0.1
	0.1.0
	0.1.9
	0.1.10
	0.1.17
	0.2.0
	0.9.99
	0.10.0
	1.0.0
	1.0.1
	2.0.0
	10.0.0
)

previous=""
previous_version=""
for version in "${versions[@]}"; do
	if ! current="$("${SCRIPT}" "${version}")"; then
		fail "${version} was refused, so the ordering below it proves nothing"
		continue
	fi
	# Validate before comparing, for the same reason the script itself does: `[` on
	# a non-integer aborts with "integer expression expected", and because that is
	# a condition inside an `if`, `set -e` does not fire — so every ordering
	# assertion below would silently stop comparing while the loop reported
	# nothing. Found by ablating this file: forcing multi-line output produced 11
	# swallowed comparison errors and no ordering failure at all.
	if [[ -z "${current}" || "${current}" == *[!0-9]* ]]; then
		fail "${version} printed '${current}', which is not a bare integer — the ordering comparison cannot run on it"
		previous=""
		previous_version=""
		continue
	fi
	if [ -n "${previous}" ] && [ "${current}" -le "${previous}" ]; then
		fail "${previous_version} -> ${version} did not increase the sequence (${previous} -> ${current}) — a client would refuse the newer release as stale"
	fi
	previous="${current}"
	previous_version="${version}"
done

# --- idempotence: a re-run of the same tag is the same publication ---

first="$("${SCRIPT}" 1.2.3)"
second="$("${SCRIPT}" 1.2.3)"
if [ "${first}" != "${second}" ]; then
	fail "the same version produced ${first} then ${second} — a CD re-run would publish a different mark for one publication"
fi

# --- refusals, each with a control so the matrix cannot pass vacuously ---

# <version> <must_succeed> <what it is>
cases=(
	"1.2.3 yes the-control-a-well-formed-version"
	"0.0.0 yes the-control-the-lowest-well-formed-version"
	"1.2.3-rc.1 no a-prerelease-tag-UpdateManifest-would-refuse-anyway"
	"1.2 no a-two-component-version"
	"1.2.3.4 no a-four-component-version"
	"v1.2.3 no a-version-carrying-its-tag-prefix"
	"01.2.3 no a-leading-zero-that-would-collide-with-1.2.3"
	"1.02.3 no a-leading-zero-in-the-minor"
	"1.2.03 no a-leading-zero-in-the-patch"
	"abc no not-a-version-at-all"
	" no an-empty-version"
	"1.2.1000000 no a-patch-that-reaches-the-positional-base"
	"1.1000000.3 no a-minor-that-reaches-the-positional-base"
	"999999.999999.999999 yes the-control-the-largest-in-range-version"
	# Past the shell's signed-integer range. These are the cases a value
	# comparison could not judge: `[ x -ge y ]` aborts with "integer expression
	# expected", `set -e` does not fire inside an `if`, and the arithmetic then
	# wraps. Measured before the length guard: the first exited 0 with sequence
	# `0` — the lowest possible anti-replay floor, and the one mark nothing can
	# ever supersede.
	"9223372036854775808.0.0 no a-major-past-the-signed-integer-range"
	"1.9223372036854775808.0 no a-minor-past-the-signed-integer-range"
	"1.0.9223372036854775808 no a-patch-past-the-signed-integer-range"
	"99999999999999999999999999.0.0 no a-major-far-past-any-integer-range"
)

for entry in "${cases[@]}"; do
	version="${entry%% *}"
	rest="${entry#* }"
	expect="${rest%% *}"
	label="${rest#* }"
	# An empty version must still be PASSED as an argument, or the script would
	# be refusing on arity instead of on the value under test.
	[ "${version}" = "" ] && version=""

	# stdout and stderr are captured SEPARATELY. Exit status alone would miss the
	# shape this guard exists for: a leaked "integer expression expected" on
	# stderr while the script still exits 0 and prints a wrapped mark. An
	# accepted version must therefore be silent on stderr AND print a bare
	# integer, not merely return 0.
	stderr_file="$(mktemp)"
	if stdout="$("${SCRIPT}" "${version}" 2>"${stderr_file}")"; then
		if [ "${expect}" = "no" ]; then
			fail "${label}: '${version}' was accepted (printed '${stdout}') — CD would publish an unorderable mark"
		elif [ -s "${stderr_file}" ]; then
			fail "${label}: '${version}' succeeded but wrote to stderr: $(tr '\n' ' ' <"${stderr_file}") — a swallowed comparison failure is how a wrapped mark ships"
		# A bash pattern over the WHOLE value, not `grep -Eq '^[0-9]+$'`, which is
		# line-oriented: it matches when ANY line is all digits, so `123\nextra`
		# would satisfy it while CD expects one bare integer.
		elif [[ -z "${stdout}" || "${stdout}" == *[!0-9]* ]]; then
			fail "${label}: '${version}' printed '${stdout}', which is not a bare integer"
		fi
	else
		[ "${expect}" = "yes" ] && fail "${label}: '${version}' was refused — the refusal cases prove nothing if nothing can pass"
	fi
	rm -f "${stderr_file}"
done

# Wrong arity is its own contract (exit 2, a usage error rather than a bad value).
if "${SCRIPT}" >/dev/null 2>&1; then
	fail "no argument at all was accepted"
fi
if "${SCRIPT}" 1.2.3 4.5.6 >/dev/null 2>&1; then
	fail "two arguments were accepted — a caller splitting a version on whitespace would go unnoticed"
fi

# --- wiring: a derivation CD does not call is a derivation that does nothing ---

CD="${ROOT}/.github/workflows/cd.yaml"
# Match the CONCRETE INVOCATION, not the script path. `cd.yaml` also names the
# path in a comment explaining the derivation, so a path-only grep passes on that
# comment alone — it would stay green with the real `SEQUENCE=` assignment
# deleted, which is the one thing this assertion exists to catch.
if ! grep -qE 'SEQUENCE=\$\(\./tools/manifest-sequence\.sh +"\$\{VERSION\}"\)' "${CD}"; then
	fail "cd.yaml does not assign SEQUENCE from tools/manifest-sequence.sh with \${VERSION} — the manifest step is deriving its mark some other way"
fi
if grep -qE 'SEQUENCE=\$\(date' "${CD}"; then
	fail "cd.yaml still samples a clock for the sequence — concurrent releases can invert the mark"
fi

if [ "${failures}" -ne 0 ]; then
	echo "manifest-sequence.test.sh: ${failures} failure(s)" >&2
	exit 1
fi
echo "manifest-sequence.test.sh: PASS"
