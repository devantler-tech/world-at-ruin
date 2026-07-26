#!/usr/bin/env bash
set -euo pipefail

workflow=${1:-.github/workflows/cd.yaml}
workflow_directory=$(cd -- "$(dirname -- "$workflow")" && pwd -P)
workflow_path="${workflow_directory}/$(basename -- "$workflow")"
script_directory=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
validator_directory="${script_directory}/release-credential-boundary"

exec go -C "$validator_directory" run . "$workflow_path"
