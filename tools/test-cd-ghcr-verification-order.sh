#!/usr/bin/env bash
# Execute the release workflow's real publication steps with a stateful registry
# boundary. Signing and downloaded bytes fail independently; neither may expose
# the candidate through latest.
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"
test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT
mkdir -p "${test_dir}/bin" "${test_dir}/fixture"
printf 'checked release zip\n' >"${test_dir}/fixture/WorldAtRuin-0.80.0-macOS-universal.zip"
printf '{"version":"0.80.0"}\n' >"${test_dir}/fixture/update-manifest.json"

# extract_step — Extract the named production step without replacing its shell logic.
extract_step() {
  awk -v title="      - name: $1" '
		$0 == title { inside = 1; next }
		inside && /^      - name:/ { exit }
		inside && /^        run: \|$/ { body = 1; next }
		inside && body && /^    [^ ]/ { exit }
		inside && body { sub(/^          /, ""); print }
	' "${workflow}" >"${test_dir}/$2"
}

extract_step "📦 Push the OCI artifact" push.sh
extract_step "🔏 Sign the artifact by digest" sign.sh
extract_step "✅ Verify signature and byte-identity" verify.sh
extract_step "🧾 Attest completed release verification" complete.sh
extract_step "🏷️ Advance the verified latest digest" latest.sh
for step in push sign verify complete; do
  [ -s "${test_dir}/${step}.sh" ] || {
    echo "missing CD step: ${step}" >&2
    exit 1
  }
done

cat >"${test_dir}/bin/cosign" <<'COMMAND'
#!/usr/bin/env bash
set -euo pipefail
printf 'cosign %s\n' "$*" >>"${WAR_REGISTRY_CALLS}"
case "$1" in
	attest) [ "${WAR_ATTEST_RC:-0}" -eq 0 ] || exit "$WAR_ATTEST_RC"; cp release-completion.json "${WAR_COMPLETION}" ;;
	verify-attestation)
		statement=$(jq -n --arg artifact "$ARTIFACT" --arg digest "$DIGEST" --slurpfile predicate "$WAR_COMPLETION" '{predicateType:"https://devantler.tech/world-at-ruin/release-completion/v1",subject:[{name:$artifact,digest:{sha256:($digest|ltrimstr("sha256:"))}}],predicate:$predicate[0]}')
		jq -n --arg payload "$(printf '%s' "$statement" | base64 | tr -d '\n')" '{payload:$payload}'
		;;
	sign) exit "${WAR_SIGN_RC}" ;;
	verify) exit "${WAR_VERIFY_RC}" ;;
	*) exit 2 ;;
esac
COMMAND

cat >"${test_dir}/bin/oras" <<'COMMAND'
#!/usr/bin/env bash
set -euo pipefail
printf 'oras %s\n' "$*" >>"${WAR_REGISTRY_CALLS}"
case "$1 $2" in
	"repo tags") printf '0.79.0\n0.80.0\nlatest\n'; [ ! -f "$WAR_COMPLETION" ] || printf 'completed-0.80.0\n' ;;
	"manifest fetch")
		if [ "${3:-}" = "--descriptor" ]; then
			if [[ "$4" == *:latest ]] && [ "$(cat "$WAR_LATEST")" != "$VERSION" ]; then
        printf '{"digest":"sha256:%064d"}\n' 2
      else printf '{"digest":"sha256:%064d"}\n' 1; fi
		elif [[ "${3:-}" == *@sha256:*2 ]]; then
      printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "$(cat "$WAR_LATEST")"
    elif [[ "${3:-}" == *@sha256:* ]]; then
			jq -n --arg version "$VERSION" --arg revision "$(cat "$WAR_FIXTURE/pushed-revision")" --arg archive "$(sha256sum "$WAR_FIXTURE/WorldAtRuin-0.80.0-macOS-universal.zip" | cut -d' ' -f1)" --arg manifest "$(sha256sum "$WAR_FIXTURE/update-manifest.json" | cut -d' ' -f1)" '{annotations:{"org.opencontainers.image.version":$version,"org.opencontainers.image.revision":$revision},layers:[{mediaType:"application/zip",digest:("sha256:"+$archive),annotations:{"org.opencontainers.image.title":("WorldAtRuin-"+$version+"-macOS-universal.zip")}},{mediaType:"application/vnd.devantler.worldatruin.client.manifest.v1+json",digest:("sha256:"+$manifest),annotations:{"org.opencontainers.image.title":"update-manifest.json"}}]}'
		else
			printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "$(cat "${WAR_LATEST}")"
		fi
		;;
	"tag "*)
		[ "$3" != completed-0.80.0 ] || exit 0
		[ "$3" = latest ] || exit 2
		printf '0.80.0\n' >"${WAR_LATEST}"
		;;
	"push "*)
    shift 2
    while [ "$#" -gt 0 ]; do
      if [ "$1" = --annotation ] && [[ "$2" == org.opencontainers.image.revision=* ]]; then
        printf '%s\n' "${2#*=}" > "$WAR_FIXTURE/pushed-revision"
      fi
      shift
    done ;;

	"pull "*)
		cp "${WAR_FIXTURE}/WorldAtRuin-0.80.0-macOS-universal.zip" .
		cp "${WAR_FIXTURE}/update-manifest.json" .
		case "${WAR_CORRUPT}" in
			zip) printf 'corrupt\n' >>WorldAtRuin-0.80.0-macOS-universal.zip ;;
			manifest) printf 'corrupt\n' >>update-manifest.json ;;
			none) ;;
			*) exit 2 ;;
		esac
		;;
	*) exit 2 ;;
