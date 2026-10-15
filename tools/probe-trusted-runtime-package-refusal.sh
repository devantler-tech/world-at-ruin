#!/usr/bin/env bash
# Runs within the caller's existing inspection phase and owned-container cleanup.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
image="${1:?image required}" state="${2:?private directory required}"
[[ "$image" =~ ^sha256:[0-9a-f]{64}$ ]]
mkdir "$state/package-refusal"
chmod 0755 "$state/package-refusal"
go run "$root/tools/trusted-runtime-packages/main.go" --emit "$root" > "$state/package-refusal/expected.tsv"
awk 'BEGIN{FS=OFS="\t"} NR==1{$3="0-refusal-control"} {print}' "$state/package-refusal/expected.tsv" > "$state/package-refusal/wrong.tsv"
cp "$root/tools/verify-trusted-runtime-packages.sh" "$state/package-refusal/verify.sh"
chmod 0644 "$state/package-refusal/"*
name="war-trusted-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$name" =~ ^war-trusted-[0-9a-f]{32}$ ]]
: > "$state/containers/$name"
status=0
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --user 1001:1001 --name "$name" \
  --tmpfs /tmp:rw,nosuid,nodev,noexec,size=4m,mode=1777 \
  --mount "type=bind,src=$state/package-refusal,dst=/package-refusal,readonly" \
  --entrypoint /bin/bash "$image" /package-refusal/verify.sh /package-refusal/wrong.tsv > "$state/package-refusal/result" 2>&1 || status=$?
[ "$status" -eq 1 ]
grep -qx 'trusted runtime installed package identities differ from the reviewed lock' "$state/package-refusal/result"
bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$state/containers"
echo 'TEST PASS -- real runtime refuses changed package expectation and owned container absence is verified'
