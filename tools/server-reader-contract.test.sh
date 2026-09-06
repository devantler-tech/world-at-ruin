#!/usr/bin/env bash
# Exercise registration against a real Go reader, never a source-text surrogate.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
repo="$scratch/repo"
data="$repo/server/futurestore/testdata"
mkdir -p "$data" "$repo/server/nakamaauth/testdata"
git -C "$repo" init -q -b main
git -C "$repo" config user.email t@example.com
git -C "$repo" config user.name t
git -C "$repo" config commit.gpgsign false
git -C "$repo" commit --allow-empty -qm base
base="$(git -C "$repo" rev-parse HEAD)"
printf 'module example.com/readerfixture\n\ngo 1.26.6\n' >"$repo/server/go.mod"
printf '1\n' >"$data/shipped_progress_versions.txt"
printf 'world_at_ruin_progress\n' >"$data/shipped_progress_collection.txt"
printf '{"schema":1,"quest":7}\n' >"$data/golden_progress_v1.json"
printf '{}\n' >"$repo/server/nakamaauth/testdata/golden_google_identity_address_v1.json"
cat >"$repo/server/futurestore/store.go" <<'GO'
package futurestore
import "encoding/json"
const Collection = "world_at_ruin_progress"
type Record struct { Schema int `json:"schema"`; Quest int `json:"quest"` }
func Read(data []byte) (Record, error) {
 var record Record
 err := json.Unmarshal(data, &record)
 return record, err
}
GO
cat >"$repo/server/futurestore/store_test.go" <<'GO'
package futurestore
import ("os"; "testing")
func TestHistoricalReader(t *testing.T) {
 data, err := os.ReadFile("testdata/golden_progress_v1.json")
 if err != nil { t.Fatal(err) }
 record, err := Read(data)
 if err != nil { t.Fatal(err) }
 if record.Schema != 1 || record.Quest != 7 { t.Fatalf("lost historical state: %+v", record) }
}
GO
printf 'TestHistoricalReader store.go Read\n' >"$data/shipped_progress_reader.txt"
cp "$repo/server/futurestore/store.go" "$scratch/reader"
cp "$repo/server/futurestore/store_test.go" "$scratch/test"
failures=0
# check compares the real durability guard's exit status with the expected verdict.
check() {
	local expected="$1" label="$2" out rc=0
	out="$(cd "$repo" && BASE_SHA="$base" bash "$ROOT/tools/google-binding-durability-guard.sh" 2>&1)" || rc=$?
	if { [ "$expected" = pass ] && [ "$rc" -ne 0 ]; } ||
		{ [ "$expected" = fail ] && [ "$rc" -eq 0 ]; }; then
		printf 'FAIL: %s (rc=%s): %s\n' "$label" "$rc" "$out"
		failures=$((failures + 1))
	fi
}
check pass 'valid registered production reader'
# A fixture assertion must depend on the production reader's returned state.
cat >"$repo/server/futurestore/store_test.go" <<'GO'
package futurestore
import ("encoding/json"; "os"; "testing")
func TestHistoricalReader(t *testing.T) {
 data, err := os.ReadFile("testdata/golden_progress_v1.json")
 if err != nil { t.Fatal(err) }
 var saved Record
 if err := json.Unmarshal(data, &saved); err != nil { t.Fatal(err) }
 if saved.Schema != 1 || saved.Quest != 7 { t.Fatalf("lost fixture: %+v", saved) }
 _, err = Read([]byte(`{"schema":1,"quest":99}`))
 if err != nil { t.Fatal(err) }
}
GO
check fail 'fixture parsed independently while reader output is ignored'
# Even meaningful assertions about unrelated constant input do not cover the fixture.
sed 's/_, err = Read/record, err := Read/' \
	"$repo/server/futurestore/store_test.go" >"$scratch/unrelated"
sed '/record, err := Read/a\
 if record.Quest != 99 { t.Fatalf("constant read: %+v", record) }
