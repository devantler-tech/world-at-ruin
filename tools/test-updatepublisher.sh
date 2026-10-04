#!/usr/bin/env bash
# Real command -> newly signed bytes -> native client verification.
set -euo pipefail
root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd -P)
probe=$(mktemp -d)
trap 'rm -rf -- "$probe"' EXIT
godot_bin=$(printenv GODOT_BIN || command -v godot)
at=2030-01-15T00:00:00Z
WAR_PUBLISHER_PROOF_DIR="$probe" go -C "$root/server" test -count=1 -timeout 90s ./internal/updatepublisher -run '^TestBundleAssemblyAndIndependentReadback$'
go -C "$root/server" build -o "$probe/publisher" ./cmd/updatepublisher
if "$probe/publisher" -operation canonicalize -input "$probe/build-facts.json" -output "$probe/default-off.json"; then
 echo 'experimental publisher ran without opt-in' >&2; exit 1
fi
test ! -e "$probe/default-off.json"
for kind in certificate revocation head; do
 "$probe/publisher" -experimental -operation issue -kind "$kind" -input "$probe/$kind-input.json" -private-key "$probe/root-private.pem" -observed-at "$at" -output "$probe/$kind.json"
done
"$probe/publisher" -experimental -operation issue -kind head -input "$probe/raised-head-input.json" -private-key "$probe/root-private.pem" -observed-at "$at" -output "$probe/raised-head.json"
"$probe/publisher" -experimental -operation assemble -input "$probe/build-facts.json" -certificate "$probe/certificate.json" -revocation "$probe/revocation.json" -head "$probe/head.json" -root-public-key "$probe/root-public.pem" -private-key "$probe/leaf-private.pem" -observed-at "$at" -output "$probe/manifest.json"
"$probe/publisher" -experimental -operation verify -input "$probe/manifest.json" -head "$probe/head.json" -root-public-key "$probe/root-public.pem" -observed-at "$at"
jq --slurpfile manifest "$probe/manifest.json" --slurpfile head "$probe/head.json" --slurpfile raised "$probe/raised-head.json" '.manifest=$manifest[0] | .head=$head[0] | .raised_head=$raised[0]' "$probe/chain.json" > "$probe/command-chain.json"
"$godot_bin" --headless --path "$root/client" --script "$root/tools/updatepublisher-client-probe.gd" -- "$probe/command-chain.json" > "$probe/godot.log" 2>&1
cat "$probe/godot.log"
grep -q 'TEST PASS' "$probe/godot.log"
if grep -qE 'SCRIPT ERROR|^ERROR' "$probe/godot.log"; then
 echo 'native publisher interoperability emitted an engine error' >&2; exit 1
fi
echo 'TEST PASS — offline commands and native client agree on the complete signed chain'
