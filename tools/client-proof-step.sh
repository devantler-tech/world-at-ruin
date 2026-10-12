#!/usr/bin/env bash
# GitHub supplies one job-private script; its complete process group is owned
# by the existing bounded phase supervisor, including on runner cancellation.
set -euo pipefail
if [[ $# != 1 || ! -f $1 ]]; then
  echo '::error::ordinary client phase needs its generated step script' >&2
  exit 2
fi
exec bash tools/trusted-regression-phase.sh 'ordinary client step' \
  bash --noprofile --norc -e -o pipefail "$1"
