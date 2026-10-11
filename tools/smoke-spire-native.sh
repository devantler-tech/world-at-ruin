#!/usr/bin/env bash
# An independent, default-off issuer fixture; no production services or secrets.
set -euo pipefail
if [[ $# != 2 || $2 != --experimental || -z $1 ]]; then
  echo 'usage: smoke-spire-native.sh <local-image> --experimental' >&2
  exit 2
fi
image=$1
state=$(mktemp -d)
trial_id=""
cleanup() {
  local rc=$?
  trap - EXIT
  if [[ -n "$trial_id" ]]; then
    if ! docker rm -f "$trial_id" >/dev/null 2>&1; then
      echo 'owned SPIRE container retirement failed; preserving diagnostics' >&2
      exit 1
    fi
    if docker container inspect "$trial_id" >/dev/null 2>&1; then
      echo 'owned SPIRE container still exists; preserving diagnostics' >&2
      exit 1
    fi
  fi
  rm -rf -- "$state"
  exit "$rc"
}
trap cleanup EXIT
if [[ $(docker image inspect --format '{{.Config.User}}' "$image") != 0:0 ]]; then
  echo 'SPIRE controller image must declare its root credential-switch identity' >&2
  exit 1
fi
if docker run --rm --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --pids-limit 64 --memory 256m \
  "$image" > "$state/default.log" 2>&1; then
  refused=0
else
  refused=$?
fi
if [[ $refused != 2 ]] || ! grep -q '^SPIRE trial requires explicit opt-in before any state or process$' "$state/default.log"; then
  echo 'SPIRE trial default invocation did not refuse missing opt-in' >&2
  exit 1
fi
trial_id=$(docker create --network none --read-only --cap-drop ALL \
  --cap-add SETUID --cap-add SETGID --cap-add KILL \
  --security-opt no-new-privileges:true --pids-limit 256 --memory 1g --cpus 2 \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=128m,mode=1777 \
  "$image" -war-experimental -test.v -test.timeout=5m)
docker start -a "$trial_id" | tee "$state/trial.log"
if [[ $(docker inspect --format '{{.State.ExitCode}}' "$trial_id") != 0 ]] || \
  ! grep -q '^--- PASS: TestNativeSPIREAttestedRoles (' "$state/trial.log" || \
  ! grep -q '^SPIRE NATIVE PASS:' "$state/trial.log" || \
  ! grep -q '^PASS$' "$state/trial.log"; then
  echo 'SPIRE native acceptance lacks a complete passing verdict' >&2
  exit 1
fi
echo 'SPIRE ACCEPTANCE PASS: native attestation, exact role authorization and owned cleanup; original-process authority remains unproven'
