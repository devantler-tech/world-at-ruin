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
    aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
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
echo 'TEST PASS — real pinned scanner rejects added clones and stale entries; cleanup passes'
