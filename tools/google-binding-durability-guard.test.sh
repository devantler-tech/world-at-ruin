#!/usr/bin/env bash
# Proves every shipped server schema and fixture is anchored to
# the immutable base revision rather than only to files edited in the same PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/google-binding-durability-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"
failures=0

# t_fail records a failed assertion while allowing the remaining cases to run.
t_fail() {
	printf 'Google binding durability guard test: FAIL — %s\n' "$1" >&2
	failures=$((failures + 1))
}

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
data="$repo/server/nakamaauth/testdata"
lease_data="$repo/server/nakamalease/testdata"
character_data="$repo/server/nakamacharacter/testdata"
audit_data="$repo/server/playerstate/testdata"
mkdir -p "$data" "$lease_data" "$character_data" "$audit_data"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false

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
printf '1\n' >"$character_data/shipped_character_versions.txt"
printf '%s\n' '{"schema":1,"recipe":{"version":3,"body_type":"hero"}}' \
	>"$character_data/golden_character_v1.json"
printf '1\n' >"$audit_data/shipped_audit_versions.txt"
printf '%s\n' '{"schema":1,"payload":{"item":"ash-blade"},"outcome":{"count":1}}' \
	>"$audit_data/golden_audit_v1.json"
printf 'world_at_ruin_google_identity_bindings\n' >"$data/shipped_google_binding_collection.txt"
printf 'world_at_ruin_handoff_leases\n' >"$lease_data/shipped_lease_collection.txt"
printf 'world_at_ruin_characters\n' >"$character_data/shipped_character_collection.txt"
printf 'world_at_ruin_player_mutations\n' >"$audit_data/shipped_audit_collection.txt"
git -C "$repo" add server/nakamaauth/testdata server/nakamalease/testdata \
	server/nakamacharacter/testdata server/playerstate/testdata
git -C "$repo" commit -qm 'ship binding schema one'
base="$(git -C "$repo" rev-parse HEAD)"

# reset_tree restores only the temporary fixture repository to its shipped base.
reset_tree() {
	git -C "$repo" reset -q --hard "$base"
	git -C "$repo" clean -qfd
}

# run_guard_from captures the real guard's output and status at a supplied base.
run_guard_from() {
	local anchor="$1" out rc=0
	out="$(cd "$repo" && BASE_SHA="$anchor" bash "$GUARD" 2>&1)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

# run_guard_from_with_strict_comm exposes order-sensitive comparisons through PATH.
run_guard_from_with_strict_comm() {
	local anchor="$1" out rc=0
	out="$(
		cd "$repo" &&
			PATH="$scratch/bin:$PATH" BASE_SHA="$anchor" bash "$GUARD" 2>&1
	)" || rc=$?
	printf '%s' "$out"
	return "$rc"
}

# expect_pass requires the candidate fixture tree to satisfy the real guard.
expect_pass() {
	local label="$1" out rc=0
	out="$(run_guard_from "$base")" || rc=$?
	if [ "$rc" -ne 0 ]; then
		t_fail "$label: expected a pass, got rc=$rc: $out"
	fi
}

# expect_fail_matching requires refusal for the specified reason, not any failure.
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

# A new store must join the gate without a handwritten family allowlist.
# Discovery also uses the base tree: deleting the complete candidate family
# must not erase the historical promise from the input set.
for family in character audit; do
	case "$family" in
	character) family_data="$character_data" ;;
	audit) family_data="$audit_data" ;;
	esac
	reset_tree
	git -C "$repo" rm -qr -- "${family_data#"$repo/"}"
	expect_fail_matching "deleted $family family" "shipped_${family}_versions.txt"
	reset_tree
	printf '2\n' >"$family_data/shipped_${family}_versions.txt"
	rm "$family_data/golden_${family}_v1.json"
	printf '{"schema":2}\n' >"$family_data/golden_${family}_v2.json"
	expect_fail_matching "coordinated $family history removal" "shipped_${family}_versions.txt"
	reset_tree
	printf '{"schema":1}\n' >"$family_data/golden_${family}_v1.json"
	expect_fail_matching "rewritten $family history" "golden_${family}_v1.json"
	reset_tree
	printf '2\n' >>"$family_data/shipped_${family}_versions.txt"
	expect_fail_matching "$family version without a fixture" "golden_${family}_v2.json"
	printf '{"schema":2}\n' >"$family_data/golden_${family}_v2.json"
	expect_pass "additive $family schema"
