#!/usr/bin/env bash
# Regressions for script-uid-guard.sh (#1635). Each case builds a tiny index in a
# throwaway repository; the guard reads only the index, so nothing is committed.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
guard="${repo_root}/tools/script-uid-guard.sh"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT
failures=0

new_repo() {
	local repo="${work}/$1"
	mkdir -p "${repo}/client/scripts"
	git -C "${repo}" init -q
	printf 'extends Node\n' >"${repo}/client/scripts/a.gd"
	printf 'uid://a\n' >"${repo}/client/scripts/a.gd.uid"
	printf '%s\n' "${repo}"
}

expect_pass() {
	local name="$1" repo="$2" output
	if ! output="$("${guard}" "${repo}" 2>&1)"; then
		printf 'FAIL: %s — guard refused\n%s\n' "${name}" "${output}" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "${name}"
}

expect_fail() {
	local name="$1" repo="$2" expected="$3" output
	if output="$("${guard}" "${repo}" 2>&1)"; then
		printf 'FAIL: %s — guard accepted\n%s\n' "${name}" "${output}" >&2
		failures=$((failures + 1))
		return
	fi
	if [[ "${output}" != *"${expected}"* ]]; then
		printf 'FAIL: %s — missing diagnostic %s\n%s\n' "${name}" "${expected}" "${output}" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "${name}"
}

repo="$(new_repo paired)"
git -C "${repo}" add client
expect_pass "a script with its tracked .uid is accepted" "${repo}"

repo="$(new_repo untracked_uid)"
git -C "${repo}" add client/scripts/a.gd
expect_fail "a .uid that exists only on disk is refused" "${repo}" "client/scripts/a.gd has no tracked client/scripts/a.gd.uid"

repo="$(new_repo nested)"
mkdir -p "${repo}/client/tests/deep"
printf 'extends Node\n' >"${repo}/client/tests/deep/b.gd"
git -C "${repo}" add client
expect_fail "a script in a nested directory is checked too" "${repo}" "client/tests/deep/b.gd has no tracked"

repo="$(new_repo orphan_uid)"
rm "${repo}/client/scripts/a.gd"
printf 'extends Node\n' >"${repo}/client/scripts/c.gd"
printf 'uid://c\n' >"${repo}/client/scripts/c.gd.uid"
git -C "${repo}" add client
expect_pass "a leftover .uid with no script is not an error" "${repo}"

repo="$(new_repo newline)"
nl_name=$'x\ny'
printf 'extends Node\n' >"${repo}/client/scripts/${nl_name}.gd"
printf 'uid://x\n' >"${repo}/client/scripts/${nl_name}.gd.uid"
git -C "${repo}" add client
expect_fail "a tracked script path with a newline fails closed" "${repo}" "cannot compare it"

repo="${work}/empty"
mkdir -p "${repo}"
git -C "${repo}" init -q
expect_fail "an index with no client scripts fails closed" "${repo}" "examined nothing"

expect_pass "the repository's own index" "${repo_root}"

if [ "${failures}" -ne 0 ]; then
	echo "TEST FAIL — ${failures} script .uid guard case(s) failed"
	exit 1
fi
echo "TEST PASS — the script .uid guard reads the index, checks nested scripts and fails closed"
