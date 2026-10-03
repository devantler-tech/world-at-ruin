#!/usr/bin/env bash
# Exercise the exact GHCR latest-tag helper embedded in CD. The registry is a
# stateful local double: the helper still parses real manifest JSON with jq and
# its observable contract is the tag the registry exposes, not a mocked call.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
workflow="${repo_root}/.github/workflows/cd.yaml"

test_dir="$(mktemp -d)"
trap 'rm -rf "${test_dir}"' EXIT

helper_file="${test_dir}/ghcr-latest-forward-helper.sh"
sed -n \
  '/# BEGIN ghcr-latest-forward-helper/,/# END ghcr-latest-forward-helper/p' \
  "${workflow}" >"${helper_file}"
# shellcheck source=/dev/null
source "${helper_file}"
if ! declare -F advance_latest_tag >/dev/null; then
  echo "missing advance_latest_tag production helper in ${workflow}" >&2
  exit 1
fi

tags_file="${test_dir}/tags"
latest_file="${test_dir}/latest"
calls_file="${test_dir}/calls"
repo_tags_rc=0
publish_newer_after_first_tag=""
manifest_json_override=""
manifest_fetch_error=""
descriptor_rc=0
descriptor_override=""
signature_verify_rc=0
selected_annotation_override=""
tag_rc=0
alias_changes_after_resolve=0
incomplete_version=""
completion_fault=""
latest_digest_override=""
preserve_latest_digest_override_on_tag=0

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

reset_registry() {
  : >"${tags_file}"
  : >"${latest_file}"
  : >"${calls_file}"
  repo_tags_rc=0
  publish_newer_after_first_tag=""
  manifest_json_override=""
  manifest_fetch_error=""
  descriptor_rc=0
  descriptor_override=""
  signature_verify_rc=0
  selected_annotation_override=""
  tag_rc=0
  alias_changes_after_resolve=0
  incomplete_version=""
  completion_fault=""
  latest_digest_override=""
  preserve_latest_digest_override_on_tag=0
}

set_tags() {
  printf '%s\n' "$@" >"${tags_file}"
}

set_latest() {
  printf '%s\n' "$1" >"${latest_file}"
}

latest() {
  local value=""
  if [ -s "${latest_file}" ]; then
    read -r value <"${latest_file}"
  fi
  printf '%s\n' "${value}"
}

tag_calls() {
  grep -c '^tag ' "${calls_file}" || true
}

