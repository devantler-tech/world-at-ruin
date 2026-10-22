#!/usr/bin/env bash
# Exercise the real planner and worker with only the scene verdict command
# doubled. Complete rendered/native execution remains hosted evidence.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
worker="$root/tools/run-client-scene-shard.sh"
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
fail() {
  echo "TEST FAIL -- $*" >&2
  exit 1
}
[[ -f "$worker" ]] || fail 'ordinary scenes still have no isolated worker'
GOTOOLCHAIN=local GOWORK=off go test "$root/tools/client-scene-plan/main.go" "$root/tools/client-scene-plan/main_test.go"
GOTOOLCHAIN=local GOWORK=off go build -o "$scratch/client-scene-plan" "$root/tools/client-scene-plan/main.go"
fixture="$scratch/product"
mkdir -p "$fixture/client/tests" "$fixture/tools" "$fixture/temp"
for scene in save_fixture_guard_test creature_factory_test save_vault_guard_test boot_recovery_guard_test vault_restore_boot_test ability_registry_test case{00..11}_test; do
  printf '[gd_scene]\n' >"$fixture/client/tests/$scene.tscn"
done
cat >"$fixture/tools/run-client-test.sh" <<'RUNNER'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$1" >> "$RUNNER_TEMP/calls"
mkdir -p "$XDG_DATA_HOME"
printf 'synthetic private state\n' > "$XDG_DATA_HOME/state"
exit "${SCENE_FIXTURE_EXIT:-0}"
RUNNER
chmod +x "$fixture/tools/run-client-test.sh"
git -C "$fixture" init -q -b main
git -C "$fixture" add client/tests tools/run-client-test.sh
git -C "$fixture" -c commit.gpgsign=false -c core.hooksPath=/dev/null \
  -c user.name=Fixture -c user.email=fixture@example.invalid commit -qm fixture
sha=$(git -C "$fixture" rev-parse HEAD)
cp "$scratch/client-scene-plan" "$fixture/temp/client-scene-plan"
run_worker() {
  (cd "$fixture" && RUNNER_TEMP="$fixture/temp" XDG_DATA_HOME="$fixture/temp/war-client-scenes-$1" \
    GITHUB_SHA="$sha" GITHUB_RUN_ID=77 GITHUB_RUN_ATTEMPT=2 bash "$worker" "$1")
}
mkdir "$scratch/artifacts"
for shard in 0 1 2; do
  run_worker "$shard" >"$scratch/worker.log" 2>&1 || fail "worker $shard failed"
  [[ ! -e "$fixture/temp/war-client-scenes-$shard" ]] || fail 'worker reported completion before cleanup'
  artifact="$scratch/artifacts/client-scenes-$shard-$sha-77-2"
  mkdir "$artifact"
  cp "$fixture/temp/client-scene-$shard/receipt.json" "$artifact/receipt.json"
done
[[ $(wc -l <"$fixture/temp/calls") -eq 12 && $(sort -u "$fixture/temp/calls" | wc -l) -eq 12 ]] || fail 'workers did not run the exact disjoint scene set'
(cd "$fixture" && "$scratch/client-scene-plan" verify "$sha" 77 2 "$scratch/artifacts") || fail 'real worker receipts did not reduce'
# Reused output directories must not allow old receipts to survive a retry.
if run_worker 0 >"$scratch/worker.log" 2>&1; then fail 'accepted a reused worker output directory'; fi
rm -rf "$fixture/temp/client-scene-0"
if SCENE_FIXTURE_EXIT=23 run_worker 0 >"$scratch/worker.log" 2>&1; then fail 'accepted a failing scene'; fi
[[ ! -e "$fixture/temp/client-scene-0/receipt.json" ]] || fail 'failed scene produced completion'
rm -rf "$fixture/temp/client-scene-0"
mkdir "$scratch/bad-rm"
printf '#!/usr/bin/env bash\nexit 31\n' >"$scratch/bad-rm/rm"
chmod +x "$scratch/bad-rm/rm"
if PATH="$scratch/bad-rm:$PATH" run_worker 0 >"$scratch/worker.log" 2>&1; then fail 'accepted failed private-state cleanup'; fi
[[ ! -e "$fixture/temp/client-scene-0/receipt.json" ]] || fail 'cleanup refusal produced completion'
for shard in '' -1 3 00 '0 1'; do
  if run_worker "$shard" >"$scratch/worker.log" 2>&1; then fail 'accepted an invalid worker'; fi
done
echo 'TEST PASS -- real scene worker requires complete execution and cleanup before its exact receipt'
