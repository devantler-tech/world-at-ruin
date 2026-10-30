#!/usr/bin/env bash
# A successful matrix means all three fixed, isolated workers. The union proof
# is separately required and accepts only this integration and run attempt.
set -euo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if ! yq -o=json . "${1:-$root/.github/workflows/ci.yaml}" | jq -e '
  def checkout:
    .=={uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",
      with:{"fetch-depth":0,"persist-credentials":false}};
  def setup:
    .=={uses:"actions/setup-go@b7ad1dad31e06c5925ef5d2fc7ad053ef454303e",
      with:{"go-version-file":"server/go.mod",cache:false}};
  def build:
    .run=="GOTOOLCHAIN=local GOWORK=off go build -o \"$RUNNER_TEMP/client-scene-plan\" tools/client-scene-plan/main.go";
  .jobs as $jobs | $jobs["client-scene-shards"] as $worker | $jobs["client-scene-proof"] as $proof |
  ($worker|keys)==["defaults","env","name","runs-on","steps","strategy","timeout-minutes"] and
  $worker.name=="Client scenes (${{ matrix.shard }})" and
  $worker["runs-on"]=="ubuntu-latest" and $worker["timeout-minutes"]==15 and
  $worker.defaults=={run:{shell:"bash --noprofile --norc tools/client-proof-step.sh {0}"}} and
  $worker.env=={SCENE_SHARD:"${{ matrix.shard }}"} and
  $worker.strategy=={"fail-fast":false,matrix:{shard:["0","1","2"]}} and
  ($worker.steps|length)==8 and
  all($worker.steps[]; (has("if") or has("continue-on-error") or has("shell") or has("env") or has("working-directory"))|not) and
  ($worker.steps[0]|checkout) and ($worker.steps[2]|setup) and
  $worker.steps[1].run=="printf \u0027XDG_DATA_HOME=%s/war-client-scenes-%s\\n\u0027 \"$RUNNER_TEMP\" \"$SCENE_SHARD\" >> \"$GITHUB_ENV\"" and
  $worker.steps[3].run=="bash tools/install-ci-godot.sh" and
  $worker.steps[4].run=="set -o pipefail\nbash tools/trusted-regression-phase.sh \"editor import\" godot --headless --editor --quit --path client 2>&1 | tee import.log\nif grep -qE \u0027SCRIPT ERROR|^ERROR\u0027 import.log; then exit 1; fi\n" and
  ($worker.steps[5]|build) and
  $worker.steps[6].run=="bash tools/run-client-scene-shard.sh \"$SCENE_SHARD\"" and
  $worker.steps[7]=={uses:"actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",with:{
    name:"client-scenes-${{ matrix.shard }}-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}",
    path:"${{ runner.temp }}/client-scene-${{ matrix.shard }}/receipt.json","if-no-files-found":"error"}} and
  ($proof|keys)==["name","needs","outputs","runs-on","steps","timeout-minutes"] and
  $proof.name=="Complete client scene union" and $proof.needs==["client-scene-shards"] and
  $proof["runs-on"]=="ubuntu-latest" and $proof["timeout-minutes"]==5 and
  $proof.outputs=={complete:"${{ steps.proof.outputs.complete }}","tested-sha":"${{ steps.proof.outputs.tested-sha }}",
    "run-id":"${{ steps.proof.outputs.run-id }}","run-attempt":"${{ steps.proof.outputs.run-attempt }}"} and
  ($proof.steps|length)==5 and
  all($proof.steps[];(has("if") or has("continue-on-error") or has("env") or has("working-directory"))|not) and
  ($proof.steps[0]|checkout) and ($proof.steps[1]|setup) and
  $proof.steps[2]=={uses:"actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333",with:{
    pattern:"client-scenes-*-${{ github.sha }}-${{ github.run_id }}-${{ github.run_attempt }}",
    path:"${{ runner.temp }}/scene-proofs","merge-multiple":false}} and
  ($proof.steps[3]|build) and
  $proof.steps[4]=={name:"Verify the complete scene set",id:"proof",shell:"bash",run:
    "set -euo pipefail\n\"$RUNNER_TEMP/client-scene-plan\" verify \"$GITHUB_SHA\" \"$GITHUB_RUN_ID\" \"$GITHUB_RUN_ATTEMPT\" \"$RUNNER_TEMP/scene-proofs\"\nprintf \u0027complete=true\\ntested-sha=%s\\nrun-id=%s\\nrun-attempt=%s\\n\u0027 \"$GITHUB_SHA\" \"$GITHUB_RUN_ID\" \"$GITHUB_RUN_ATTEMPT\" >> \"$GITHUB_OUTPUT\"\n"} and
  all(["client-scene-shards","client-scene-proof"][]; . as $job |
    ($jobs["ci-required-checks"].needs|index($job))!=null) and
  # Dedicated commands must be unique, unconditional ordinary steps. Reading
  # closed step data never executes candidate workflow text in this validator.
  all([
    "./tools/run-client-test.sh save_fixture_guard_test \"a historical save no longer loads with zero loss\"",
    "./tools/run-client-test.sh creature_factory_test \"a shipped creature recipe version lost its fixture or no longer builds\"",
    "./tools/run-client-test.sh save_vault_guard_test \"a historical vault no longer loads with zero loss\"",
    "./tools/run-client-test.sh boot_recovery_guard_test \"a historical boot-recovery document no longer loads with zero loss\"",
    "./tools/run-client-test.sh vault_restore_boot_test \"an attuned respawn point no longer restores on boot\"",
    "./tools/run-client-test.sh ability_registry_test \"a combat product law is broken\"",
    "bash tools/client-scene-shards.test.sh\nbash tools/client-scene-workflow-guard.test.sh\n"
  ][]; . as $command |
    [$jobs["client-ordinary"].steps[] | select(.run==$command)] as $steps |
    ($steps|length)==1 and ($steps[0]|keys)==["name","run"]) and
  (any($jobs["client-ordinary"].steps[];(.run // "")|contains("Ran ${ran} discovered regression"))|not)
' >/dev/null; then
  echo '::error::client scenes require three isolated workers and a complete integration/attempt-bound union' >&2
  exit 1
fi
