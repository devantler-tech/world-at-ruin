#!/usr/bin/env bash
# Proves every shipped server schema and fixture is anchored to
# the immutable base revision rather than only to files edited in the same PR.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD="$ROOT/tools/google-binding-durability-guard.sh"
WORKFLOW="$ROOT/.github/workflows/ci.yaml"
failures=0

# The standalone helper has no module or dependencies; explicit files keep its
# lexical and I/O regressions on the same Go toolchain as this CI guard suite.
go test "$ROOT/tools/server-collection-literals/main.go" "$ROOT/tools/server-collection-literals/main_test.go"
go test "$ROOT/tools/server-write-sites/main.go" "$ROOT/tools/server-write-sites/main_test.go"

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
printf 'module example.com/historyguard\n\ngo 1.26.6\n' >"$repo/server/go.mod"
: >"$repo/server/persisted-write-sites.txt"

# Provide executable fixture readers to the structural-guard fixture packages.
# The separate reader-contract suite supplies missing, skipped and lossy controls.
add_reader_contract() {
	local family_data="$1" family="$2" package_dir="${1%/testdata}"
	printf 'TestHistoricalReader reader.go Read\n' >"$family_data/shipped_${family}_reader.txt"
	cat >"$package_dir/reader.go" <<'GO'
package fixture
import "encoding/json"
func Read(data []byte) (any, error) {
 var document any
 err := json.Unmarshal(data, &document)
 return document, err
}
GO
	cat >"$package_dir/reader_test.go" <<'GO'
package fixture
import ("encoding/json"; "os"; "path/filepath"; "reflect"; "testing")
func TestHistoricalReader(t *testing.T) {
 paths, err := filepath.Glob("testdata/golden_*_v*.json")
 if err != nil || len(paths) == 0 { t.Fatalf("fixtures: %v", err) }
 for _, path := range paths {
  data, err := os.ReadFile(path)
  if err != nil { t.Fatal(err) }
  got, err := Read(data)
  if err != nil { t.Fatal(err) }
  var want any
  if err := json.Unmarshal(data, &want); err != nil { t.Fatal(err) }
  if !reflect.DeepEqual(got, want) { t.Fatal("lost fixture state") }
 }
}
GO
}
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
add_reader_contract "$data" google_binding
add_reader_contract "$lease_data" lease
add_reader_contract "$character_data" character
add_reader_contract "$audit_data" audit
git -C "$repo" add server/go.mod server/persisted-write-sites.txt server/nakamaauth server/nakamalease \
	server/nakamacharacter server/playerstate
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

# collection_literal_cases bind registration to decoded Go string tokens, while
# comments and larger strings containing collection-looking text remain data.
collection_literal_cases() {
	local literal
	for literal in \
		'"\x77orld_at_ruin_missing"' \
		'"\167orld_at_ruin_missing"' \
		'"\u0077orld_at_ruin_missing"' \
		'"\U00000077orld_at_ruin_missing"' \
		'"world_at_ruin_miss\u0069ng"'; do
		reset_tree
		printf 'package fixture\nconst Collection = %s\n' "$literal" >"$data/../collection.go"
		expect_fail_matching "escaped unregistered collection [$literal]" 'world_at_ruin_missing but registers no schema ledger'
	done

	reset_tree
	cat >"$data/../collection.go" <<'GO'
package fixture
const Hex = "\x77orld_at_ruin_google_identity_bindings"
const Octal = "\167orld_at_ruin_google_identity_bindings"
const Unicode = "\u0077orld_at_ruin_google_identity_bindings"
const UnicodeLong = "\U00000077orld_at_ruin_google_identity_bindings"
const Suffix = "world_at_ruin_google_identity_binding\u0073"
GO
	expect_pass 'escaped registered collections use their decoded mapping'

	reset_tree
	cat >"$data/../collection.go" <<'GO'
package fixture
// "world_at_ruin_missing"
/* `world_at_ruin_missing` */
const Message = "\"world_at_ruin_missing\""
const RawMessage = `documentation: "world_at_ruin_missing"`
const RawEscapes = `world_at_ruin_\x6dissing`
GO
	expect_pass 'comments and quoted collection-looking data register nothing'

	reset_tree
	printf '%s\n' 'package fixture' 'const Collection = "\x77orld_at_ruin_missing"' >"$data/../collection_test.go"
	expect_pass 'escaped collections in test code register nothing'

	reset_tree
	mkdir -p "$repo/server/brokenstore"
	printf '%s\n' 'package brokenstore' 'const Invalid = "\q"' >"$repo/server/brokenstore/store.go"
	expect_fail_matching 'malformed Go literal fails closed' 'could not scan collection literals'
	reset_tree
}

