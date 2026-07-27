#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lint_script="${repo_root}/tools/gdscript-lint.sh"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "${tmp_dir}"' EXIT

if ! command -v gdlint >/dev/null 2>&1; then
  echo "TEST FAIL — gdlint is unavailable; install gdtoolkit 4.5.0" >&2
  exit 1
fi

if [[ ! -x "${lint_script}" ]]; then
  echo "TEST FAIL — ${lint_script} is not an executable lint entrypoint" >&2
  exit 1
fi

mkdir -p "${tmp_dir}/clean" "${tmp_dir}/broken"

cat >"${tmp_dir}/clean/example.gd" <<'GDSCRIPT'
extends Node


func _ready() -> void:
	print("ready")
GDSCRIPT

cat >"${tmp_dir}/broken/example.gd" <<'GDSCRIPT'
extends Node


func _ready() -> void:
	1 + 1
GDSCRIPT

"${lint_script}" "${tmp_dir}/clean"

if "${lint_script}" "${tmp_dir}/broken" >"${tmp_dir}/broken.log" 2>&1; then
  echo "TEST FAIL — an unassigned expression passed GDScript lint" >&2
  exit 1
fi

if ! grep -q "(expression-not-assigned)" "${tmp_dir}/broken.log"; then
  echo "TEST FAIL — the invalid fixture failed for the wrong reason" >&2
  cat "${tmp_dir}/broken.log" >&2
  exit 1
fi

echo "TEST PASS — GDScript lint accepts a valid fixture and rejects an unassigned expression"
