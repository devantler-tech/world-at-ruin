#!/usr/bin/env bash
set -euo pipefail
cd "$SOURCE_EVIDENCE_DIR/logs"
set -o pipefail
# FAIL CLOSED on an unknown verdict. main.gd prints this line through
# Volumetrics.marker() and volumetrics_test pins its shape, so a drift
# that breaks this parse fails the unit test first — but if the print
# is removed outright, the degradation would become UNKNOWABLE rather
# than merely invisible, and a green capture would go straight back to
# reading as volumetric evidence. Unknown is a failure, not a default.
# Read each gated feature's verdict, and fail closed on ANYTHING
# ambiguous. `head -1` on a multi-verdict log is not a tiebreak, it is
# a coin toss that silently suppresses the warning — so require
# exactly one DISTINCT verdict per marker rather than taking the
# first. (A boundary alone stops "VOLUMETRICS onward …" from matching;
# it does not stop two genuine contradictory markers.)
read_verdict() {
  marker="$1"
  log="$2"
  distinct="$(grep -oE "^${marker} (on|off)([[:space:]]|\$)" "$log" |
    sed -E "s/^${marker} //; s/[[:space:]]*\$//" | sort -u)"
  # `|| true`: grep -c exits 1 on a zero count, and under `bash -e` a
  # failing command substitution in an assignment kills the step —
  # which would bypass the explicit no-verdict error below.
  n="$(printf '%s\n' "$distinct" | grep -c . || true)"
  if [ "$n" -eq 0 ]; then
    echo "::error::no ${marker} verdict in ${log} — cannot tell what these frames depict (see the marker() helper and its pinning test)" >&2
    return 1
  fi
  if [ "$n" -gt 1 ]; then
    echo "::error::contradictory ${marker} verdicts in ${log} ($(printf '%s' "$distinct" | tr '\n' '/')) — refusing to guess which one the frames depict" >&2
    return 1
  fi
  printf '%s' "$distinct"
}
probe="$(read_verdict VOLUMETRICS capture.log)" || exit 1
pools="$(read_verdict 'HOLLOW FOG' capture.log)" || exit 1
# #325. The world frames carry no replicated entity — no zone is
# configured for them — and that fact now travels with the artifact
# instead of being something a reviewer has to know. Read through the
# same fail-closed parse: an absent verdict means the capture stopped
# printing it, which would put the artifact straight back to being
# silent about what it contains.
world_replication="$(read_verdict REPLICATION capture.log)" || exit 1
replication="$(read_verdict REPLICATION capture-replication.log)" || exit 1
mob_chase="$(read_verdict 'MOB CHASE' capture-mob-chase.log)" || exit 1
echo "volumetric fog path: ${probe}; hollow ash pools: ${pools}"
echo "replication — world frames: ${world_replication}; replication scenario: ${replication}"
echo "authoritative mob chase: ${mob_chase}"

# The replication scenario exists ONLY to publish frames containing a
# replicated population. An 'off' there is not a degraded runner or a
# missing GPU feature, as it is for the two verdicts above — it means
# the scenario photographed an empty table and would be publishing
# evidence of the exact absence it was built to end. Fail, loudly.
if [ "${replication}" != "on" ]; then
  echo "::error::the replication scenario reported REPLICATION ${replication} — its frames contain no replicated entity, which is the failure #325 exists to close" >&2
  exit 1
fi
if [ "${mob_chase}" != "on" ]; then
  echo "::error::the mob-chase scenario reported ${mob_chase} — its sequence cannot evidence the default chase" >&2
  exit 1
fi
# And the world frames must NOT claim a population: they are captured
# with no zone, so an 'on' here means the verdict is being printed
# from somewhere that does not know what the frames contain.
if [ "${world_replication}" != "off" ]; then
  echo "::error::the world capture reported REPLICATION ${world_replication} despite booting with no zone — the verdict does not track what the frames depict" >&2
  exit 1
fi

