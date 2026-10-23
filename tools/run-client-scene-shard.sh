#!/usr/bin/env bash
# Called through the same owned process-group supervisor as ordinary client
# steps. Nothing publishes a receipt until every scene and cleanup succeeds.
set -euo pipefail
[[ $# == 1 ]] || exit 2
case "$1" in 0 | 1 | 2) shard=$1 ;; *) exit 2 ;; esac
: "${RUNNER_TEMP:?}" "${GITHUB_SHA:?}" "${GITHUB_RUN_ID:?}" "${GITHUB_RUN_ATTEMPT:?}"
state="$RUNNER_TEMP/war-client-scenes-$shard"
[[ $RUNNER_TEMP == /* && $RUNNER_TEMP != / && ${XDG_DATA_HOME:-} == "$state" ]] || {
  echo '::error::scene worker private-state identity is invalid' >&2
  exit 1
}
umask 077
work="$RUNNER_TEMP/client-scene-$shard"
mkdir "$work" # Reused output must fail, not preserve an old completion receipt.
planner="$RUNNER_TEMP/client-scene-plan"
"$planner" list "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$shard" >"$work/scenes"
: >"$work/completed"
while IFS= read -r scene; do
  ./tools/run-client-test.sh "$scene" || exit 1
  printf '%s\n' "$scene" >>"$work/completed"
done <"$work/scenes"
rm -rf -- "$state"
test ! -e "$state"
"$planner" seal "$GITHUB_SHA" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT" "$shard" "$work/completed" >"$work/receipt.json"
