#!/usr/bin/env bash
# Bind a schema family to an executed test and production reader. Fixture probes
# run only in a private copy; the checkout and historical data are never edited.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ledger="$1"
scratch="$2"
dir="${ledger%/testdata/*}"
family="${ledger##*/shipped_}"
family="${family%_versions.txt}"
contract="${ledger%_versions.txt}_reader.txt"

# fail reports the affected ledger and refusal reason, then exits unsuccessfully.
fail() {
	printf 'Server reader contract: FAIL — %s: %s\n' "$ledger" "$1" >&2
	exit 1
}

# Refuse symlinks before reading a contract or its named production source.
require_file() {
	local path="$1" part="$1"
	[ -f "$path" ] || fail "$path is missing"
	while :; do
		[ ! -L "$part" ] || fail "$path must not depend on a symbolic link"
		[ "$part" != "${part%/*}" ] || break
		part="${part%/*}"
	done
}

require_file "$contract"
awk 'NR != 1 || NF != 3 || $1 !~ /^Test[A-Z][A-Za-z0-9_]*$/ ||
 $2 !~ /^[A-Za-z0-9_]+\.go$/ || $2 ~ /_test\.go$/ ||
 $3 !~ /^[A-Za-z_][A-Za-z0-9_]*$/ { exit 1 }
 END { if (NR != 1) exit 1 }' "$contract" || fail 'malformed test / production file / reader registration'
read -r test_name source reader <"$contract"
require_file "$dir/$source"
work="$(mktemp -d "$scratch/reader.XXXXXX")"
binary="$work/reader.test"
events="$work/events.jsonl"
profile="$work/coverage.out"
package="${dir#server/}"
if ! go -C server test -c -cover -o "$binary" "./$package" >"$work/build.log" 2>&1; then
	cat "$work/build.log" >&2
	fail 'reader test did not compile'
fi
mkdir "$work/run"
cp -R "$dir/testdata" "$work/run/testdata"

# Exact JSON test events distinguish an executed pass from no tests or a skip.
run_test() {
	local executable="${1:-$binary}"
	local flags=(-test.v=test2json -test.run="^${test_name}$" -test.count=1 -test.timeout=60s)
	if [ "$executable" = "$binary" ]; then
		flags+=(-test.coverprofile="$profile")
	fi
	(cd "$work/run" && go tool test2json -t -p "$package" "$executable" \
		"${flags[@]}") >"$events" 2>&1
}

if ! run_test; then
	cat "$events" >&2
	fail 'historical reader test failed'
fi
jq -e -s --arg test "$test_name" \
	'any(.[]; .Test == $test and .Action == "run") and
 any(.[]; .Test == $test and .Action == "pass") and
 all(.[]; .Action != "skip" and .Action != "fail")' \
	"$events" >/dev/null || fail 'registered test did not execute and pass completely'
go -C server tool cover -func="$profile" >"$work/coverage.txt" || fail 'reader coverage is unavailable'
awk -v file="/$source:" -v reader="$reader" '
 index($1, file) && $2 == reader { matches++; if ($3 + 0 > 0) covered++ }
 END { exit !(matches == 1 && covered == 1) }
' "$work/coverage.txt" || fail 'registered production reader was not exercised unambiguously'

# Compile an overlay that returns zero state only when this run's private marker
# reaches the reader. Ignored calls and calls on unrelated constants cannot kill it.
probe="$work/probe"
go build -o "$probe" "$SCRIPT_DIR/server-reader-probe/main.go" || fail 'probe helper did not compile'
"$probe" reader "$dir/$source" "$reader" "$work/reader.go" "$work/marker" ||
	fail 'reader must accept raw JSON as its first string or []byte parameter'
package_dir="$(go -C server list -f '{{.Dir}}' "./$package")" || fail 'reader package path is unavailable'
jq -n --arg source "$package_dir/$source" --arg replacement "$work/reader.go" \
	'{Replace: {($source): $replacement}}' >"$work/overlay.json"
# Keep both comparison builds uninstrumented: coverage can mask source overlays.
control="$work/control.test"
if ! go -C server test -c -o "$control" "./$package" >"$work/control-build.log" 2>&1; then
	cat "$work/control-build.log" >&2
	fail 'reader control did not compile'
fi
mutant="$work/ablated.test"
if ! go -C server test -c -overlay "$work/overlay.json" -o "$mutant" "./$package" >"$work/mutant-build.log" 2>&1; then
	cat "$work/mutant-build.log" >&2
	fail 'instrumented reader did not compile'
fi

# Every declared fixture must affect the selected test. A test using constants,
# skipping new versions, or ignoring fixture-read errors cannot pass this probe.
while IFS= read -r version || [ -n "$version" ]; do
	fixture="golden_${family}_v${version}.json"
	"$probe" fixture "$dir/testdata/$fixture" "$work/run/testdata/$fixture" "$work/marker" ||
		fail "$fixture could not be marked without changing its JSON meaning"
	if ! run_test "$control"; then
		cat "$events" >&2
		fail "$fixture must remain readable with internal JSON whitespace"
	fi
	jq -e -s --arg test "$test_name" \
		'any(.[]; .Test == $test and .Action == "pass") and
 all(.[]; .Action != "skip" and .Action != "fail")' \
		"$events" >/dev/null || fail "$fixture marker control did not pass completely"
	if run_test "$mutant"; then
		fail "$fixture does not drive assertions on the registered reader output"
	fi
	jq -e -s --arg test "$test_name" \
		'any(.[]; .Test == $test and .Action == "fail")' \
		"$events" >/dev/null || fail "$fixture reader ablation did not produce a test failure"
	printf 'unreadable historical fixture\n' >"$work/run/testdata/$fixture"
	if run_test "$control"; then
		fail "$fixture is not exercised by the registered test"
	fi
	jq -e -s --arg test "$test_name" \
		'any(.[]; .Test == $test and .Action == "fail")' \
		"$events" >/dev/null || fail "$fixture did not produce a reader-test failure"
	cp "$dir/testdata/$fixture" "$work/run/testdata/$fixture"
done <"$ledger"
printf 'Server reader contract: PASS — %s (%s / %s)\n' "$ledger" "$test_name" "$reader"