# Travels INSIDE the artifact, beside the PNGs, so a reviewer who
# downloads frames a week later still knows what they are looking at.
{
  echo "# Capture conditions"
  echo
  echo "runner: ${CAPTURE_RUNNER_OS} (hosted)"
  echo "volumetric_fog: ${probe}"
  echo "hollow_ash_pools: ${pools}"
  echo "replicated_entities_in_world_frames: ${world_replication}"
  echo "replicated_entities_in_replication_frames: ${replication}"
  echo "authoritative_mob_chase: ${mob_chase}"
  echo
  echo "Only the frames under replication/ and mob-chase/ contain replicated entities."
  echo "Every other frame here was captured with no zone configured, so"
  echo "its replica table is empty by construction and it evidences"
  echo "nothing about remote-entity appearance, interpolation or culling."
  if [ "${probe}" = "off" ]; then
    echo
    echo "These frames show the HEIGHT-FOG FALLBACK, not the volumetric"
    echo "path: this runner's GPU lacks R32_Uint atomic storage image"
    echo "support, so Godot's froxel volumetrics never initialise here."
    echo "Nothing in this artifact evidences a change to volumetric fog."
  fi
  if [ "${pools}" = "off" ]; then
    echo
    echo "This world contains ZERO ash pools. #233 retired the opt-in"
    echo "that used to gate them, so pools now build wherever the GPU"
    echo "probe passes — meaning this verdict normally follows the"
    echo "volumetric one above, and an 'off' here with the probe ON"
    echo "would instead mean no hollow was deep enough to qualify."
    echo "Nothing in this artifact evidences a change to the pools."
  fi
} >"${SOURCE_EVIDENCE_DIR}/shots/capture-conditions.txt"

{
  echo "### Frame capture conditions"
  echo
  echo "Volumetric fog path: **${probe}** · hollow ash pools: **${pools}**"
} >>"$GITHUB_STEP_SUMMARY"

# The case #232 is actually about: a PR changing probe-gated code,
# captured on a runner that cannot run it. Say so loudly rather than
# letting the green check imply coverage. Not a hard failure — the
# frames are still valid evidence for everything else in the diff, and
# blocking here would block the whole volumetric lane on a runner
# limitation. The obligation it raises is the one AGENTS.md already
# makes a P1 review blocker: attach a frame of the actual change.
# Keyed on what was ACTUALLY RENDERED, not on the GPU verdict alone.
# Pools need the probe AND the opt-in, so keying this on `probe` would
# go quiet — and imply the frames show the pools — the moment a
# capable runner arrives (the lavapipe lane, #314) while the capture
# still sets no opt-in. The condition has to track every gate that can
# empty the frame, or it decays into a claim the frames do not support.
# `if` blocks, NOT `[ … ] && var=…`: this step runs under `bash -e`,
# where a bare test-and-assign whose test is FALSE makes the list
# return non-zero and kills the step. The failure would land only on
# runs where the feature rendered correctly — the green path — so it
# would look like a flake in the capture rather than a shell bug.
# Each item carries its own "no", so the joined phrase reads correctly
# for one item AND for both: "no volumetric fog and no hollow ash
# pools", never "no volumetric fog and hollow ash pools" — which
# scans as though the pools WERE rendered.
missing=""
if [ "${probe}" = "off" ]; then
  missing="no volumetric fog"
fi
if [ "${pools}" = "off" ]; then
  missing="${missing:+${missing} and }no hollow ash pools"
fi
if [ "${GPU_GATED}" = "true" ] && [ -n "${missing}" ]; then
  echo "::warning::this PR touches gated rendering, but the capture rendered ${missing} — these frames CANNOT evidence that change. Attach a locally-rendered frame of the enabled path (AGENTS.md: a player-visible PR with no inspectable frame evidence is a P1 blocker)."
  {
    echo
    echo "> [!WARNING]"
    echo "> This PR touches gated rendering, but the captured frames"
    echo "> contain ${missing}. They cannot evidence that change."
    echo "> Attach a locally-rendered frame of the enabled path."
  } >>"$GITHUB_STEP_SUMMARY"
fi
