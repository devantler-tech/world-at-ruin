#!/usr/bin/env bash
# Proves shipped Google identity-binding schemas and fixtures are anchored to
# the immutable base revision rather than only to files edited in the same PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/google-binding-durability-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"
failures=0

t_fail() {
	printf 'Google binding durability guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
data="$repo/server/nakamaauth/testdata"
lease_data="$repo/server/nakamalease/testdata"
mkdir -p "$data" "$lease_data"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t

git -C "$repo" commit --allow-empty -qm 'base before bindings'
pre_binding_base="$(git -C "$repo" rev-parse HEAD)"
printf '1\n' >"$data/shipped_google_binding_versions.txt"
printf '%s\n' '{"schema":1,"user_id":"11111111-1111-4111-8111-111111111111"}' \
	>"$data/golden_google_binding_v1.json"
printf '%s\n' '{"schema":1,"collection":"world_at_ruin_google_identity_bindings"}' \
	>"$data/golden_google_identity_address_v1.json"
printf '1\n2\n' >"$lease_data/shipped_lease_versions.txt"
printf '%s\n' '[{"schema":1,"attempt_id":"attempt-1"}]' \
	>"$lease_data/golden_lease_v1.json"
printf '%s\n' '[{"schema":2,"attempt_id":"attempt-1","staging":true}]' \
	>"$lease_data/golden_lease_v2.json"
git -C "$repo" add server/nakamaauth/testdata server/nakamalease/testdata
git -C "$repo" commit -qm 'ship binding schema one'
base="$(git -C "$repo" rev-parse HEAD)"

reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

run_guard_from() {
	local anchor="$1" out rc=0
	out="$(cd "$repo" && BASE_SHA="$anchor" bash "$GUARD" 2>&1)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

run_guard_from_with_strict_comm() {
	local anchor="$1" out rc=0
	out="$(
		cd "$repo" &&
			PATH="$scratch/bin:$PATH" BASE_SHA="$anchor" bash "$GUARD" 2>&1
	)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

expect_pass() {
	local label="$1" out rc=0
	out="$(run_guard_from "$base")" || rc=$?
	if [ "$rc" -ne 0 ]; then
		t_fail "$label: expected a pass, got rc=$rc: $out"
	fi
}

expect_fail_matching() {
	local label="$1" needle="$2" out rc=0
	out="$(run_guard_from "$base")" || rc=$?
	if [ "$rc" -eq 0 ]; then
		t_fail "$label: expected a refusal, but the guard passed"
	elif ! printf '%s' "$out" | grep -qF "$needle"; then
		t_fail "$label: refused for the wrong reason — wanted '$needle', got: $out"
	fi
}

expect_pass 'unchanged shipped schema'

reset_tree
printf '2\n' >>"$data/shipped_google_binding_versions.txt"
printf '%s\n' '{"schema":2,"user_id":"22222222-2222-4222-8222-222222222222"}' \
	>"$data/golden_google_binding_v2.json"
expect_pass 'additive schema and fixture'

reset_tree
for version in 2 3 4 5 6 7 8 9 10; do
	printf '%s\n' "$version" >>"$data/shipped_google_binding_versions.txt"
	printf '{"schema":%s,"user_id":"22222222-2222-4222-8222-222222222222"}\n' \
		"$version" >"$data/golden_google_binding_v${version}.json"
done
git -C "$repo" add server/nakamaauth/testdata
git -C "$repo" commit -qm 'ship binding schemas through ten'
version_ten_base="$(git -C "$repo" rev-parse HEAD)"
mkdir -p "$scratch/bin"
system_comm="$(command -v comm)"
printf '%s\n' \
	'#!/usr/bin/env bash' \
	'set -euo pipefail' \
	"LC_ALL=C sort -c \"\$2\"" \
	"LC_ALL=C sort -c \"\$3\"" \
	"exec '$system_comm' \"\$@\"" \
	>"$scratch/bin/comm"
chmod +x "$scratch/bin/comm"
version_ten_out="$(run_guard_from_with_strict_comm "$version_ten_base")" ||
	t_fail "unchanged schemas through version 10 were refused: $version_ten_out"

reset_tree
printf '2\n' >"$data/shipped_google_binding_versions.txt"
expect_fail_matching 'removed ledger entry' 'shipped schema version(s) removed'

reset_tree
printf '%s\n' '{"schema":1,"user_id":"22222222-2222-4222-8222-222222222222"}' \
	>"$data/golden_google_binding_v1.json"
expect_fail_matching 'rewritten shipped fixture' 'changed after it shipped'

reset_tree
rm "$data/golden_google_binding_v1.json"
expect_fail_matching 'deleted shipped fixture' 'was deleted'

reset_tree
printf '%s\n' '{"schema":1,"collection":"rewritten_identity_bindings"}' \
	>"$data/golden_google_identity_address_v1.json"
expect_fail_matching 'rewritten identity address contract' 'identity address contract changed'

reset_tree
printf '2\n' >"$lease_data/shipped_lease_versions.txt"
expect_fail_matching 'removed lease ledger entry' 'shipped lease schema version(s) removed'

reset_tree
printf '3\n' >>"$lease_data/shipped_lease_versions.txt"
printf '%s\n' '[{"schema":3,"attempt_id":"attempt-1","staging":true}]' \
	>"$lease_data/golden_lease_v3.json"
expect_pass 'additive lease schema and fixture'

reset_tree
printf '%s\n' '[{"schema":2,"attempt_id":"rewritten"}]' \
	>"$lease_data/golden_lease_v2.json"
expect_fail_matching 'rewritten shipped lease fixture' 'historical lease fixtures are immutable'

reset_tree
rm "$lease_data/golden_lease_v1.json"
expect_fail_matching 'deleted shipped lease fixture' 'shipped lease must remain readable'

reset_tree
baseline_out="$(run_guard_from "$pre_binding_base")" ||
	t_fail "first binding baseline was refused: $baseline_out"
printf '%s' "$baseline_out" | grep -qF 'establishing the base-comparable binding schema ledger' ||
	t_fail "first binding baseline did not report its one-time state: $baseline_out"

missing_base_out="$(
	cd "$repo" &&
		BASE_SHA=0000000000000000000000000000000000000000 bash "$GUARD" 2>&1
)" && missing_base_rc=0 || missing_base_rc=$?
if [ "$missing_base_rc" -eq 0 ] ||
	! printf '%s' "$missing_base_out" | grep -qF 'is not present in the checkout'; then
	t_fail "missing base commit did not fail closed: $missing_base_out"
fi

unset_base_out="$(cd "$repo" && BASE_SHA='' bash "$GUARD" 2>&1)" &&
	unset_base_rc=0 || unset_base_rc=$?
if [ "$unset_base_rc" -eq 0 ] ||
	! printf '%s' "$unset_base_out" | grep -qF 'BASE_SHA is unset'; then
	t_fail "unset base commit did not fail closed: $unset_base_out"
fi

grep -Fq 'tools/google-binding-durability-guard.sh' "$WORKFLOW" ||
	t_fail 'CI does not run the Google binding durability guard'
grep -Fq 'tools/google-binding-durability-guard.test.sh' "$WORKFLOW" ||
	t_fail 'CI does not run this guard test'

if [ "$failures" -ne 0 ]; then
	printf 'Google binding durability guard test: %d failure(s)\n' "$failures" >&2
	exit 1
fi
printf 'Google binding durability guard test: PASS\n'