esac
COMMAND
chmod +x "${test_dir}/bin/"*

export PATH="${test_dir}/bin:${PATH}"
export GITHUB_SERVER_URL=https://github.com
export GITHUB_REPOSITORY=devantler-tech/world-at-ruin
export GITHUB_SHA=eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee
export REVISION=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
export VERSION=0.80.0 TAG=v0.80.0
export WAR_COMPLETION="${test_dir}/completion.json"
export WAR_REGISTRY_CALLS="${test_dir}/calls"
export WAR_LATEST="${test_dir}/latest"
export WAR_FIXTURE="${test_dir}/fixture"
export GITHUB_OUTPUT="${test_dir}/output"

# prepare_case — Reset artifact bytes and registry state for one publication scenario.
prepare_case() {
  rm -rf "${test_dir}/run"
  mkdir -p "${test_dir}/run/oci"
  cp "${WAR_FIXTURE}/"* "${test_dir}/run/oci/"
  (cd "${test_dir}/run/oci" && sha256sum WorldAtRuin-0.80.0-macOS-universal.zip) >"${test_dir}/run/release-asset.sha256"
  (cd "${test_dir}/run/oci" && sha256sum update-manifest.json) >"${test_dir}/run/manifest.sha256"
  printf '0.79.0\n' >"${WAR_LATEST}"
  rm -f "$WAR_COMPLETION"
  : >"${WAR_REGISTRY_CALLS}"
  : >"${GITHUB_OUTPUT}"
}

# run_publication — Execute production publication steps against isolated boundary doubles.
run_publication() {
  (
    cd "${test_dir}/run"
    bash -e "${test_dir}/push.sh" || exit 1
    ARTIFACT="$(sed -n 's/^artifact=//p' "${GITHUB_OUTPUT}")"
    DIGEST="$(sed -n 's/^digest=//p' "${GITHUB_OUTPUT}")"
    export ARTIFACT DIGEST
    bash -e "${test_dir}/sign.sh" || exit 1
    bash -e "${test_dir}/verify.sh" || exit 1
    bash -e "${test_dir}/complete.sh" || exit 1
    if [ -s "${test_dir}/latest.sh" ]; then
      export RELEASE_ARTIFACT="${ARTIFACT}" RELEASE_VERSION="${VERSION}"
      bash -e "${test_dir}/latest.sh" || exit 1
    fi
  )
}

# fail — Report an ordering or readback contract violation.
fail() {
  echo "FAIL: $*" >&2
  exit 1
}
for failure in sign verify zip manifest attest; do
  prepare_case
  export WAR_SIGN_RC=0 WAR_VERIFY_RC=0 WAR_CORRUPT=none WAR_ATTEST_RC=0
  case "${failure}" in
  sign) WAR_SIGN_RC=1 ;;
  verify) WAR_VERIFY_RC=1 ;;
  attest) WAR_ATTEST_RC=1 ;;
  zip | manifest) WAR_CORRUPT="${failure}" ;;
  esac
  if run_publication >"${test_dir}/log" 2>&1; then
    fail "${failure} failure was reported as a successful publication"
  fi
  if [ "$(cat "${WAR_LATEST}")" != 0.79.0 ] || grep -q '^oras tag ' "${WAR_REGISTRY_CALLS}"; then
    fail "${failure} failure exposed the unchecked candidate through latest"
  fi
done

prepare_case
export WAR_SIGN_RC=0 WAR_VERIFY_RC=0 WAR_CORRUPT=none WAR_ATTEST_RC=0
run_publication >"${test_dir}/log" 2>&1 || {
  cat "${test_dir}/log"
  fail "verified publication failed"
}
[ "$(cat "${WAR_LATEST}")" = 0.80.0 ] || fail "verified candidate did not become latest"
# Every latest write needs prior signature and completion verification for its digest.
awk '
  /^cosign verify / { signatures[$3] = 1 }
  /^cosign verify-attestation / { completed[$3] = 1 }
  /^oras tag / && $NF == "latest" {
    if (!signatures[$3] || !completed[$3]) { invalid = 1; exit 1 }
    writes++
  }
  END { if (invalid || writes < 1) exit 1 }
' "${WAR_REGISTRY_CALLS}" || fail "latest write preceded verification of its digest"
echo "ok -- failed signing and readback preserve latest"
