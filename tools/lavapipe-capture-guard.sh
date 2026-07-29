#!/usr/bin/env bash
# Validate that a lavapipe frame capture exercised the enabled volumetric path
# and produced inspectable evidence. Unknown or contradictory state is failure.
set -euo pipefail

log=${1:-}
shots=${2:-}

die() {
	printf 'lavapipe capture guard: %s\n' "$1" >&2
	exit 1
}

[ -n "$log" ] && [ -f "$log" ] ||
	die "capture log is missing"
[ -n "$shots" ] && [ -d "$shots" ] ||
	die "shot directory is missing"

grep -Eq '^Vulkan .*Using Device #[0-9]+: (Unknown - )?llvmpipe([[:space:]]|\()' "$log" ||
	die "capture did not prove it used the lavapipe Vulkan device"

read_verdict() {
	local marker=$1
	local distinct count
	distinct="$(
		grep -oE "^${marker} (on|off)([[:space:]]|$)" "$log" |
			sed -E "s/^${marker} //; s/[[:space:]]*$//" |
			sort -u
	)"
	count="$(printf '%s\n' "$distinct" | grep -c . || true)"
	[ "$count" -eq 1 ] ||
		die "expected one ${marker} verdict, found ${count}"
	printf '%s' "$distinct"
}

[ "$(read_verdict VOLUMETRICS)" = "on" ] ||
	die "volumetric rendering reported the fallback path"
[ "$(read_verdict 'HOLLOW FOG')" = "on" ] ||
	die "the capture built no hollow fog"

grep -Eq '^HOLLOW FOG on — [1-9][0-9]* drifting ash pools$' "$log" ||
	die "the enabled hollow-fog marker did not report a positive pool count"
grep -q 'BOOT_OK' "$log" ||
	die "the real boot path never completed"
grep -q 'CAPTURE PASS' "$log" ||
	die "the frame capture did not report success"

if grep -qE 'SCRIPT ERROR|^ERROR|SHADER ERROR|Shader compilation failed' "$log"; then
	die "runtime or shader errors make the rendered evidence untrustworthy"
fi

[ -n "$(find "$shots" -type f -name '*.png' -size +0c -print -quit)" ] ||
	die "no non-empty PNG was captured"

printf 'lavapipe capture guard: OK\n'
