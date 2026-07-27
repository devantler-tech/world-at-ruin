#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

if ! command -v gdlint >/dev/null 2>&1; then
  echo "gdlint is unavailable; install gdtoolkit 4.5.0" >&2
  exit 127
fi

cd "${repo_root}"
exec gdlint "$@"