' "$scratch/unrelated" >"$repo/server/futurestore/store_test.go"
check fail 'asserted reader output is unrelated to the historical fixture'
cp "$scratch/test" "$repo/server/futurestore/store_test.go"
printf '1' >"$data/shipped_progress_versions.txt"
check pass 'valid final ledger entry without a newline'
# A missing newline must not drop the final version from the runtime probes.
# shellcheck disable=SC2016
sed 's/os.ReadFile("testdata\/golden_progress_v1.json")/func() ([]byte, error) { return []byte(`{"schema":1,"quest":7}`), nil }()/' "$scratch/test" | sed 's/"os"; //' >"$repo/server/futurestore/store_test.go"
check fail 'unterminated ledger still probes its last fixture'
printf '1\n' >"$data/shipped_progress_versions.txt"
cp "$scratch/test" "$repo/server/futurestore/store_test.go"
rm "$data/shipped_progress_reader.txt"
check fail 'family without reader registration'
printf 'TestHistoricalReader store.go Read\n' >"$data/shipped_progress_reader.txt"
printf 'package futurestore\nimport "testing"\nfunc TestHistoricalReader(t *testing.T) {}\n' >"$repo/server/futurestore/store_test.go"
check fail 'empty test does not exercise a production reader'
printf 'package futurestore\nimport "testing"\nfunc TestHistoricalReader(t *testing.T) { t.Skip("later") }\n' >"$repo/server/futurestore/store_test.go"
check fail 'skipped reader test'
cp "$scratch/test" "$repo/server/futurestore/store_test.go"
printf 'TestMissing store.go Read\n' >"$data/shipped_progress_reader.txt"
check fail 'test name that runs nothing'
printf 'TestHistoricalReader store.go Missing\n' >"$data/shipped_progress_reader.txt"
check fail 'missing production reader'
printf 'TestHistoricalReader store_test.go TestHistoricalReader\n' >"$data/shipped_progress_reader.txt"
check fail 'test code cannot be registered as the production reader'
printf 'TestHistoricalReader store.go Read\n' >"$data/shipped_progress_reader.txt"
sed 's/record.Quest != 7/record.Quest != 99/' "$scratch/test" >"$repo/server/futurestore/store_test.go"
check fail 'reader behavior failure reaches the gate'
cp "$scratch/test" "$repo/server/futurestore/store_test.go"
sed 's/return record, err/record.Quest = 0; return record, err/' "$scratch/reader" >"$repo/server/futurestore/store.go"
check fail 'lossy production reader'
cp "$scratch/reader" "$repo/server/futurestore/store.go"
# The replacement is Go source containing a raw JSON string, not shell expansion.
# shellcheck disable=SC2016
sed 's/os.ReadFile("testdata\/golden_progress_v1.json")/func() ([]byte, error) { return []byte(`{"schema":1,"quest":7}`), nil }()/' "$scratch/test" | sed 's/"os"; //' >"$repo/server/futurestore/store_test.go"
check fail 'reader exercised without consuming its fixture'
cp "$scratch/test" "$repo/server/futurestore/store_test.go"
printf '2\n' >>"$data/shipped_progress_versions.txt"
printf '{"schema":2,"quest":8}\n' >"$data/golden_progress_v2.json"
check fail 'new fixture without a reader check'
cat >"$repo/server/futurestore/store_test.go" <<'GO'
package futurestore
import ("fmt"; "os"; "testing")
func TestHistoricalReader(t *testing.T) {
 for version, quest := range map[int]int{1:7, 2:8} {
  data, err := os.ReadFile(fmt.Sprintf("testdata/golden_progress_v%d.json", version))
  if err != nil { t.Fatal(err) }
  record, err := Read(data)
  if err != nil { t.Fatal(err) }
  if record.Schema != version || record.Quest != quest { t.Fatalf("lost historical state: %+v", record) }
 }
}
GO
check pass 'valid extension keeps both schemas readable'
[ "$failures" -eq 0 ] || exit 1
printf 'Server reader contract: PASS\n'
