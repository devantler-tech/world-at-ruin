#!/usr/bin/env bash
# Verify every isolated world view before publishing the established full artifact.
set -euo pipefail
[[ $# == 3 ]] || {
  echo 'expected input directory, fresh output directory and source SHA' >&2
  exit 2
}
input=$1 output=$2 sha=$3
[[ $sha =~ ^[0-9a-f]{40}$ && -d $input && ! -L $input && ! -e $output && ! -L $output ]] || {
  echo 'invalid source identity, input or fresh output directory' >&2
  exit 2
}
root=$(cd "$(dirname "$0")/.." && pwd -P)
views=(sunward crossfield shrine bonepale cinderreach cave-chamber cave-walkout cave-mouth)
fail() {
  echo "lavapipe union: $*" >&2
  exit 1
}
[[ $(find "$input" -mindepth 1 -maxdepth 1 | wc -l) -eq ${#views[@]} ]] || fail 'expected exactly eight view artifacts'
for view in "${views[@]}"; do
  cell="$input/lavapipe-volumetric-frames-$sha-$view"
  [[ -d $cell && ! -L $cell ]] || fail "missing regular artifact for $view"
  [[ $(find "$cell" -mindepth 1 -maxdepth 1 | wc -l) -eq 4 ]] || fail "unexpected evidence entries for $view"
  for name in "$view.png" "$view.txt" "capture-conditions-$view.txt" capture-lavapipe.log; do
    [[ -f $cell/$name && ! -L $cell/$name && -s $cell/$name ]] || fail "missing regular $view evidence"
  done
  conditions="$cell/capture-conditions-$view.txt"
  [[ $(grep -Fxc "integration_sha: $sha" "$conditions") -eq 1 &&
  $(grep -c '^integration_sha:' "$conditions") -eq 1 &&
  $(grep -Fxc "vantage: $view" "$conditions") -eq 1 &&
  $(grep -c '^vantage:' "$conditions") -eq 1 ]] || fail "crossed source or view for $view"
  [[ $(grep -Ec '^capture_seconds: [1-9][0-9]{0,3}$' "$conditions") -eq 1 &&
  $(grep -c '^capture_seconds:' "$conditions") -eq 1 ]] || fail "missing capture duration for $view"
  seconds=$(sed -n 's/^capture_seconds: //p' "$conditions")
  [[ $seconds -le 900 ]] || fail "capture exceeded the reviewed view budget for $view"
  [[ $(grep -c '^CAPTURE PASS' "$cell/capture-lavapipe.log") -eq 1 &&
  $(grep -c '^CAPTURE PASS — 1 vantages written to ' "$cell/capture-lavapipe.log") -eq 1 &&
  $(grep -c '^CAPTURED ' "$cell/capture-lavapipe.log") -eq 1 &&
  $(grep -Fc "CAPTURED $view -> " "$cell/capture-lavapipe.log") -eq 1 ]] || fail "incomplete or replayed view $view"
  bash "$root/tools/lavapipe-capture-guard.sh" "$cell/capture-lavapipe.log" "$cell"
done
# No output is created until every source, view and positive/refusal guard passed.
mkdir "$output"
for view in "${views[@]}"; do
  cell="$input/lavapipe-volumetric-frames-$sha-$view"
  cp "$cell/$view.png" "$cell/$view.txt" "$cell/capture-conditions-$view.txt" "$output/"
  cp "$cell/capture-lavapipe.log" "$output/capture-lavapipe-$view.log"
done
printf 'Lavapipe complete union: eight distinct views at %s\n' "$sha"
