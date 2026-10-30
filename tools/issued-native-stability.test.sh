#!/usr/bin/env bash
# Exercise the real measurement driver against independent joined fixture processes.
set -euo pipefail
root=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/bin"
export STABILITY_RECORD="$scratch/record" STABILITY_MODE=complete STABILITY_FAIL_AT=1
image="sha256:$(printf '%064d' 1)"
export STABILITY_IMAGE=$image
export STABILITY_REAL_GIT
STABILITY_REAL_GIT=$(command -v git)
export STABILITY_REAL_TEE
STABILITY_REAL_TEE=$(command -v tee)
cat > "$scratch/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
"$STABILITY_REAL_GIT" "$@"
if [[ $STABILITY_MODE == source-read-failed && $* == *'rev-parse HEAD' ||
  $STABILITY_MODE == untracked-read-failed && $* == *'ls-files --others --exclude-standard' ]]; then exit 1; fi
GIT
cat > "$scratch/bin/tee" <<'TEE'
#!/usr/bin/env bash
set -euo pipefail
"$STABILITY_REAL_TEE" "$@"
if [[ $STABILITY_MODE == tee-read-failed && $(wc -l < "$STABILITY_RECORD" | tr -d ' ') == "$STABILITY_FAIL_AT" ]]; then exit 1; fi
TEE
cat > "$scratch/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == "image inspect --format {{.Id}} {{.Os}} {{.Architecture}} $STABILITY_IMAGE" ]]
if [[ $STABILITY_MODE == wrong-image ]]; then echo 'wrong linux amd64'; exit 0; fi
printf '%s linux amd64\n' "$STABILITY_IMAGE"
[[ $STABILITY_MODE != image-read-failed ]]
DOCKER
cat > "$scratch/wrapper" <<'WRAPPER'
#!/usr/bin/env bash
set -euo pipefail
[[ $# == 3 && $1 == "$STABILITY_IMAGE" && $2 == --experimental && $3 == --spire ]]
index=1
if [[ -f $STABILITY_RECORD ]]; then index=$(( $(wc -l < "$STABILITY_RECORD") + 1 )); fi
printf '%s\n' "$index" >> "$STABILITY_RECORD"
for cut in complete lost-enrollment-ack cancel-enrollment-ack lost-receipt changed-binding lost-custody-ack cancel-custody-ack source-death lost-pins; do
  if [[ $STABILITY_MODE == missing-cut && $index == "$STABILITY_FAIL_AT" && $cut == source-death ]]; then continue; fi
  echo "ISSUED ORIGINAL CUSTODY PASS: cut=$cut credential_prerequisite_joined=true real_process_snapshots=true"
done
verdict='NAKAMA ISSUED SPIRE PASS: real issuance and native private claim; disposable PostgreSQL; separate controller profile'
if [[ $STABILITY_MODE != missing-verdict || $index != "$STABILITY_FAIL_AT" ]]; then echo "$verdict"; fi
if [[ $STABILITY_MODE == duplicate-verdict && $index == "$STABILITY_FAIL_AT" ]]; then echo "$verdict"; fi
if [[ $index == "$STABILITY_FAIL_AT" ]]; then
  case "$STABILITY_MODE" in
    failed-after-verdict|cleanup-failed) exit 1;;
    canceled) kill -TERM "$$";;
    source-drift) printf '\n# changed\n' >> "${BASH_SOURCE[0]}";;
  esac
fi
WRAPPER
chmod +x "$scratch/bin/docker" "$scratch/bin/git" "$scratch/bin/tee"
export PATH="$scratch/bin:$PATH"

prepare() {
  local directory="$scratch/case-$1"
  mkdir -p "$directory/tools"
  cp "$root/tools/issued-native-stability.sh" "$directory/tools/issued-native-stability.sh"
  cp "$scratch/wrapper" "$directory/tools/smoke-nakama-native.sh"
  git -c init.defaultBranch=main init -q --template='' "$directory"
  git -C "$directory" add tools/issued-native-stability.sh tools/smoke-nakama-native.sh
  git -C "$directory" -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm fixture
  fixture=$directory
  source=$("$STABILITY_REAL_GIT" -C "$fixture" rev-parse HEAD)
  : > "$STABILITY_RECORD"
}
invoke() {
  GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 bash "$fixture/tools/issued-native-stability.sh" "$image" "$source" amd64 > "$scratch/output" 2>&1
}
prepare complete
invoke
[[ $(wc -l < "$STABILITY_RECORD" | tr -d ' ') == 10 ]] || { echo 'FAIL: measurement did not execute ten complete trials'; exit 1; }
[[ $(grep -c '^ISSUED STARTUP SAMPLE PASS:' "$scratch/output") == 10 ]]
grep -Fxq "ISSUED STARTUP STABILITY PASS: source=$source architecture=amd64 image=$image run=123 attempt=1 trials=10 cuts_per_trial=9 cleanup=joined" "$scratch/output"

for mode in failed-after-verdict cleanup-failed missing-verdict duplicate-verdict missing-cut canceled source-drift tee-read-failed; do
  for position in 1 9 10; do
    prepare "$mode-$position"
    export STABILITY_MODE=$mode STABILITY_FAIL_AT=$position
    if invoke; then echo "FAIL: measurement accepted $mode at $position"; exit 1; fi
    [[ $(wc -l < "$STABILITY_RECORD" | tr -d ' ') == "$position" ]]
    if grep -q '^ISSUED STARTUP STABILITY PASS:' "$scratch/output"; then echo 'FAIL: incomplete measurement published completion'; exit 1; fi
  done
done
for mode in wrong-image image-read-failed source-read-failed untracked-read-failed; do
  prepare "$mode"
  export STABILITY_MODE=$mode
  if invoke; then echo "FAIL: measurement accepted $mode"; exit 1; fi
  [[ ! -s $STABILITY_RECORD ]]
done
export STABILITY_MODE=complete
prepare invalid-source
source=$(printf '%040d' 2)
if invoke; then echo 'FAIL: measurement accepted another source'; exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
prepare invalid-image
if GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 bash "$fixture/tools/issued-native-stability.sh" mutable-tag "$source" amd64 > "$scratch/output" 2>&1; then exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
prepare wrong-architecture
if GITHUB_RUN_ID=123 GITHUB_RUN_ATTEMPT=1 bash "$fixture/tools/issued-native-stability.sh" "$image" "$source" arm64 > "$scratch/output" 2>&1; then exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
prepare dirty-source
printf '\n# dirty\n' >> "$fixture/tools/smoke-nakama-native.sh"
if invoke; then echo 'FAIL: measurement accepted dirty source'; exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
prepare unknown-source-file
touch "$fixture/untracked"
if invoke; then echo 'FAIL: measurement accepted untracked source'; exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
prepare invalid-run
if GITHUB_RUN_ID=0 GITHUB_RUN_ATTEMPT=1 bash "$fixture/tools/issued-native-stability.sh" "$image" "$source" amd64 > "$scratch/output" 2>&1; then exit 1; fi
[[ ! -s $STABILITY_RECORD ]]
echo 'TEST PASS: ten joined trials required; failed cleanup, partial output, cancellation and identity drift cannot become stability'
