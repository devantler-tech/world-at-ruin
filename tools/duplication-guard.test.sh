#!/usr/bin/env bash
# Behavioral controls through the actual pinned scanner and production checker.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
scanner="$repo_root/tools/duplication/node_modules/.bin/jscpd"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT
go test -race -count=1 "$repo_root/tools/duplication-guard/main.go" "$repo_root/tools/duplication-guard/main_test.go"
go build -o "$tmp_dir/guard" "$repo_root/tools/duplication-guard/main.go"
cp "$repo_root/.jscpd.json" "$tmp_dir/config.json"
printf '{"number":276,"state":"open"}\n' > "$tmp_dir/owner.json"
mkdir "$tmp_dir/source"
cat > "$tmp_dir/source/a.go" <<'GO'
package fixture

func calculate(values []int) int {
  result := 0
  for index, value := range values {
    if value > 10 {
      result += value * index
    } else {
      result -= value + index
    }
  }
  return result
}
GO
cp "$tmp_dir/source/a.go" "$tmp_dir/source/b.go"
cd "$tmp_dir/source"
git init --quiet
git add a.go b.go
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/initial" "$tmp_dir/config.json" > "$tmp_dir/scan.log" 2>&1
"$tmp_dir/guard" generate "$tmp_dir/initial/jscpd-report.json" "$tmp_dir/config.json" "$tmp_dir/catalog.json"
cp "$tmp_dir/catalog.json" "$tmp_dir/base.json"
run_check() {
  "$tmp_dir/guard" check "$1/jscpd-report.json" "$tmp_dir/catalog.json" \
    "$tmp_dir/base.json" "$tmp_dir/config.json" "$tmp_dir/owner.json" \
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa ''
}
run_check "$tmp_dir/initial"
printf 'b.go\n' > .gitignore
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/ignored" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
# An ignore edit must not look like successful cleanup of a tracked source file.
run_check "$tmp_dir/ignored"
rm .gitignore
printf 'b.go\n' > .ignore
printf 'b.go\n' > .git/info/exclude
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/other-ignored" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
run_check "$tmp_dir/other-ignored"
rm .ignore
printf '// %s%s\n' 'jscpd:' 'ignore-start' > a.go
if "$tmp_dir/guard" scan "$scanner" "$tmp_dir/suppressed" "$tmp_dir/config.json" > "$tmp_dir/suppressed.log" 2>&1; then
  echo 'TEST FAIL — inline suppression passed' >&2; exit 1
fi
grep -q 'inline duplication suppression' "$tmp_dir/suppressed.log"
cp b.go a.go
cp a.go c.go
git add c.go
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/added" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
if run_check "$tmp_dir/added" > "$tmp_dir/added.log" 2>&1; then
  echo 'TEST FAIL — actual new duplicate passed' >&2; exit 1
fi
grep -q 'unaccepted clone:.*\.go:.*and .*\.go:' "$tmp_dir/added.log"
rm b.go c.go
git rm --cached --quiet b.go c.go
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/removed" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
if run_check "$tmp_dir/removed" > "$tmp_dir/removed.log" 2>&1; then
  echo 'TEST FAIL — actual removed clone left a stale entry' >&2; exit 1
fi
grep -q 'stale catalog' "$tmp_dir/removed.log"
"$tmp_dir/guard" generate "$tmp_dir/removed/jscpd-report.json" "$tmp_dir/config.json" "$tmp_dir/catalog.json"
run_check "$tmp_dir/removed"
if "$tmp_dir/guard" scan "$scanner" "$tmp_dir/removed" "$tmp_dir/config.json" > "$tmp_dir/stale.log" 2>&1; then
  echo 'TEST FAIL — old producer report reused' >&2; exit 1
