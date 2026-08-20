#!/usr/bin/env bash
# Execute the regression suite from a trusted workflow snapshot against a
# candidate checkout. The candidate supplies product code; it never supplies
# the selector, test harness, fixtures, or verdict runner.
set -euo pipefail

if [ "$#" -ne 2 ]; then
	echo "::error::usage: tools/required-regression-control.sh <trusted-root> <candidate-root>" >&2
	exit 2
fi

trusted_root="$(cd "$1" 2>/dev/null && pwd -P)" || {
	echo "::error::trusted workflow snapshot is not a readable directory" >&2
	exit 2
}
candidate_root="$(cd "$2" 2>/dev/null && pwd -P)" || {
	echo "::error::candidate checkout is not a readable directory" >&2
	exit 2
}
trusted_tests="${trusted_root}/client/tests"
trusted_runner="${trusted_root}/tools/run-client-test.sh"

if [ ! -d "${trusted_tests}" ] || [ -L "${trusted_tests}" ]; then
	echo "::error::trusted regression directory is missing or symlinked: ${trusted_tests}" >&2
	exit 2
fi
if [ ! -x "${trusted_runner}" ] || [ -L "${trusted_runner}" ]; then
	echo "::error::trusted client-test runner is missing, non-executable, or symlinked" >&2
	exit 2
fi
if [ ! -d "${candidate_root}/client" ] || [ -L "${candidate_root}/client" ]; then
	echo "::error::candidate client project is missing or symlinked" >&2
	exit 2
fi
if [ ! -f "${candidate_root}/client/project.godot" ]; then
	echo "::error::candidate client/project.godot is missing" >&2
	exit 2
fi
if ! command -v godot >/dev/null 2>&1; then
	echo "::error::trusted regressions could not execute: godot was not found in PATH" >&2
	exit 2
fi

LC_ALL=C
export LC_ALL
shopt -s nullglob
trusted_scenes=("${trusted_tests}"/*_test.tscn)
if [ "${#trusted_scenes[@]}" -eq 0 ]; then
	echo "::error::no trusted regression test scenes found under client/tests/*_test.tscn" >&2
	exit 1
fi

evaluation_root="$(mktemp -d "${TMPDIR:-/tmp}/required-regression-control.XXXXXX")"
cleanup() {
	rm -rf "${evaluation_root}"
}
trap cleanup EXIT

# Do not mutate the checkout Actions produced. Copy only tracked-worktree
# content (never its .git directory), then replace the candidate-controlled
# harness wholesale with the snapshot that contains this workflow.
if ! (
	cd "${candidate_root}"
	tar --exclude='./.git' --exclude='.git' -cf - .
) | (
	cd "${evaluation_root}"
	tar -xf -
); then
	echo "::error::candidate checkout could not be copied into the isolated evaluation root" >&2
	exit 2
fi

rm -rf -- "${evaluation_root}/client/tests"
cp -R "${trusted_tests}" "${evaluation_root}/client/tests"

if ! (
	cd "${evaluation_root}"
	set -o pipefail
	godot --headless --editor --quit --path client 2>&1 | tee trusted-import.log
); then
	echo "::error::candidate client failed the trusted headless import" >&2
	exit 1
fi
if grep -qE 'SCRIPT ERROR|^ERROR' "${evaluation_root}/trusted-import.log"; then
	echo "::error::candidate client reported errors during the trusted headless import" >&2
	exit 1
fi

ran=0
for scene in "${trusted_scenes[@]}"; do
	name="$(basename "${scene}" .tscn)"
	(
		cd "${evaluation_root}"
		"${trusted_runner}" "${name}" "trusted required regression failed"
	)
	ran=$((ran + 1))
done

printf 'Ran %d trusted regression test scene(s) from workflow snapshot %s.\n' \
	"${ran}" "${trusted_root}"