# Stateful stand-in for the registry boundary. It mirrors the three ORAS
# commands the production helper uses and changes the visible latest tag on a
# real tag operation.
oras() {
  printf '%s\n' "$*" >>"${calls_file}"
  if [ "$1" = repo ] && [ "$2" = tags ]; then
    cat "${tags_file}"
    while IFS= read -r version; do
      [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || continue
      [ "$version" = "$incomplete_version" ] || printf 'completed-%s\n' "$version"
    done <"${tags_file}"
    return "${repo_tags_rc}"
  fi
  if [ "$1" = manifest ] && [ "$2" = fetch ]; then
    if [ "${3:-}" = --descriptor ]; then
      if [ -n "${descriptor_override}" ]; then
        printf '%s\n' "${descriptor_override}"
      else
        case "${4##*:}" in
        latest)
          if [ -n "${manifest_fetch_error}" ]; then
            printf "%s\n" "${manifest_fetch_error}" >&2
            return 1
          fi
          if [ -n "${latest_digest_override}" ]; then
            printf '{"digest":"%s"}\n' "${latest_digest_override}"
          elif [ "$(latest)" = 0.79.0 ]; then
            printf '{"digest":"sha256:%064d"}\n' 79
          elif [ "$(latest)" = 0.80.0 ]; then
            printf '{"digest":"sha256:%064d"}\n' 80
          elif [ -z "$(latest)" ]; then
            echo 'manifest unknown' >&2
            return 1
          else printf '{"digest":"sha256:%064d"}\n' 81; fi
          ;;
        completed-0.79.0) printf '{"digest":"sha256:%064d"}\n' 79 ;;
        completed-0.80.0) printf '{"digest":"sha256:%064d"}\n' 80 ;;
        *) return 2 ;;
        esac
      fi
      return "${descriptor_rc}"
    fi
    if [[ "${3:-}" == *@sha256:* ]]; then
      if [ -n "${manifest_json_override}" ]; then
        printf "%s\n" "${manifest_json_override}"
        return 0
      fi
      local release
      case "${3##*@sha256:}" in
      0000000000000000000000000000000000000000000000000000000000000079) release=0.79.0 ;;
      0000000000000000000000000000000000000000000000000000000000000080) release=0.80.0 ;;
      0000000000000000000000000000000000000000000000000000000000000081) release="$(latest)" ;;
      *) return 2 ;;
      esac
      [ -z "${selected_annotation_override}" ] || release="${selected_annotation_override}"
      jq -n --arg version "$release" '{annotations:{"org.opencontainers.image.version":$version,"org.opencontainers.image.revision":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},layers:[{mediaType:"application/zip",digest:("sha256:"+("b"*64)),annotations:{"org.opencontainers.image.title":("WorldAtRuin-"+$version+"-macOS-universal.zip")}},{mediaType:"application/vnd.devantler.worldatruin.client.manifest.v1+json",digest:("sha256:"+("c"*64)),annotations:{"org.opencontainers.image.title":"update-manifest.json"}}]}'
      return 0
    fi
    [[ "${3:-}" == *:latest ]] || return 2
    if [ -n "${manifest_fetch_error}" ]; then
      printf '%s\n' "${manifest_fetch_error}" >&2
      return 1
    fi
    if [ -n "${manifest_json_override}" ]; then
      printf '%s\n' "${manifest_json_override}"
      return 0
    fi
    local current
    current="$(latest)"
    if [ -z "${current}" ]; then
      echo "Error response from registry: manifest unknown: latest is not found" >&2
      return 1
    fi
    printf '{"annotations":{"org.opencontainers.image.version":"%s"}}\n' "${current}"
    return 0
  fi
  if [ "$1" = tag ]; then
    [ "${tag_rc}" -eq 0 ] || return "${tag_rc}"
    local source="$2" version
    case "${source}" in
    *@sha256:0000000000000000000000000000000000000000000000000000000000000079) version=0.79.0 ;;
    *@sha256:0000000000000000000000000000000000000000000000000000000000000080) version=0.80.0 ;;
    *:0.80.0)
      version=0.80.0
      [ "${alias_changes_after_resolve}" -eq 0 ] || version=0.79.0
      ;;
    *:0.79.0) version=0.79.0 ;;
    *) return 2 ;;
    esac
    [ "$3" = latest ] || return 2
    set_latest "${version}"
    if [ "$preserve_latest_digest_override_on_tag" -eq 0 ]; then latest_digest_override=""; fi
    if [ -n "${publish_newer_after_first_tag}" ]; then
      printf '%s\n' "${publish_newer_after_first_tag}" >>"${tags_file}"
      publish_newer_after_first_tag=""
    fi
    return 0
  fi
  return 2
}

cosign() {
  printf 'cosign %s\n' "$*" >>"${calls_file}"
  [ "${signature_verify_rc}" -eq 0 ] || return "${signature_verify_rc}"
  if [ "$1" = verify-attestation ]; then
    local release=0.80.0
    [[ "$2" != *@sha256:*79 ]] || release=0.79.0
    [ "$completion_fault" != forged ] || return 1
    local statement
    statement=$(jq -n --arg artifact "$artifact" --arg digest "${2##*@}" --arg version "$release" --arg fault "$completion_fault" '
          {predicateType:"https://devantler.tech/world-at-ruin/release-completion/v1",subject:[{name:$artifact,digest:{sha256:($digest|ltrimstr("sha256:"))}}],predicate:{schema:1,version:$version,artifact_digest:$digest,revision:("a"*40),archive_sha256:("b"*64),manifest_sha256:("c"*64)}} |
          if $fault == "subject" then .subject[0].digest.sha256=("d"*64)
          elif $fault == "archive" then .predicate.archive_sha256=("d"*64)
          elif $fault == "manifest" then .predicate.manifest_sha256=("d"*64)
          elif $fault == "version" then .predicate.version="9.9.9"
          elif $fault == "revision" then .predicate.revision=("d"*40)
          elif $fault == "type" then .predicateType="https://invalid.example/type"
          elif $fault == "unknown" then .predicate.unchecked=true
          else . end')
    jq -n --arg payload "$(printf '%s' "$statement" | base64 | tr -d '\n')" '{payload:$payload}'
    if [ "$completion_fault" = ambiguous ]; then
      jq -n --arg payload "$(printf '%s' "$statement" | jq '.predicate.revision="bad"' | base64 | tr -d '\n')" '{payload:$payload}'
    fi
  fi
}

export GITHUB_SERVER_URL=https://github.com GITHUB_REPOSITORY=devantler-tech/world-at-ruin
artifact="ghcr.io/devantler-tech/world-at-ruin/client"

# A first publication establishes latest.
reset_registry
set_tags "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.80.0")" ||
  fail "first publication did not establish latest"
[ "$(latest)" = "0.80.0" ] || fail "first publication exposed $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 1 ] || fail "first publication should tag exactly once"
[[ "${out}" == *"advanced latest to 0.80.0"* ]] ||
  fail "first publication did not report the version it exposed"

