#!/usr/bin/env bash
# One complete pinned scan; the PR may shrink, but never refresh, its catalog.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_root"
report_root="${DUPLICATION_REPORT_ROOT:-megalinter-reports/duplication-gate}"
base_revision="${DUPLICATION_BASE_REVISION:-$(git merge-base origin/main HEAD)}"
[[ "$base_revision" =~ ^[0-9a-f]{40}$ ]] || { echo 'invalid duplication base revision' >&2; exit 1; }
git cat-file -e "${base_revision}^{commit}"
mkdir -p "$report_root"
base_catalog=''
if git cat-file -e "${base_revision}:.duplication-catalog.json" 2>/dev/null; then
  base_catalog="$report_root/base-catalog.json"
  git show "${base_revision}:.duplication-catalog.json" > "$base_catalog"
fi
gh api repos/devantler-tech/world-at-ruin/issues/276 > "$report_root/cleanup-owner.json"
go build -o "$report_root/guard" tools/duplication-guard/main.go
"$report_root/guard" scan tools/duplication/node_modules/.bin/jscpd "$report_root/scan" .jscpd.json
"$report_root/guard" check "$report_root/scan/jscpd-report.json" .duplication-catalog.json \
  "$base_catalog" .jscpd.json "$report_root/cleanup-owner.json" "$base_revision"
