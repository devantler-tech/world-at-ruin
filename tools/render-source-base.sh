#!/usr/bin/env bash
set -euo pipefail
set -o pipefail
base="$BASE_SHA"
echo "base (pairs with the checked-out merge result): $base"
git worktree add --detach "${RUNNER_TEMP}/base" "$base"
godot --headless --editor --quit --path "${RUNNER_TEMP}/base/client" 2>&1 | tail -5
mkdir -p "${RUNNER_TEMP}/shots-base"
# Seed from the BASE's own recipe, not the head's: a PR that edits the
# recipe would otherwise render the base world wearing the head's
# character, and every frame would differ for that reason alone.
if ! cp "${RUNNER_TEMP}/base/client/recipes/wanderer.json" "${RUNNER_TEMP}/probe_save_base.json"; then
  echo "::warning::could not seed the base capture's save — skipping the change report"
  exit 1
fi
WAR_SHOT_DIR="${RUNNER_TEMP}/shots-base" \
  WAR_SAVE_PATH="${RUNNER_TEMP}/probe_save_base.json" \
  WAR_VAULT_PATH="${RUNNER_TEMP}/probe_save_base_vault.json" \
  WAR_BOOT_RECOVERY_PATH="${RUNNER_TEMP}/probe_save_base_recovery.json" \
  godot --path "${RUNNER_TEMP}/base/client" res://tools/frame_capture.tscn 2>&1 | tee base-capture.log
if ! grep -q "CAPTURE PASS" base-capture.log; then
  echo "::warning::the merge base did not render cleanly — the change report will be incomplete"
  tail -20 base-capture.log
  exit 1
fi
# The head captures the first-run UI into the SAME shots dir when the
# PR touches the creator, so without a matching base render every
# first_run*.png is reported "no base frame" — and a character-creator
# PR would get a change report covering only the world vantages it did
# NOT touch, while the UI it actually changed carries no measurement.
# That is the #145 shape all over again, one level up.
#
# The save must be ABSENT for the creator to open, exactly as the head
# step does it; point at a path that was never created.
#
# A warning rather than exit 1: the world frames above already compared
# successfully, and discarding their measurement because the base's
# creator failed to render would throw away the evidence we have.
if [ "$FIRST_RUN" = "true" ]; then
  WAR_SHOT_DIR="${RUNNER_TEMP}/shots-base" \
    WAR_SCENARIO=first_run \
    WAR_LAYERED_OUTFIT_PICKERS=1 \
    WAR_SAVE_PATH="${RUNNER_TEMP}/no_such_save_base.json" \
    WAR_VAULT_PATH="${RUNNER_TEMP}/no_such_save_base_vault.json" \
    WAR_BOOT_RECOVERY_PATH="${RUNNER_TEMP}/no_such_save_base_recovery.json" \
    godot --path "${RUNNER_TEMP}/base/client" res://tools/frame_capture.tscn 2>&1 |
    tee base-first-run.log || true
  # The world scenario prints "CAPTURE PASS" too, so require the
  # first-run marker: a base that silently fell back to the world path
  # would leave first_run frames unmatched while looking like a success.
  if ! grep -qE "[0-9]+ first-run vantages? written" base-first-run.log; then
    echo "::warning::the base did not render the first-run UI — creator frames will carry no change measurement"
    tail -20 base-first-run.log || true
  fi
fi
