#!/usr/bin/env bash
# Build refusal controls from the exact source returned by the successful scan.
set -euo pipefail
control=$(mktemp -d "$RUNNER_TEMP/retired-links.XXXXXX")
trap 'rm -rf "$control"' EXIT
mkdir "$control/.github"
cp .github/retired-repo-links.json "$control/.github/"
cp README.md AGENTS.md "$control/"
[[ "$VALIDATOR_SOURCE" == /* ]]
test -f "$VALIDATOR_SOURCE/go.mod"
test -f "$VALIDATOR_SOURCE/main.go"
go -C "$VALIDATOR_SOURCE" build -mod=readonly -trimpath -o "$control/validator" .
printf '\nhttps://github.com/devantler-tech/reusable-workflows\n' >>"$control/README.md"
status=0
"$control/validator" --root "$control" >"$control/negative.log" 2>&1 || status=$?
test "$status" = 1 || { cat "$control/negative.log"; exit 1; }
grep -Eq '^README.md:[0-9]+: link targets retired repository devantler-tech/reusable-workflows$' "$control/negative.log"
rm "$control/.github/retired-repo-links.json"
status=0
"$control/validator" --root "$control" >"$control/missing.log" 2>&1 || status=$?
test "$status" = 2 || { cat "$control/missing.log"; exit 1; }
grep -q '^Invalid configuration:' "$control/missing.log"
echo 'PASS: clean scan, seeded retired link rejection, and missing configuration refusal'
