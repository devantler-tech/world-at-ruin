#!/usr/bin/env bash
# Execute the regression suite from a trusted workflow snapshot against a
# candidate checkout. The candidate supplies product code; it never supplies
# the selector, test harness, historical fixtures, or verdict runner. The one
# candidate data declaration is validated against the trusted capability ledger.
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

scratch_root="$(mktemp -d "${TMPDIR:-/tmp}/required-regression-control.XXXXXX")"
evaluation_root="${scratch_root}/candidate"
# Remove this invocation's private evaluation tree and reconstructed ledger on exit.
cleanup() {
	rm -rf "${scratch_root}"
}
trap cleanup EXIT
mkdir "${evaluation_root}"

# Accept only the already shipped declaration or the one planned mastery
# activation. Construct the permitted bytes ourselves: candidate comments,
# rewritten history and future capabilities cannot redefine the contract.
ledger_path='client/tests/data/shipped_save_capability.txt'
for root in "${trusted_root}" "${candidate_root}"; do
	for path in client/tests client/tests/data "${ledger_path}"; do
		if [ -L "${root}/${path}" ]; then
			echo "::error::save-capability declaration has a symlinked path" >&2
			exit 1
		fi
	done
	if [ ! -f "${root}/${ledger_path}" ]; then
		echo "::error::save-capability declaration is missing" >&2
		exit 1
	fi
done
# A later append must start a new record, never concatenate onto the old ceiling.
if [ "$(tail -c 1 "${trusted_root}/${ledger_path}" | wc -l)" -ne 1 ]; then
	echo "::error::trusted save-capability declaration lacks its final newline" >&2
	exit 1
fi
trusted_capability="$(awk '
	/^#/ || /^$/ { next }
	!/^[1-9][0-9]*$/ || $0 != ++capability { invalid = 1; exit }
	END {
		if (invalid || (capability != 6 && capability != 7)) exit 1
		print capability
	}
' "${trusted_root}/${ledger_path}")" || {
	echo "::error::trusted save-capability declaration is malformed or unsupported" >&2
	exit 1
}
validated_ledger="${scratch_root}/validated-capability.txt"
cp "${trusted_root}/${ledger_path}" "${validated_ledger}"
if ! cmp -s "${candidate_root}/${ledger_path}" "${validated_ledger}"; then
	if [ "${trusted_capability}" != 6 ]; then
		echo "::error::save-capability declaration differs from shipped history" >&2
		exit 1
	fi
	printf '7\n' >>"${validated_ledger}"
	if ! cmp -s "${candidate_root}/${ledger_path}" "${validated_ledger}"; then
		echo "::error::save-capability declaration must preserve history and append only capability 7" >&2
		exit 1
	fi
fi

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
cp "${validated_ledger}" "${evaluation_root}/${ledger_path}"
rm "${validated_ledger}"

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
