#!/usr/bin/env bash
# Exercise the proposal extractor without Docker or network access.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd -P)"
state="$(mktemp -d)"
trap 'rm -rf "$state"' EXIT
fixture="$state/fixture"
mkdir -p "$fixture/tools/trusted-runtime-archives" "$state/bin" "$state/out"
cp "$root/tools/propose-trusted-runtime-archives.sh" "$fixture/tools/"
printf 'package main\n' > "$fixture/tools/trusted-runtime-archives/main.go"
cat > "$fixture/tools/build-trusted-regression-runtime.sh" <<'BUILD'
#!/usr/bin/env bash
set -euo pipefail
[ "$WAR_TRUSTED_RUNTIME_INVENTORY" = 1 ]
[ "$WAR_TRUSTED_RUNTIME_ARCHIVE_PROPOSAL" = 1 ]
printf 'build\n' >> "$PROPOSAL_TRACE"
[ "${PROPOSAL_FAILURE:-}" != build ] || exit 9
printf 'sha256:%064d\n' 1
printf 'TRUSTED_RUNTIME_ARCHIVE_PROPOSAL evidence-only=true\n' >&2
printf 'TRUSTED_RUNTIME_INVENTORY {"schema":1,"evidence":"proposal"}\n' >&2
[ "${PROPOSAL_FAILURE:-}" != duplicate ] || printf 'TRUSTED_RUNTIME_INVENTORY {}\n' >&2
BUILD
cat > "$state/bin/go" <<'GO'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$PROPOSAL_TRACE"
[ "$1" = run ] && [ "$3" = --from-report ]
[ -s "$4" ] && [ "$5" = "$PROPOSAL_ROOT" ]
printf '{"schema":1,"archives":[]}\n'
GO
cat > "$state/bin/docker" <<'DOCKER'
#!/usr/bin/env bash
set -euo pipefail
printf 'docker %s\n' "$*" >> "$PROPOSAL_TRACE"
[ "$#" -eq 3 ] && [ "$1 $2" = 'image rm' ] && [ "$3" = "$PROPOSAL_IMAGE" ]
[ "${PROPOSAL_FAILURE:-}" != cleanup ]
DOCKER
chmod +x "$fixture/tools/build-trusted-regression-runtime.sh" "$state/bin/go" "$state/bin/docker"
proposal_root="$(cd "$fixture" && pwd -P)"
proposal_image="$(printf 'sha256:%064d' 1)"
export PATH="$state/bin:$PATH" PROPOSAL_TRACE="$state/trace" PROPOSAL_ROOT="$proposal_root" PROPOSAL_IMAGE="$proposal_image"
if ! bash "$fixture/tools/propose-trusted-runtime-archives.sh" "$state/out/proposal" > "$state/stdout" 2> "$state/stderr"; then
  cat "$state/stderr" >&2
  exit 1
fi
grep -q '^TRUSTED_RUNTIME_ARCHIVE_PROPOSAL evidence-only=true$' "$state/stderr"
grep -qx "trusted runtime archive proposal written to $state/out/proposal" "$state/stdout"
grep -qx 'sha256:0000000000000000000000000000000000000000000000000000000000000001' "$state/out/proposal/source-image.txt"
grep -qx '{"schema":1,"evidence":"proposal"}' "$state/out/proposal/report.json"
grep -qx '{"schema":1,"archives":\[\]}' "$state/out/proposal/trusted-runtime-archives.lock.json"
[ "$(grep -c '^build$' "$state/trace")" -eq 1 ]
grep -qx "docker image rm $proposal_image" "$state/trace"

for failure in build duplicate; do
  : > "$state/trace"
  destination="$state/out/$failure"
  if PROPOSAL_FAILURE="$failure" bash "$fixture/tools/propose-trusted-runtime-archives.sh" "$destination" > "$state/stdout" 2> "$state/stderr"; then
    echo "accepted $failure proposal evidence" >&2; exit 1
  fi
  [ ! -e "$destination" ]
  case "$failure" in
    build) ! grep -q '^docker ' "$state/trace";;
    duplicate) grep -qx "docker image rm $proposal_image" "$state/trace";;
  esac
done
: > "$state/trace"
if PROPOSAL_FAILURE=cleanup bash "$fixture/tools/propose-trusted-runtime-archives.sh" "$state/out/cleanup" > "$state/stdout" 2> "$state/stderr"; then
  echo 'ignored proposal image cleanup failure' >&2; exit 1
fi
[ -d "$state/out/cleanup" ]
grep -qx "docker image rm $proposal_image" "$state/trace"
: > "$state/trace"
if bash "$fixture/tools/propose-trusted-runtime-archives.sh" "$state/out/proposal" >/dev/null 2>&1; then
  echo 'overwrote existing proposal evidence' >&2; exit 1
fi
[ ! -s "$state/trace" ]

yq -o=json '.' "$root/.github/workflows/propose-trusted-runtime-archives.yaml" > "$state/workflow.json"
if ! jq -e '
  keys == ["env","jobs","name","on","permissions"]
  and .name == "Propose trusted runtime archives"
  and .on == {workflow_dispatch:{inputs:{confirmation:{description:"Type PROPOSE to build disposable archive evidence",required:true,type:"string"}}}}
  and .permissions == {contents:"read"}
  and .env == {GODOT_VERSION:"4.7.2",GODOT_SHA512:"9aa00f7a605200940bce3027a567b782f49bd8e940dd06ae9e987bd65aee1b1467edd56ed84fcdcbdd44354bf613bdbb4e5d2913e925850368e150c59ed54c65"}
  and (.jobs | keys) == ["propose"]
  and (.jobs.propose |
    keys == ["name","runs-on","steps","timeout-minutes"]
    and .name == "Disposable archive proposal"
    and ."runs-on" == "ubuntu-latest"
    and ."timeout-minutes" == 30
    and (.steps | length) == 6
    and .steps[0] == {name:"Harden runner",uses:"step-security/harden-runner@dc2769abcc0fcfbadfc1df54081c1608579ef6b2",with:{"egress-policy":"audit"}}
    and .steps[1] == {uses:"actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1",with:{"fetch-depth":0,"persist-credentials":false}}
    and .steps[2] == {name:"Require an explicit maintenance selection",env:{CONFIRMATION:"${{ inputs.confirmation }}"},run:"test \"$CONFIRMATION\" = PROPOSE"}
    and .steps[3] == {name:"Install Godot (pinned, checksum-verified)",run:"bash tools/install-ci-godot.sh"}
    and .steps[4] == {name:"Build disposable evidence and generate the proposal",run:"bash tools/propose-trusted-runtime-archives.sh \"$RUNNER_TEMP/trusted-runtime-archive-proposal\""}
    and .steps[5] == {name:"Upload review evidence only",uses:"actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9",with:{name:"trusted-runtime-archive-proposal-${{ github.sha }}",path:"${{ runner.temp }}/trusted-runtime-archive-proposal","if-no-files-found":"error","retention-days":7}})
' "$state/workflow.json" >/dev/null; then
  echo 'archive proposal workflow widened beyond its manual read-only evidence boundary' >&2
  exit 1
fi
echo 'trusted runtime archive proposal extraction and refusal controls passed'
