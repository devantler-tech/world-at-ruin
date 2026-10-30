#!/usr/bin/env bash
# Package only capture evidence; never upload a BASE checkout or private save.
set -euo pipefail
copy_log() {
  local log=$1 destination=$2
  [[ -f $log && ! -L $log ]] || {
    echo "missing regular capture log: $log" >&2
    return 1
  }
  cp "$log" "$destination/"
}
case ${1:-} in
head)
  case ${CAPTURE_GROUP:-} in world | activity) ;; *)
    echo 'unknown source group' >&2
    exit 1
    ;;
  esac
  package="$RUNNER_TEMP/shots"
  mkdir "$package/logs"
  if [[ $CAPTURE_GROUP == world ]]; then
    copy_log capture.log "$package/logs"
  else
    copy_log capture-replication.log "$package/logs"
    copy_log capture-mob-chase.log "$package/logs"
  fi
  go run tools/source-evidence/main.go seal "$CAPTURE_GROUP" "$package" success
  ;;
base)
  for outcome in "${INSTALL_RESULT:-}" "${RENDER_RESULT:-}"; do
    case $outcome in success | failure | skipped | cancelled) ;; *)
      echo 'unknown BASE outcome' >&2
      exit 1
      ;;
    esac
  done
  package="$RUNNER_TEMP/source-base"
  [[ ! -e $package && ! -L $package ]] || {
    echo 'BASE package already exists' >&2
    exit 1
  }
  mkdir "$package"
  verdict=failure
  if [[ $INSTALL_RESULT == success && $RENDER_RESULT == success ]]; then
    # Keep the flat PNG/caption tree separate from the worktree and saved game.
    [[ -d $RUNNER_TEMP/shots-base && ! -L $RUNNER_TEMP/shots-base ]]
    cp -R "$RUNNER_TEMP/shots-base/." "$package/"
    mkdir "$package/logs"
    copy_log base-capture.log "$package/logs"
    if [[ $FIRST_RUN == true ]]; then copy_log base-first-run.log "$package/logs"; fi
    verdict=success
  else
    echo '::warning::BASE capture failed; its partial frames will not be compared'
  fi
  go run tools/source-evidence/main.go seal base "$package" "$verdict"
  ;;
*)
  echo 'usage: source-evidence-package.sh head|base' >&2
  exit 2
  ;;
esac