# write_site_cases prove existing collection registrations cannot hide another
# persistence boundary, including one that obtains its collection through imports.
write_site_cases() {
	reset_tree
	printf 'package fixture\nconst Collection = "world_at_ruin_google_identity_bindings"\n' >"$data/../collection.go"
	mkdir -p "$repo/server/newwriter"
	cat >"$repo/server/newwriter/store.go" <<'GO'
package newwriter
import shared "example.com/historyguard/nakamaauth"
var storage struct { StorageWrite func(string) }
func Save() { storage.StorageWrite(shared.Collection) }
GO
	expect_fail_matching 'imported existing collection still registers a new writer' 'unregistered persistence write site: server/newwriter/store.go|Save|StorageWrite|1'
	printf '%s\n' 'server/newwriter/store.go|Save|StorageWrite|1 server/nakamaauth/testdata/shipped_google_binding_versions.txt' >"$repo/server/persisted-write-sites.txt"
	expect_pass 'explicitly registered writer using an imported collection'
	printf '\nfunc Second() { storage.StorageWrite(shared.Collection) }\n' >>"$repo/server/newwriter/store.go"
	expect_fail_matching 'second writer sharing the same collection' 'unregistered persistence write site: server/newwriter/store.go|Second|StorageWrite|1'
	printf '%s\n' 'server/newwriter/store.go|Second|StorageWrite|1 server/nakamaauth/testdata/shipped_google_binding_versions.txt' >>"$repo/server/persisted-write-sites.txt"
	expect_pass 'same schema at two explicitly registered write sites'
	printf '%s\n' 'server/missing.go|Save|StorageWrite|1 server/nakamaauth/testdata/shipped_google_binding_versions.txt' >>"$repo/server/persisted-write-sites.txt"
	expect_fail_matching 'stale site cannot remain in inventory' 'stale persistence write-site registration'
	printf '%s\n' 'server/newwriter/store.go|Save|StorageWrite|1 server/missing/testdata/shipped_missing_versions.txt' >"$repo/server/persisted-write-sites.txt"
	expect_fail_matching 'site must bind a complete registered family' 'registers missing schema ledger'
	printf '%s\n' 'server/newwriter/store.go|Save|StorageWrite|1 server/nakamaauth/testdata/shipped_google_binding_versions.txt' 'server/newwriter/store.go|Save|StorageWrite|1 server/nakamaauth/testdata/shipped_google_binding_versions.txt' >"$repo/server/persisted-write-sites.txt"
	expect_fail_matching 'duplicate manifest sites are invalid' 'malformed or duplicate write-site registrations'
	reset_tree
}

if [ "$#" -gt 0 ] && [ "$1" = --write-sites-only ]; then
	write_site_cases
	[ "$failures" -eq 0 ] || exit 1
	printf 'Server write-site tests: PASS\n'
	exit 0
fi

collection_literal_cases
write_site_cases
if [ "$#" -gt 0 ] && [ "$1" = --collection-literals-only ]; then
	if [ "$failures" -ne 0 ]; then
		printf 'Google collection literal tests: %d failure(s)\n' "$failures" >&2
		exit 1
	fi
	printf 'Google collection literal tests: PASS\n'
	exit 0
fi

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
add_reader_contract "$new_data" progress
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
expect_fail_matching 'registration without a historical reader' 'reader.txt is missing'
add_reader_contract "$repo/server/orphanstore/testdata" orphan
# Existing collection fixtures must share their package with the reader fixture.
sed 's/package fixture/package orphanstore/' "$repo/server/orphanstore/reader.go" >"$scratch/reader.go"
mv "$scratch/reader.go" "$repo/server/orphanstore/reader.go"
sed 's/package fixture/package orphanstore/' "$repo/server/orphanstore/reader_test.go" >"$scratch/reader_test.go"
mv "$scratch/reader_test.go" "$repo/server/orphanstore/reader_test.go"
expect_pass 'registered persisted family with its tested reader'

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
printf 'TestHistoricalReader reader.go Read\n' >"$repo/server/orphanstore/testdata/shipped_second_reader.txt"
expect_pass 'two collections with their own complete families'
printf '%s\n' 'const Repeated = "world_at_ruin_orphans"' >>"$repo/server/orphanstore/second.go"
expect_pass 'repeated collection use shares its one family'
# shellcheck disable=SC2016
printf '%s\n' 'const AlsoSecond = `world_at_ruin_unregistered`' >>"$repo/server/orphanstore/store.go"
expect_pass 'both registered collections in one file'
printf 'world_at_ruin_orphans\n' >"$repo/server/orphanstore/testdata/shipped_second_collection.txt"
# Remove the other collection literals: two independent schemas can legitimately
# use the same physical collection, while retaining their own fixture and reader.
printf '%s\n' 'package orphanstore' 'const Collection = "world_at_ruin_orphans"' >"$repo/server/orphanstore/store.go"
printf '%s\n' 'package orphanstore' >"$repo/server/orphanstore/second.go"
expect_pass 'independent schema families can share a collection'
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
