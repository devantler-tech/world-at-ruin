#!/usr/bin/env bash
# Measure independent successes, never retry a failed native trial.
set -euo pipefail
if [[ $# != 3 || ! $1 =~ ^sha256:[0-9a-f]{64}$ || ! $2 =~ ^[0-9a-f]{40}$ || ! $3 =~ ^(amd64|arm64)$ ||
  ! ${GITHUB_RUN_ID:-} =~ ^[1-9][0-9]*$ || ! ${GITHUB_RUN_ATTEMPT:-} =~ ^[1-9][0-9]*$ ]]; then
  echo 'issued startup measurement identity refused' >&2
  exit 2
fi
image=$1 source=$2 architecture=$3
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
unchanged_source() {
  local observed untracked
  observed=$(git --no-replace-objects -C "$root" rev-parse HEAD) || return 1
  [[ $observed == "$source" ]] || return 1
  git --no-replace-objects -C "$root" diff --quiet HEAD -- || return 1
  untracked=$(git --no-replace-objects -C "$root" ls-files --others --exclude-standard) || return 1
  [[ -z $untracked ]]
}
if ! unchanged_source; then echo 'issued startup measurement source refused' >&2; exit 1; fi
if ! actual=$(docker image inspect --format '{{.Id}} {{.Os}} {{.Architecture}}' "$image") ||
  [[ $actual != "$image linux $architecture" ]]; then
  echo 'issued startup measurement image observation refused' >&2
  exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
verdict='NAKAMA ISSUED SPIRE PASS: real issuance and native private claim; disposable PostgreSQL; separate controller profile'
for ((index = 1; index <= 10; index++)); do
  if ! unchanged_source; then echo 'issued startup measurement source changed' >&2; exit 1; fi
  printf 'ISSUED STARTUP SAMPLE BEGIN: index=%s source=%s architecture=%s image=%s run=%s attempt=%s\n' \
    "$index" "$source" "$architecture" "$image" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
  # The wrapper's verdict precedes its EXIT cleanup. Only its successful process
  # join proves both the complete suite and verified fixture retirement.
  if ! bash "$root/tools/smoke-nakama-native.sh" "$image" --experimental --spire 2>&1 | tee "$scratch/trial.log"; then
    echo 'issued startup measurement failed; no subsequent trial will run' >&2
    exit 1
  fi
  if [[ $(grep -Fxc "$verdict" "$scratch/trial.log") != 1 ||
    $(grep -c 'ISSUED ORIGINAL CUSTODY PASS: cut=.* credential_prerequisite_joined=true ' "$scratch/trial.log") != 9 ]] ||
    ! unchanged_source; then
    echo 'issued startup measurement complete observation refused' >&2
    exit 1
  fi
  printf 'ISSUED STARTUP SAMPLE PASS: index=%s source=%s architecture=%s image=%s run=%s attempt=%s\n' \
    "$index" "$source" "$architecture" "$image" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
done
printf 'ISSUED STARTUP STABILITY PASS: source=%s architecture=%s image=%s run=%s attempt=%s trials=10 cuts_per_trial=9 cleanup=joined\n' \
  "$source" "$architecture" "$image" "$GITHUB_RUN_ID" "$GITHUB_RUN_ATTEMPT"
