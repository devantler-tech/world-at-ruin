#!/usr/bin/env bash
# Called within the builder's one existing image-inspection phase.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
image="${1:?local image required}"
state="${2:?private observation directory required}"
docker image inspect "$image" --format '[{"Id":{{json .Id}},"Os":{{json .Os}},"Architecture":{{json .Architecture}},"Config":{"User":{{json .Config.User}},"WorkingDir":{{json .Config.WorkingDir}},"Entrypoint":{{json .Config.Entrypoint}}}}]' > "$state/image.json"
# The fixed-format inspect is parsed before it can select an executor.
identity="$(jq -er 'if length==1 and .[0].Os=="linux" and .[0].Architecture=="amd64" and .[0].Config.User=="1001:1001" and .[0].Config.WorkingDir=="/project" and .[0].Config.Entrypoint==["/usr/local/bin/godot"] then .[0].Id else error("runtime contract") end' "$state/image.json")"
[[ "$identity" =~ ^sha256:[0-9a-f]{64}$ ]]
name="war-trusted-$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')"
[[ "$name" =~ ^war-trusted-[0-9a-f]{32}$ ]]
: > "$state/containers/$name"
# A failed producer remains failed even if it emitted plausible complete bytes.
docker run --rm --pull=never --network=none --read-only --cap-drop=ALL \
  --security-opt=no-new-privileges --user 1001:1001 --name "$name" \
  --entrypoint /bin/cat "$identity" /usr/share/war-trusted-runtime/inventory.tsv | head -c 1048577 > "$state/inventory.tsv"
bash "$root/tools/trusted-regression-phase.sh" --cleanup-containers "$state/containers"
go run "$root/tools/trusted-runtime-inventory/main.go" --experimental "$root" "$state/image.json" "$state/inventory.tsv" > "$state/report.json"
printf '%s\n' "$identity"
