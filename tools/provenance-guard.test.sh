#!/usr/bin/env bash
# Integration regressions for provenance-guard.sh.
#
# Each case creates a tiny tracked client tree. The guard deliberately works
# from Git's index, so these tests stage every fixture exactly as CI would see
# it rather than relying on untracked working-tree files.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
GUARD="$SCRIPT_DIR/provenance-guard.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/war-provenance-guard.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT

failures=0

new_repo() {
	local name="$1"
	local repo="$TEST_ROOT/$name"
	mkdir -p "$repo/client/assets/pack"
	git -C "$repo" init -q
	git -C "$repo" config user.email "provenance-guard@example.invalid"
	git -C "$repo" config user.name "Provenance Guard Test"
	printf '%s\n' "$repo"
}

index_sha256() {
	local repo="$1"
	local path="$2"
	git -C "$repo" cat-file blob ":$path" | shasum -a 256 | awk '{print $1}'
}

expect_failure() {
	local name="$1"
	local expected="$2"
	local repo="$3"
	local output

	if output=$(cd "$repo" && "$GUARD" 2>&1); then
		printf 'FAIL: %s — guard accepted the fixture\n' "$name" >&2
		failures=$((failures + 1))
		return
	fi
	if ! printf '%s\n' "$output" | grep -Fq -- "$expected"; then
		printf 'FAIL: %s — missing diagnostic %s\n%s\n' "$name" "$expected" "$output" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "$name"
}

expect_success() {
	local name="$1"
	local repo="$2"
	local output

	if ! output=$(cd "$repo" && "$GUARD" 2>&1); then
		printf 'FAIL: %s — guard rejected the fixture\n%s\n' "$name" "$output" >&2
		failures=$((failures + 1))
		return
	fi
	printf 'PASS: %s\n' "$name"
}

repo=$(new_repo unaccounted)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright. Source checksum recorded separately.' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/hero.bin client/assets/pack/PROVENANCE.md
expect_failure \
	"tracked asset needs an exact provenance entry" \
	"client/assets/pack/hero.bin" \
	"$repo"

repo=$(new_repo changed)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
printf 'asset-v2\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
expect_failure \
	"replacement needs its recorded checksum updated" \
	"checksum does not match" \
	"$repo"

repo=$(new_repo accounted)
printf 'asset-v1\n' >"$repo/client/assets/pack/hero.bin"
git -C "$repo" add client/assets/pack/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
expect_success "exact path and checksum are accepted" "$repo"

repo=$(new_repo inherited)
mkdir -p "$repo/client/assets/pack/sub"
printf 'asset-v1\n' >"$repo/client/assets/pack/sub/hero.bin"
git -C "$repo" add client/assets/pack/sub/hero.bin
sha=$(index_sha256 "$repo" client/assets/pack/sub/hero.bin)
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	'' \
	'```text' \
	"$sha  sub/hero.bin" \
	'```' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add client/assets/pack/PROVENANCE.md
expect_success "ancestor record uses a record-relative path" "$repo"

repo=$(new_repo newline)
newline_path='client/assets/pack/hero
copy.bin'
printf 'asset-v1\n' >"$repo/$newline_path"
printf '%s\n' \
	'# Provenance' \
	'' \
	'Source: original work. Licence: owned outright.' \
	>"$repo/client/assets/pack/PROVENANCE.md"
git -C "$repo" add "$newline_path" client/assets/pack/PROVENANCE.md
expect_failure \
	"unrepresentable paths fail closed" \
	"cannot be represented in a provenance manifest" \
	"$repo"

if [ "$failures" -ne 0 ]; then
	printf 'provenance-guard tests: %d failure(s)\n' "$failures" >&2
	exit 1
fi

printf 'provenance-guard tests: PASS\n'