done

for invalid in '' 'garbage' '1\ninvalid' '1\n1' '1\n3' '01' '0'; do
	reset_tree
	printf '%b\n' "$invalid" >"$audit_data/shipped_audit_versions.txt"
	expect_fail_matching "malformed ledger [$invalid]" 'shipped_audit_versions.txt'
done

reset_tree
new_data="$repo/server/futurestore/testdata"
mkdir -p "$new_data"
printf '1\n' >"$new_data/shipped_progress_versions.txt"
expect_fail_matching 'new family without its first fixture' 'golden_progress_v1.json'
for invalid in 'not-json' '{}' '[]' '[{"schema":1},{"schema":2}]' '{"schema":"1"}' 'null' '{"schema":1} {"schema":1}'; do
	printf '%s\n' "$invalid" >"$new_data/golden_progress_v1.json"
	expect_fail_matching "invalid new fixture [$invalid]" 'golden_progress_v1.json'
done
printf '{"schema":1,"progress":{"quest":7}}\n' >"$new_data/golden_progress_v1.json"
printf 'world_at_ruin_progress\n' >"$new_data/shipped_progress_collection.txt"
expect_pass 'complete new record family'

git -C "$repo" add server/futurestore/testdata
git -C "$repo" commit -qm 'ship a previously unknown family'
future_base="$(git -C "$repo" rev-parse HEAD)"
git -C "$repo" rm -qr -- server/futurestore
future_out="$(run_guard_from "$future_base")" && future_rc=0 || future_rc=$?
if [ "$future_rc" -eq 0 ] || ! printf '%s' "$future_out" | grep -qF 'shipped_progress_versions.txt'; then
	t_fail "base-only discovery lost a future family: $future_out"
fi

reset_tree
# A store that persists records in a Nakama collection cannot stay outside the
# gate by never writing a ledger: persisted families are registered from the
# production code that names the collection, not from ledgers that already exist.
reset_tree
mkdir -p "$repo/server/orphanstore"
printf '%s\n' 'package orphanstore' '' 'const Collection = "world_at_ruin_orphans"' \
	>"$repo/server/orphanstore/store.go"
expect_fail_matching 'persisted family without a ledger' 'registers no schema ledger'
rm "$repo/server/orphanstore/store.go"
printf '%s\n' 'package orphanstore' '' 'const collection = "world_at_ruin_orphans"' \
	>"$repo/server/orphanstore/store_test.go"
expect_pass 'a collection literal in test code alone registers nothing'
printf '%s\n' 'package orphanstore' '' 'const Collection = "world_at_ruin_orphans"' \
	>"$repo/server/orphanstore/store.go"
mkdir -p "$repo/server/orphanstore/testdata"
printf '1\n' >"$repo/server/orphanstore/testdata/shipped_orphan_versions.txt"
printf '{"schema":1,"orphans":[]}\n' >"$repo/server/orphanstore/testdata/golden_orphan_v1.json"
printf 'world_at_ruin_orphans\n' >"$repo/server/orphanstore/testdata/shipped_orphan_collection.txt"
expect_pass 'registered new persisted family'

# The actual collection, not merely the package, determines registration. An
# existing ledger cannot hide a second family, even on the same source line.
printf '%s\n' 'const Second = "world_at_ruin_unregistered"; const Third = "world_at_ruin_unregistered_raw"' \
	>>"$repo/server/orphanstore/store.go"
expect_fail_matching 'second collection in the same source file' 'world_at_ruin_unregistered'
printf '%s\n' 'package orphanstore' 'const Collection = "world_at_ruin_orphans"' \
	>"$repo/server/orphanstore/store.go"
# The fixture contains a Go raw string, not shell command substitution.
# shellcheck disable=SC2016
printf '%s\n' 'package orphanstore' 'const Second = `world_at_ruin_unregistered`' \
	>"$repo/server/orphanstore/second.go"
