#!/usr/bin/env bash
# Shared containment for the two default-off private-server diagnostic fixtures.
set -euo pipefail
if [[ $# != 3 || $3 != --experimental || -z $2 ]]; then
  echo 'usage: smoke-native-private-server.sh <spire|owned-child> <local-image> --experimental' >&2
  exit 2
fi
kind=$1
image=$2
case "$kind" in
spire)
  refusal='SPIRE trial requires explicit opt-in before any state or process'
  proof='SPIRE NATIVE PASS:'
  tests=(TestNativeSPIREAttestedRoles)
  ;;
owned-child)
  refusal='owned child trial requires explicit opt-in before any process'
  proof='OWNED CHILD NATIVE PASS:'
  tests=(TestNativeOwnedChild TestNativeOwnedRetirement TestNativeOwnedCleanupFaults TestNativeExecSeal TestNativeExecSealArchitectureMismatch TestNativeExecSealABIReports TestExecSealFilterTable)
  ;;
*)
  echo 'unknown native diagnostic fixture' >&2
  exit 2
  ;;
esac
state=$(mktemp -d)
trial_id=""
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$trial_id" ]]; then
    if ! docker rm -f "$trial_id" >/dev/null 2>&1; then
      echo 'owned native container retirement failed; preserving diagnostics' >&2
      exit 1
    fi
    if ! remaining=$(docker container ls --all --filter "id=$trial_id" --format '{{.ID}}') || [[ -n "$remaining" ]]; then
      echo 'owned native container absence is unverified; preserving diagnostics' >&2
      exit 1
    fi
  fi
  rm -rf -- "$state"
  exit "$rc"
}
trap cleanup EXIT
if [[ $(docker image inspect --format '{{.Config.User}}' "$image") != 10001:10001 ]]; then
  echo 'native image must use its safe non-root default identity' >&2
  exit 1
fi
if docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --pids-limit 64 --memory 256m \
  "$image" >"$state/default.log" 2>&1; then
  refused=0
else
  refused=$?
fi
if [[ $refused != 2 ]] || ! grep -Fxq "$refusal" "$state/default.log"; then
  echo 'native trial default invocation did not refuse missing opt-in' >&2
  exit 1
fi
trial_id=$(docker create --user 0:0 --network none --read-only --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true --pids-limit 256 --memory 1g --cpus 2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=128m,mode=1777 \
  "$image" -war-experimental -test.v -test.timeout=5m)
docker start -a "$trial_id" | tee "$state/trial.log"
if [[ $(docker inspect --format '{{.State.ExitCode}}' "$trial_id") != 0 ]] ||
  ! grep -q "^$proof" "$state/trial.log" ||
  ! grep -q '^PASS$' "$state/trial.log"; then
  echo 'native acceptance lacks a complete passing verdict' >&2
  exit 1
fi
for required in "${tests[@]}"; do
  if ! grep -q "^--- PASS: $required (" "$state/trial.log"; then
    echo "native acceptance lacks $required" >&2
    exit 1
  fi
done
echo "NATIVE ACCEPTANCE PASS: $kind diagnostic proof and joined cleanup; production authority remains unproven"
