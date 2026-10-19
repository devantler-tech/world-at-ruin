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
report_root="$(cd "$report_root" && pwd)"
scanner="$repo_root/tools/duplication/node_modules/.bin/jscpd"
gh api repos/devantler-tech/world-at-ruin/issues/276 > "$report_root/cleanup-owner.json"
go build -o "$report_root/guard" tools/duplication-guard/main.go
base_catalog=''
base_report=''
if git cat-file -e "${base_revision}:.duplication-catalog.json" 2>/dev/null; then
  base_catalog="$report_root/base-catalog.json"
  git show "${base_revision}:.duplication-catalog.json" > "$base_catalog"
  # A frozen-reference split is judged against what the same scanner and
  # settings reported for the base tree, never against raw text.
  base_tree="$(mktemp -d)"
  trap 'git -C "$repo_root" worktree remove --force "$base_tree/tree" >/dev/null 2>&1 || true; rm -rf "$base_tree"' EXIT
  git worktree add --quiet --detach "$base_tree/tree" "$base_revision"
  (cd "$base_tree/tree" && "$report_root/guard" scan "$scanner" "$report_root/base-scan" "$repo_root/.jscpd.json")
  base_report="$report_root/base-scan/jscpd-report.json"
fi
"$report_root/guard" scan "$scanner" "$report_root/scan" .jscpd.json
"$report_root/guard" check "$report_root/scan/jscpd-report.json" .duplication-catalog.json \
  "$base_catalog" .jscpd.json "$report_root/cleanup-owner.json" "$base_revision" "$base_report"