# An older overlapping run may not move latest backwards.
reset_registry
set_tags "0.79.0" "0.80.0" "latest"
set_latest "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
  fail "older publication failed instead of preserving the newer latest"
[ "$(latest)" = "0.80.0" ] || fail "older publication moved latest back to $(latest)"
[ "$(tag_calls)" -eq 0 ] || fail "older publication issued a tag write"
[[ "${out}" == *"left latest at newer 0.80.0"* ]] ||
  fail "older publication did not say why it left latest untouched"

# A newer latest remains a monotonic floor even if its immutable tag catalogue
# entry is temporarily invisible. Retagging from the partial catalogue would
# turn a read defect into a real rollback.
reset_registry
set_tags "0.79.0"
set_latest "0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
  fail "newer latest without a visible bare tag was not preserved"
[ "$(latest)" = "0.80.0" ] ||
  fail "partial catalogue moved latest back to $(latest)"
[ "$(tag_calls)" -eq 0 ] ||
  fail "partial catalogue issued a backward tag write"

# A present but malformed latest annotation cannot be ordered, so the helper
# must fail closed rather than guessing that the immutable catalogue is newer.
reset_registry
set_tags "0.80.0"
set_latest "not-a-version"
if advance_latest_tag "${artifact}" "0.80.0" >/dev/null 2>&1; then
  fail "a malformed current latest version was treated as safe to replace"
fi
[ "$(tag_calls)" -eq 0 ] ||
  fail "malformed current latest still issued a tag write"
[ "$(latest)" = "not-a-version" ] ||
  fail "malformed current latest was replaced"

# A present latest tag with an unreadable manifest is not the first-publication
# case. It must fail closed rather than treating parser failure as absence.
reset_registry
set_tags "0.79.0"
set_latest "0.80.0"
manifest_json_override='{"annotations":'
if advance_latest_tag "${artifact}" "0.79.0" >/dev/null 2>&1; then
  fail "an unreadable latest manifest was treated as an absent tag"
fi
[ "$(tag_calls)" -eq 0 ] ||
  fail "unreadable latest manifest still issued a tag write"
[ "$(latest)" = "0.80.0" ] ||
  fail "unreadable latest manifest changed latest"

# A partial catalogue plus a transient fetch failure is unknown state. Only the
# registry's positive MANIFEST_UNKNOWN response may establish first publication.
reset_registry
set_tags "0.79.0"
set_latest "0.80.0"
manifest_fetch_error="dial tcp: transient registry read failure"
if advance_latest_tag "${artifact}" "0.79.0" >/dev/null 2>&1; then
  fail "a transient latest fetch failure was treated as first publication"
fi
[ "$(tag_calls)" -eq 0 ] ||
  fail "transient latest fetch failure still issued a tag write"
[ "$(latest)" = "0.80.0" ] ||
  fail "transient latest fetch failure changed latest"

# A newer publication advances latest.
reset_registry
set_tags "0.79.0" "0.80.0" "latest"
set_latest "0.79.0"
out="$(advance_latest_tag "${artifact}" "0.80.0")" ||
  fail "newer publication did not advance latest"
[ "$(latest)" = "0.80.0" ] || fail "newer publication exposed $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 1 ] || fail "newer publication should tag exactly once"
grep -qF "tag ${artifact}@sha256:0000000000000000000000000000000000000000000000000000000000000080 latest" "${calls_file}" ||
  fail "the newer publication did not tag the newest immutable version"

# A newer immutable version that appears while an older run is tagging must be
# noticed on the verification pass and become the converged latest value.
reset_registry
set_tags "0.79.0"
publish_newer_after_first_tag="0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" ||
  fail "overlap convergence failed"
[ "$(latest)" = "0.80.0" ] ||
  fail "overlap convergence left latest at $(latest), want 0.80.0"
[ "$(tag_calls)" -eq 2 ] ||
  fail "overlap convergence should write the old candidate then repair to the new one"
grep -qF "tag ${artifact}@sha256:0000000000000000000000000000000000000000000000000000000000000080 latest" "${calls_file}" ||
  fail "overlap convergence never repaired latest to the newly visible version"

# An unreadable tag catalogue is unknown state, never permission to retag.
reset_registry
set_tags "0.80.0"
repo_tags_rc=1
if advance_latest_tag "${artifact}" "0.80.0" >/dev/null 2>&1; then
  fail "an unreadable tag catalogue was treated as safe to mutate"
fi
[ "$(tag_calls)" -eq 0 ] || fail "catalogue failure still issued a tag write"
[ -z "$(latest)" ] || fail "catalogue failure changed latest"

