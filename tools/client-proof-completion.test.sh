#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
sha="$(git -C "$root" rev-parse HEAD)"
for kind in ordinary sandbox; do
  state="$tmp/war-client-$kind"
  mkdir -p "$state"
  : > "$state/owned-save"
  env RUNNER_TEMP="$tmp" XDG_DATA_HOME="$state" GITHUB_SHA=wrong GITHUB_OUTPUT="$tmp/output" \
    bash "$root/tools/client-proof-completion.sh" "$kind" >/dev/null 2>&1 && exit 1
  test -f "$state/owned-save" && test ! -e "$tmp/output"
  env RUNNER_TEMP="$tmp" XDG_DATA_HOME="$tmp" GITHUB_SHA="$sha" GITHUB_OUTPUT="$tmp/output" \
    bash "$root/tools/client-proof-completion.sh" "$kind" >/dev/null 2>&1 && exit 1
  test -f "$state/owned-save" && test ! -e "$tmp/output"
  env RUNNER_TEMP="$tmp" XDG_DATA_HOME="$state" GITHUB_SHA="$sha" GITHUB_OUTPUT="$tmp/output" \
    bash "$root/tools/client-proof-completion.sh" "$kind"
  test ! -e "$state"
  grep -Fxq complete=true "$tmp/output"
  grep -Fxq "tested-sha=$sha" "$tmp/output"
  rm "$tmp/output"
done
echo 'TEST PASS -- completion binds actual checkout and removes only its own worker state'
