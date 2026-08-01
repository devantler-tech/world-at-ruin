#!/usr/bin/env bash
# Admit wire changes only as an expand-first rollout. The head must retain every
# base protocol so either deployment order remains connected; contraction stays
# blocked until a later TTL/deployment-state gate can prove it safe.
set -euo pipefail

die() {
	printf '::error::%s\n' "$1" >&2
	exit 1
}

if [ -z "${BASE_SHA:-}" ]; then
	die 'BASE_SHA is unset — cannot verify the wire protocol rollout'
fi
if ! git cat-file -e "$BASE_SHA" 2>/dev/null; then
	die "base commit $BASE_SHA is not present in the checkout — cannot verify the wire protocol rollout"
fi

scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT

read_at() {
	local ref="$1" path="$2" out="$3"
	if ! git show "$ref:$path" >"$out" 2>/dev/null; then
		die "could not read $path at $ref — the rollout guard cannot compare an unknown base"
	fi
}

read_at "$BASE_SHA" client/scripts/wire_codec.gd "$scratch/base-client"
read_at "$BASE_SHA" server/wire/wire.go "$scratch/base-server"
cp client/scripts/wire_codec.gd "$scratch/head-client"
cp server/wire/wire.go "$scratch/head-server"

client_max() {
	awk '$1 == "const" && $2 == "VERSION" && $3 == ":=" { print $4 }' "$1"
}

client_min() {
	awk '$1 == "const" && $2 == "LEGACY_VERSION" && $3 == ":=" { print $4 }' "$1"
}

server_max() {
	awk '$1 == "const" && $2 == "Version" && $3 == "uint16" && $4 == "=" { print $5 }' "$1"
}

server_min() {
	awk '$1 == "const" && $2 == "LegacyVersion" && $3 == "uint16" && $4 == "=" { print $5 }' "$1"
}

validate_version() {
	local label="$1" value="$2"
	# A protocol constant is uint16. Validate its lexical domain before numeric
	# comparison so a hostile or malformed huge literal cannot overflow Bash.
	if [[ ! "$value" =~ ^[1-9][0-9]{0,4}$ ]] || [ "$value" -gt 65535 ]; then
		die "$label protocol version '$value' is not one positive uint16 literal"
	fi
}

bc_max="$(client_max "$scratch/base-client")"
bs_max="$(server_max "$scratch/base-server")"
hc_max="$(client_max "$scratch/head-client")"
hs_max="$(server_max "$scratch/head-server")"
validate_version 'base client maximum' "$bc_max"
validate_version 'base server maximum' "$bs_max"
validate_version 'head client maximum' "$hc_max"
validate_version 'head server maximum' "$hs_max"

bc_min="$(client_min "$scratch/base-client")"
bs_min="$(server_min "$scratch/base-server")"
hc_min="$(client_min "$scratch/head-client")"
hs_min="$(server_min "$scratch/head-server")"
hc_explicit=true
hs_explicit=true
if [ -z "$bc_min" ]; then bc_min="$bc_max"; fi
if [ -z "$bs_min" ]; then bs_min="$bs_max"; fi
if [ -z "$hc_min" ]; then hc_min="$hc_max"; hc_explicit=false; fi
if [ -z "$hs_min" ]; then hs_min="$hs_max"; hs_explicit=false; fi
validate_version 'base client minimum' "$bc_min"
validate_version 'base server minimum' "$bs_min"
validate_version 'head client minimum' "$hc_min"
validate_version 'head server minimum' "$hs_min"

if [ "$bc_min" -ne "$bs_min" ] || [ "$bc_max" -ne "$bs_max" ]; then
	die "base client range $bc_min..$bc_max differs from server range $bs_min..$bs_max — there is no coherent rollout anchor"
fi
if [ "$hc_min" -ne "$hs_min" ] || [ "$hc_max" -ne "$hs_max" ]; then
	die "client range $hc_min..$hc_max differs from server range $hs_min..$hs_max"
fi

if [ "$hc_max" -gt "$bc_max" ] && { [ "$hc_explicit" != true ] || [ "$hs_explicit" != true ]; }; then
	die "protocol $hc_max does not declare an explicit retained minimum on both tiers — a simultaneous bump would strand whichever population deploys second"
fi

# Raising the minimum is contraction. Its safe time depends on every manifest
# advertising the old range having expired, which a source diff cannot prove.
if [ "$hc_min" -gt "$bc_min" ]; then
	die "this change contracts the protocol minimum from $bc_min to $hc_min — contraction requires separate manifest-expiry and deployment-state evidence"
fi
if [ "$hc_max" -lt "$bc_max" ]; then
	die "this change removes protocol maximum $bc_max (head ends at $hc_max) — version retirement is a contraction, not an expansion"
fi

if [ "$hc_max" -gt "$bc_max" ]; then
	# Old server/new client and new server/old client must both have an overlap.
	if [ "$bs_max" -lt "$hc_min" ] || [ "$bs_max" -gt "$hc_max" ] ||
		[ "$bc_max" -lt "$hs_min" ] || [ "$bc_max" -gt "$hs_max" ]; then
		die "expanded range $hc_min..$hc_max does not retain base protocol $bc_max for both deployment orders"
	fi

	cd_file=.github/workflows/cd.yaml
	min_line="$(sed -n '/^[[:space:]]*WAR_MANIFEST_PROTOCOL_MIN=/p' "$cd_file")"
	max_line="$(sed -n '/^[[:space:]]*WAR_MANIFEST_PROTOCOL_MAX=/p' "$cd_file")"
	min_source="\$2 == \"LegacyVersion\""
	max_source="\$2 == \"Version\""
	if [ "$(printf '%s\n' "$min_line" | grep -c . || true)" -ne 1 ] ||
		[ "$(printf '%s\n' "$max_line" | grep -c . || true)" -ne 1 ] ||
		[[ "$min_line" != *'server/wire/wire.go'* ]] ||
		[[ "$min_line" != *"$min_source"* ]] ||
		[[ "$max_line" != *'server/wire/wire.go'* ]] ||
		[[ "$max_line" != *"$max_source"* ]]; then
		die 'cd.yaml does not publish the retained range from server/wire/wire.go — the manifest must not infer live compatibility from the client'
	fi

	printf 'Wire protocol expansion verified: %s..%s -> %s..%s; base protocol remains reachable in both deployment orders.\n' \
		"$bc_min" "$bc_max" "$hc_min" "$hc_max"
else
	printf 'Wire protocol range unchanged at %s..%s.\n' "$hc_min" "$hc_max"
fi
