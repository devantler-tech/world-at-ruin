#!/usr/bin/env bash
set -euo pipefail
set -o pipefail
if [ ! -d "${SOURCE_EVIDENCE_DIR}/shots-base" ]; then
  echo "::warning::no base frames — the merge base did not render, so this PR's frames carry no change measurement"
  exit 0
fi
# `|| true` is load-bearing, not sloppiness. The tool EXITS NONZERO
# when it can compare nothing, and this shell runs with -e and
# pipefail — so without it the step dies at the pipeline and the
# warning below, which is the entire point of that exit code, never
# runs. continue-on-error would keep the job green but leave only a
# failed step and no annotation saying the artifact has no comparison.
WAR_DIFF_BASE="${SOURCE_EVIDENCE_DIR}/shots-base" \
  WAR_DIFF_HEAD="${SOURCE_EVIDENCE_DIR}/shots" \
  godot --headless --path client res://tools/frame_diff.tscn 2>&1 | tee diff.log || true
# The tool fails closed when it compares nothing. Surface that as a
# warning rather than swallowing it: a silent empty report is the
# exact self-attestation #231 was filed about.
if ! grep -q "DIFF PASS" diff.log; then
  echo "::warning::the change report did not complete — this PR's frames carry no comparison against the base"
fi
# A vantage the base captured and the head did not is a REMOVED
# vantage. The tool names each one; surface it as an annotation too,
# since client/tools/ changes trigger this job precisely so a capture
# regression cannot pass quietly.
if grep -q "REMOVED:" diff.log; then
  echo "::warning::a committed vantage present in the base is missing from this PR's capture — see the REMOVED lines"
fi
# A frame that produced no measurement is UNMEASURED, and until now
# nothing said so above the fold: the per-frame lines sit inside a
# 25-row table under a PASS verdict, and the only grep here was the
# one above. Measured on #455 — 6 of 25 frames carried no comparison
# and the job raised no annotation about them.
#
# Covers both classes, since the consequence is the same and a reader
# cannot act on the difference: a frame the base never produced, and a
# pair that exists but could not be read or was refused. frame_diff
# emits the marker only when that set is non-empty, so a fully-compared
# run stays quiet — which is what keeps this warning meaningful rather
# than a permanent fixture of every visual PR.
if grep -q "UNCOMPARED:" diff.log; then
  echo "::warning::some captured frames carry no base comparison and are NOT evidence for this PR — see the UNCOMPARED line"
fi
