#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
for name in workflow trusted candidate; do
  git init -q "$tmp/$name"
  git -C "$tmp/$name" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit -q --allow-empty -m "$name"
done
workflow="$(git -C "$tmp/workflow" rev-parse HEAD)"
trusted="$(git -C "$tmp/trusted" rev-parse HEAD)"
candidate="$(git -C "$tmp/candidate" rev-parse HEAD)"
run() {
  GITHUB_WORKFLOW_SHA="$1" TRUSTED_SHA="$2" CANDIDATE_SHA="$3" \
    bash "$root/tools/verify-trusted-regression-checkouts.sh" "$tmp/workflow" "$tmp/trusted" "$tmp/candidate"
}
run "$workflow" "$trusted" "$candidate"
for input in workflow trusted candidate missing malformed; do
  a="$workflow" b="$trusted" c="$candidate"
  case "$input" in
  workflow) a="$trusted" ;;
  trusted) b="$candidate" ;;
  candidate) c="$workflow" ;;
  missing) c='' ;;
  malformed) b=main ;;
  esac
  if run "$a" "$b" "$c" >"$tmp/log" 2>&1; then
    echo "TEST FAIL -- accepted wrong $input identity" >&2
    exit 1
  fi
done
echo 'TEST PASS -- workflow, base and candidate checkouts match their independent exact identities'
