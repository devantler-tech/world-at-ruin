#!/usr/bin/env bash
# Proves a wire-version move is admitted only as an explicit expansion that
# keeps both old/new deployment orders connected and publishes the server's
# retained range. Contraction remains a separately gated, TTL-bound operation.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/wire-protocol-rollout-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"
failures=0

fail() {
	printf 'wire protocol rollout guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
mkdir -p "$repo/client/scripts" "$repo/server/wire" "$repo/.github/workflows"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t

write_client() {
	local maximum="$1" minimum="${2:-}"
	if [ -n "$minimum" ]; then
		printf 'const LEGACY_VERSION := %s\nconst VERSION := %s\n' "$minimum" "$maximum" \
			>"$repo/client/scripts/wire_codec.gd"
	else
		printf 'const VERSION := %s\n' "$maximum" >"$repo/client/scripts/wire_codec.gd"
	fi
}

write_server() {
	local maximum="$1" minimum="${2:-}"
	if [ -n "$minimum" ]; then
		printf 'const LegacyVersion uint16 = %s\nconst Version uint16 = %s\n' "$minimum" "$maximum" \
			>"$repo/server/wire/wire.go"
	else
		printf 'const Version uint16 = %s\n' "$maximum" >"$repo/server/wire/wire.go"
	fi
}

write_cd_server_range() {
	printf '%s\n' \
		"WAR_MANIFEST_PROTOCOL_MIN=\"\$(awk '\$1 == \"const\" && \$2 == \"LegacyVersion\" { print \$5 }' server/wire/wire.go)\" \\" \
		"WAR_MANIFEST_PROTOCOL_MAX=\"\$(awk '\$1 == \"const\" && \$2 == \"Version\" { print \$5 }' server/wire/wire.go)\" \\" \
		>"$repo/.github/workflows/cd.yaml"
}

write_cd_client_range() {
	printf '%s\n' \
		"WAR_MANIFEST_PROTOCOL_MIN=\"\$(awk '\$2 == \"LEGACY_VERSION\" { print \$4 }' client/scripts/wire_codec.gd)\" \\" \
		"WAR_MANIFEST_PROTOCOL_MAX=\"\$(awk '\$2 == \"VERSION\" { print \$4 }' client/scripts/wire_codec.gd)\" \\" \
		>"$repo/.github/workflows/cd.yaml"
}

write_client 1
write_server 1
printf 'name: base without a protocol publication range\n' >"$repo/.github/workflows/cd.yaml"
git -C "$repo" add -A
git -C "$repo" commit -qm 'v1 baseline'
base="$(git -C "$repo" rev-parse HEAD)"

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

commit_case() {
	git -C "$repo" add -A
	git -C "$repo" commit -qm "$1"
}

run_guard() {
	local out rc=0
	out="$(cd "$repo" && BASE_SHA="$base" bash "$GUARD" 2>&1)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

expect_pass() {
	local label="$1" out rc=0
	out="$(run_guard)" || rc=$?
	if [ "$rc" -ne 0 ]; then
		fail "$label: expected a pass, got rc=$rc: $out"
	fi
}

expect_fail() {
	local label="$1" needle="$2" out rc=0
	out="$(run_guard)" || rc=$?
	if [ "$rc" -eq 0 ]; then
		fail "$label: expected a refusal, but the guard passed"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

# The rollout this change needs: both tiers keep v1 and add v2, and CD obtains
# the publication range from the released server source.
reset_tree
write_client 2 1
write_server 2 1
write_cd_server_range
commit_case 'safe v1 to v2 expansion'
expect_pass 'explicit cross-order-safe expansion'

# No movement remains legal without retroactively requiring the publication
# wiring that this expansion introduces.
reset_tree
expect_pass 'unchanged implicit singleton range'

reset_tree
write_client 2
write_server 2
write_cd_server_range
commit_case 'simultaneous bump without retention'
expect_fail 'new version with no retained endpoint' 'does not declare an explicit retained minimum'

reset_tree
write_client 2 1
write_server 2 1
commit_case 'expansion without CD range'
expect_fail 'expansion with no publication source' 'does not publish the retained range from server/wire/wire.go'

reset_tree
write_client 2 1
write_server 2 1
write_cd_client_range
commit_case 'expansion self-reported by client'
expect_fail 'client-derived publication range' 'does not publish the retained range from server/wire/wire.go'

reset_tree
write_client 2 1
write_server 3 1
write_cd_server_range
commit_case 'tier endpoints diverge'
expect_fail 'mismatched client and server ranges' 'client range 1..2 differs from server range 1..3'

reset_tree
write_client 2 2
write_server 2 2
write_cd_server_range
commit_case 'contract away v1 immediately'
expect_fail 'same-change contraction' 'contracts the protocol minimum from 1 to 2'

# Missing immutable evidence must fail closed.
missing_rc=0
missing_out="$(cd "$repo" && BASE_SHA=0000000000000000000000000000000000000000 bash "$GUARD" 2>&1)" || missing_rc=$?
if [ "$missing_rc" -eq 0 ]; then
	fail 'missing base produced a diagnostic but exited zero'
elif ! printf '%s' "$missing_out" | grep -qF 'is not present in the checkout'; then
	fail "missing base did not produce the fail-closed diagnostic: $missing_out"
fi

# A correct guard and regression that CI never runs protect nothing.
grep -Fq 'tools/wire-protocol-rollout-guard.sh' "$WORKFLOW" ||
	fail 'CI does not run the wire protocol rollout guard'
grep -Fq 'tools/wire-protocol-rollout-guard.test.sh' "$WORKFLOW" ||
	fail 'CI does not run this guard regression'

if [ "$failures" -ne 0 ]; then
	printf 'wire protocol rollout guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'wire protocol rollout guard test: PASS\n'
