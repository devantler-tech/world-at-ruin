#!/usr/bin/env bash
# Every tracked GDScript under client/ must have its .uid tracked beside it (#1635).
#
# Godot writes a missing .uid during the editor import, with a different id on
# every machine. A fresh checkout is then no longer clean after the import the
# validation steps require, and a check that runs after the import cannot see
# the gap at all. So this guard reads the Git index only, never the working tree.
# #426 and #487 fixed earlier cases of the same gap by hand.
#
# Usage: tools/script-uid-guard.sh [repository-root]
set -euo pipefail

root="${1:-.}"
work="$(mktemp -d)"
trap 'rm -rf "${work}"' EXIT

git -C "${root}" ls-files -z -- 'client/*.gd' 'client/*.gd.uid' >"${work}/index"

# The comparison below is line based. A tracked path holding a newline cannot be
# compared that way, so it fails closed instead of being skipped.
records="$(tr -cd '\000' <"${work}/index" | wc -c | tr -d ' ')"
lines="$(tr '\000' '\n' <"${work}/index" | wc -l | tr -d ' ')"
if [ "${records}" != "${lines}" ]; then
	echo "::error::a tracked client script path contains a newline; the .uid guard cannot compare it"
	exit 1
fi

tr '\000' '\n' <"${work}/index" >"${work}/paths"
grep '\.gd$' "${work}/paths" | sed 's/$/.uid/' | LC_ALL=C sort >"${work}/expected" || true
grep '\.gd\.uid$' "${work}/paths" | LC_ALL=C sort >"${work}/tracked" || true

scripts="$(wc -l <"${work}/expected" | tr -d ' ')"
if [ "${scripts}" = "0" ]; then
	echo "::error::no tracked client/*.gd found under ${root}; the .uid guard examined nothing"
	exit 1
fi

LC_ALL=C comm -23 "${work}/expected" "${work}/tracked" >"${work}/missing"
missing="$(wc -l <"${work}/missing" | tr -d ' ')"
if [ "${missing}" != "0" ]; then
	while IFS= read -r uid; do
		script="${uid%.uid}"
		echo "::error file=${script}::${script} has no tracked ${uid}; run the editor import and commit the generated file"
	done <"${work}/missing"
	echo "SCRIPT UID GUARD FAIL: ${missing} of ${scripts} tracked client scripts have no tracked .uid"
	exit 1
fi
echo "SCRIPT UID GUARD PASS: all ${scripts} tracked client scripts have a tracked .uid"