expect_fail_matching 'raw collection in another file in the same package' 'world_at_ruin_unregistered'
printf '1\n' >"$repo/server/orphanstore/testdata/shipped_second_versions.txt"
printf '{"schema":1,"records":[]}\n' >"$repo/server/orphanstore/testdata/golden_second_v1.json"
printf 'world_at_ruin_unrelated\n' >"$repo/server/orphanstore/testdata/shipped_second_collection.txt"
expect_fail_matching 'an unrelated mapped ledger cannot cover a collection' 'world_at_ruin_unregistered'
printf 'world_at_ruin_unregistered\n' >"$repo/server/orphanstore/testdata/shipped_second_collection.txt"
expect_pass 'two collections with their own complete families'
printf '%s\n' 'const Repeated = "world_at_ruin_orphans"' >>"$repo/server/orphanstore/second.go"
expect_pass 'repeated collection use shares its one family'
# shellcheck disable=SC2016
printf '%s\n' 'const AlsoSecond = `world_at_ruin_unregistered`' >>"$repo/server/orphanstore/store.go"
expect_pass 'both registered collections in one file'
printf 'world_at_ruin_orphans\n' >"$repo/server/orphanstore/testdata/shipped_second_collection.txt"
expect_fail_matching 'two ledgers cannot ambiguously register the same collection' 'registered by multiple schema ledgers'
printf 'world_at_ruin_unregistered\n' >"$repo/server/orphanstore/testdata/shipped_second_collection.txt"
for invalid in '' 'world_at_ruin_orphans\nworld_at_ruin_unregistered' 'world_at_ruin_orphans\n' 'garbage'; do
	printf '%b\n' "$invalid" >"$repo/server/orphanstore/testdata/shipped_orphan_collection.txt"
	expect_fail_matching "malformed collection mapping [$invalid]" 'malformed collection mapping'
done
rm "$repo/server/orphanstore/testdata/shipped_orphan_collection.txt"
expect_fail_matching 'every ledger requires its collection mapping' 'shipped_orphan_collection.txt'
ln -s "$data/shipped_google_binding_collection.txt" "$repo/server/orphanstore/testdata/shipped_orphan_collection.txt"
expect_fail_matching 'collection mappings cannot be symlinks' 'symbolic link'
reset_tree
printf 'world_at_ruin_replacement\n' >"$audit_data/shipped_audit_collection.txt"
expect_fail_matching 'shipped collection identity is immutable' 'collection mapping changed after it shipped'
reset_tree

git -C "$repo" rm -qr -- server
empty_out="$(run_guard_from "$pre_binding_base")" && empty_rc=0 || empty_rc=$?
if [ "$empty_rc" -eq 0 ] || ! printf '%s' "$empty_out" | grep -qF 'no server schema ledgers'; then
	t_fail "empty discovery did not fail closed: $empty_out"
fi

reset_tree
rm "$audit_data/golden_audit_v1.json"
ln -s "$data/golden_google_binding_v1.json" "$audit_data/golden_audit_v1.json"
expect_fail_matching 'symlink cannot replace a shipped fixture' 'golden_audit_v1.json'

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
expect_fail_matching 'removed ledger entry' 'shipped_google_binding_versions.txt'

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
expect_fail_matching 'removed lease ledger entry' 'shipped_lease_versions.txt'

reset_tree
printf '3\n' >>"$lease_data/shipped_lease_versions.txt"
printf '%s\n' '[{"schema":3,"attempt_id":"attempt-1","staging":true}]' \
	>"$lease_data/golden_lease_v3.json"
expect_pass 'additive lease schema and fixture'

reset_tree
printf '%s\n' '[{"schema":2,"attempt_id":"rewritten"}]' \
	>"$lease_data/golden_lease_v2.json"
expect_fail_matching 'rewritten shipped lease fixture' 'historical fixtures are immutable'

reset_tree
rm "$lease_data/golden_lease_v1.json"
expect_fail_matching 'deleted shipped lease fixture' 'golden_lease_v1.json'

reset_tree
baseline_out="$(run_guard_from "$pre_binding_base")" ||
	t_fail "first binding baseline was refused: $baseline_out"
printf '%s' "$baseline_out" | grep -qF '4 schema families' ||
	t_fail "first baseline did not check every complete schema family: $baseline_out"

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