# An unsigned newer catalogue artifact must never replace the checked latest.
reset_registry
set_tags "0.79.0" "0.80.0"
set_latest "0.79.0"
signature_verify_rc=1
if advance_latest_tag "${artifact}" "0.79.0" >/dev/null 2>&1; then
  fail "unverified catalogue artifact was promoted"
fi
[ "$(tag_calls)" -eq 0 ] || fail "unverified catalogue artifact issued a latest write"
[ "$(latest)" = 0.79.0 ] || fail "unverified catalogue artifact changed latest"

# Unreadable/malformed descriptors and a signed object whose version differs
# from the catalogue name are all refusals, not permission to publish.
for failure in descriptor malformed annotation; do
  reset_registry
  set_tags "0.79.0" "0.80.0"
  set_latest "0.79.0"
  case "${failure}" in
  descriptor) descriptor_rc=1 ;;
  malformed) descriptor_override='{"digest":"not-a-digest"}' ;;
  annotation) selected_annotation_override=0.79.0 ;;
  esac
  if advance_latest_tag "${artifact}" "0.80.0" >/dev/null 2>&1; then
    fail "${failure} failure still promoted the catalogue artifact"
  fi
  [ "$(tag_calls)" -eq 0 ] || fail "${failure} failure issued a latest write"
  [ "$(latest)" = 0.79.0 ] || fail "${failure} failure changed latest"
done

# A version alias can move after resolution; only its verified digest may be
# promoted, so the replacement alias cannot become latest.
reset_registry
set_tags "0.79.0" "0.80.0"
set_latest "0.79.0"
alias_changes_after_resolve=1
advance_latest_tag "${artifact}" 0.80.0 >/dev/null ||
  fail "a version-alias change defeated digest promotion"
[ "$(latest)" = 0.80.0 ] || fail "replacement version alias became latest"
grep -qF "cosign verify ${artifact}@sha256:0000000000000000000000000000000000000000000000000000000000000080" "${calls_file}" ||
  fail "the selected digest was not signature-verified"
if grep '^tag ' "${calls_file}" | grep -qv '@sha256:'; then
  fail "promotion re-resolved a mutable version alias"
fi

reset_registry
set_tags "0.80.0"
set_latest "0.79.0"
tag_rc=1
if advance_latest_tag "${artifact}" 0.80.0 >/dev/null 2>&1; then
  fail "a rejected registry write reported successful convergence"
fi
[ "$(latest)" = 0.79.0 ] || fail "rejected registry write changed latest"

echo "ok"

# A signature does not certify that readback finished. Staging releases stay out.
reset_registry
set_tags "0.79.0" "0.80.0"
incomplete_version="0.80.0"
out="$(advance_latest_tag "${artifact}" "0.79.0")" || fail "completed older release failed"
[ "$(latest)" = "0.79.0" ] || fail "signed staging release replaced completed release"

for fault in forged subject archive manifest version revision type unknown ambiguous; do
  reset_registry
  set_tags "0.80.0"
  completion_fault="$fault"
  if advance_latest_tag "$artifact" 0.80.0 >/dev/null 2>&1; then fail "$fault completion was accepted"; fi
  [ "$(tag_calls)" -eq 0 ] || fail "$fault completion changed latest"
done
echo 'ok -- staging, forged and mismatched completion records preserve latest'

# Equal version strings do not authenticate an incomplete prior digest.
reset_registry
set_tags "0.80.0"
set_latest "0.80.0"
latest_digest_override="sha256:0000000000000000000000000000000000000000000000000000000000000081"
advance_latest_tag "$artifact" 0.80.0 >/dev/null || fail "same-version recovery failed"
[ "$(tag_calls)" -eq 1 ] || fail "same-version unchecked digest survived recovery"
[ -z "$latest_digest_override" ] || fail "same-version recovery did not replace the prior digest"

reset_registry
set_tags "0.80.0"
set_latest "0.80.0"
completion_fault=forged
if advance_latest_tag "$artifact" 0.80.0 >/dev/null 2>&1; then fail "same-version forged completion was accepted"; fi
[ "$(tag_calls)" -eq 0 ] || fail "same-version invalid completion mutated latest"
echo 'ok -- same-version recovery authenticates and compares digests'

# A registry that never exposes the written digest must exhaust retries as a failure.
reset_registry
set_tags "0.80.0"
set_latest "0.80.0"
latest_digest_override="sha256:0000000000000000000000000000000000000000000000000000000000000081"
preserve_latest_digest_override_on_tag=1
if advance_latest_tag "$artifact" 0.80.0 >/dev/null 2>&1; then fail "retry exhaustion falsely reported digest convergence"; fi
[ "$(tag_calls)" -eq 5 ] || fail "nonconverging digest did not honor the bounded retry limit"
echo "ok -- bounded retry exhaustion rejects an unchecked same-version digest"
