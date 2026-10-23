#!/usr/bin/env bash
# Assemble and judge on the host; execute candidate Godot only in containment.
set -euo pipefail
if [ "$#" -ne 2 ]; then
  echo 'usage: run-sandboxed-trusted-regressions.sh <trusted-root> <candidate-root>' >&2
  exit 2
fi
root="$(cd "$(dirname "$0")/.." && pwd -P)"
# Public invocation always builds from its own reviewed runtime sources. Never
# accept an image from arguments or inherited environment on this entrypoint.
# shellcheck source=tools/sandbox-regression-context.sh
source "$root/tools/sandbox-regression-context.sh"
run_sandboxed_regression_context "$1" "$2" ''
