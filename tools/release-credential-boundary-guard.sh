#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cd.yaml}
workflow_directory=$(cd -- "$(dirname -- "$workflow")" && pwd -P)
workflow_path="${workflow_directory}/$(basename -- "$workflow")"

exec go -C server run ./cmd/release-credential-boundary "$workflow_path"
