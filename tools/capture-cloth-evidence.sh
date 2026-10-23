#!/usr/bin/env bash
# Keep every material/geometry arm in an isolated, real Metal capture.
set -euo pipefail
: "${RUNNER_TEMP:?}"
modes=(off on drape both)
if [[ $# -gt 0 ]]; then
  if [[ $# -ne 1 ]]; then
    echo 'cloth capture: expected one fixed mode or no arguments' >&2
    exit 2
  fi
  case "$1" in
  off | on | drape | both) modes=("$1") ;;
  *)
    echo 'cloth capture: unknown mode' >&2
    exit 2
    ;;
  esac
fi
for mode in "${modes[@]}"; do
  value=0
  verdict=false
  drape=0
  drape_verdict=false
  if [ "$mode" = on ] || [ "$mode" = both ]; then
    value=1
    verdict=true
  fi
  if [ "$mode" = drape ] || [ "$mode" = both ]; then
    drape=1
    drape_verdict=true
  fi
  dir="${RUNNER_TEMP}/shots/ragged-cloth/$mode"
  # Never overwrite an earlier local capture or accept its files as this run's
  # evidence. Atomic creation also refuses a competing worker or a symlink.
  mkdir -p "${dir%/*}"
  if ! mkdir "$dir"; then
    echo 'cloth capture: the mode output directory must be fresh' >&2
    exit 1
  fi
  WAR_RAGGED_CLOTH_DETAIL="$value" WAR_RAGGED_CLOTH_DRAPE="$drape" WAR_RAGGED_WRAP_REFINEMENT="$drape" WAR_SCENARIO=ragged_cloth \
    WAR_SHOT_DIR="$dir" \
    WAR_SAVE_PATH="${RUNNER_TEMP}/cloth_${mode}_absent.json" \
    WAR_VAULT_PATH="${RUNNER_TEMP}/cloth_${mode}_vault.json" \
    WAR_BOOT_RECOVERY_PATH="${RUNNER_TEMP}/cloth_${mode}_recovery.json" \
    godot --path client res://tools/frame_capture.tscn 2>&1 | tee "cloth-$mode.log"
  grep -Fxq "CAPTURE PASS — ragged cloth: front, rear, profile and gameplay; detail=$verdict drape=$drape_verdict" "cloth-$mode.log"
  grep -Fxq "WRAP REFINEMENT — enabled=$drape_verdict" "cloth-$mode.log"
  grep -Eq '^BOOT_OK v[^[:space:]]+ — world built, [0-9]+ people and [0-9]+ hounds in the Reach$' "cloth-$mode.log"
  grep -vE 'timeout waiting for fence|drivers/metal/rendering_device_driver_metal' \
    "cloth-$mode.log" >"cloth-$mode.filtered.log" || true
  if grep -qE 'SCRIPT ERROR|^ERROR|SHADER ERROR|Shader compilation failed' "cloth-$mode.filtered.log"; then
    echo "::error::ragged cloth $mode capture encountered rendering errors"
    exit 1
  fi
  for view in cloth_front cloth_rear cloth_profile cloth_gameplay; do
    for arm in '' _repeat _fold_off _seam_off _flat _mask _geometry_flat _geometry_mask _unrefined _unrefined_mask; do
      test -s "$dir/$view$arm.png"
      test -s "$dir/$view$arm.txt"
    done
  done
done