fi
grep -q 'fresh report directory' "$tmp_dir/stale.log"
# A frozen-reference split through the real scanner: an edit inside the live
# copy passes only against the base scan, and new copying still fails.
frozen_body() {
  for i in $(seq "$1" "$2"); do printf '  value%d := input*%d + %d\n' "$i" "$i" "$((i * 7))"; done
}
mkdir -p "$tmp_dir/frozen/client/scripts" "$tmp_dir/frozen/client/tests/historical"
cd "$tmp_dir/frozen"
{ printf 'package fixture\n\nfunc calculate(input int) int {\n'; frozen_body 1 30; printf '  return value30\n}\n'; } > client/scripts/live.go
{ cat client/scripts/live.go; printf '\nfunc extra(input int) int {\n'; frozen_body 31 50; printf '  return value50\n}\n'; } > client/tests/historical/frozen.go
git init --quiet
git add client
git -c commit.gpgsign=false -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -m base
revision="$(git rev-parse HEAD)"
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/frozen-base" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
"$tmp_dir/guard" generate "$tmp_dir/frozen-base/jscpd-report.json" "$tmp_dir/config.json" "$tmp_dir/frozen-base-catalog.json"
frozen_check() {
  "$tmp_dir/guard" check "$1/jscpd-report.json" "$tmp_dir/frozen-catalog.json" \
    "$tmp_dir/frozen-base-catalog.json" "$tmp_dir/config.json" "$tmp_dir/owner.json" "$revision" "$2"
}
frozen_scan() {
  "$tmp_dir/guard" scan "$scanner" "$tmp_dir/$1" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
  cp "$tmp_dir/frozen-base-catalog.json" "$tmp_dir/frozen-catalog.json"
  "$tmp_dir/guard" generate "$tmp_dir/$1/jscpd-report.json" "$tmp_dir/config.json" "$tmp_dir/frozen-catalog.json"
}
base_scan="$tmp_dir/frozen-base/jscpd-report.json"
perl -pi -e 's/^(  value15 := .*)\n/$1\n  inserted := input - 1\n/' client/scripts/live.go
grep -q '^  inserted := input - 1$' client/scripts/live.go
frozen_scan frozen-split
[[ "$(jq '.duplicates | length' "$tmp_dir/frozen-split/jscpd-report.json")" -gt "$(jq '.duplicates | length' "$base_scan")" ]] || {
  echo 'TEST FAIL — the fixture edit did not split the frozen-reference clone' >&2; exit 1
}
frozen_check "$tmp_dir/frozen-split" "$base_scan"
# Once merged, the split leaves no catalog entry for the pair; a later edit
# inside one fragment must still pass against the new base's scan.
cp client/scripts/live.go "$tmp_dir/split-live.go"
git -c commit.gpgsign=false -c user.name=fixture -c user.email=fixture@example.invalid commit --quiet -am split
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/frozen-split-base" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
cp "$tmp_dir/frozen-catalog.json" "$tmp_dir/frozen-split-catalog.json"
perl -pi -e 's/^(  value8 := .*)\n/$1\n  again := input - 2\n/' client/scripts/live.go
grep -q '^  again := input - 2$' client/scripts/live.go
"$tmp_dir/guard" scan "$scanner" "$tmp_dir/frozen-resplit" "$tmp_dir/config.json" >> "$tmp_dir/scan.log" 2>&1
cp "$tmp_dir/frozen-split-catalog.json" "$tmp_dir/frozen-resplit-catalog.json"
"$tmp_dir/guard" generate "$tmp_dir/frozen-resplit/jscpd-report.json" "$tmp_dir/config.json" "$tmp_dir/frozen-resplit-catalog.json"
if [[ "$(jq -c "[.duplicates[].fragment]" "$tmp_dir/frozen-split-base/jscpd-report.json")" == "$(jq -c "[.duplicates[].fragment]" "$tmp_dir/frozen-resplit/jscpd-report.json")" ]]; then
  echo "TEST FAIL — the second edit did not change the reported fragments" >&2; exit 1
fi
"$tmp_dir/guard" check "$tmp_dir/frozen-resplit/jscpd-report.json" "$tmp_dir/frozen-resplit-catalog.json" \
  "$tmp_dir/frozen-split-catalog.json" "$tmp_dir/config.json" "$tmp_dir/owner.json" \
  "$(git rev-parse HEAD)" "$tmp_dir/frozen-split-base/jscpd-report.json"
cp "$tmp_dir/split-live.go" client/scripts/live.go
if frozen_check "$tmp_dir/frozen-split" '' > "$tmp_dir/frozen-nobase.log" 2>&1; then
  echo 'TEST FAIL — a frozen-reference split passed without the base scan' >&2; exit 1
fi
grep -q 'unaccepted clone' "$tmp_dir/frozen-nobase.log"
# The split's catalog has no entry for the base's unchanged clone.
if frozen_check "$tmp_dir/frozen-base" "$base_scan" > "$tmp_dir/frozen-deleted.log" 2>&1; then
  echo 'TEST FAIL — a hand-deleted frozen-reference entry passed' >&2; exit 1
fi
grep -q 'unaccepted clone' "$tmp_dir/frozen-deleted.log"
# Replacing the shared block with an equally long block copied from a part of
# the reference that was not duplicated at the base keeps the line budget.
cp client/scripts/live.go "$tmp_dir/split-live.go"
{ printf 'package fixture\n\nfunc calculate(input int) int {\n'; frozen_body 31 50; frozen_body 1 10; printf '  return value50\n}\n'; } > client/scripts/live.go
frozen_scan frozen-replaced
if frozen_check "$tmp_dir/frozen-replaced" "$base_scan" > "$tmp_dir/frozen-replaced.log" 2>&1; then
  echo 'TEST FAIL — a block newly copied from an unshared part of a frozen reference passed' >&2; exit 1
fi
grep -q 'unaccepted clone' "$tmp_dir/frozen-replaced.log"
cp "$tmp_dir/split-live.go" client/scripts/live.go
{ printf '\nfunc copied(input int) int {\n'; frozen_body 31 50; printf '  return value50\n}\n'; } >> client/scripts/live.go
frozen_scan frozen-grown
if frozen_check "$tmp_dir/frozen-grown" "$base_scan" > "$tmp_dir/frozen-grown.log" 2>&1; then
  echo 'TEST FAIL — text newly copied from a frozen reference passed' >&2; exit 1
fi
grep -q 'unaccepted clone' "$tmp_dir/frozen-grown.log"
echo 'TEST PASS — real pinned scanner rejects added clones and stale entries; cleanup and frozen-reference splits pass'
