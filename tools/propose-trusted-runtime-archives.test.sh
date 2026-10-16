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
chmod +x "$fixture/tools/build-trusted-regression-runtime.sh" "$state/bin/go"
proposal_root="$(cd "$fixture" && pwd -P)"
export PATH="$state/bin:$PATH" PROPOSAL_TRACE="$state/trace" PROPOSAL_ROOT="$proposal_root"
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

for failure in build duplicate; do
  destination="$state/out/$failure"
  if PROPOSAL_FAILURE="$failure" bash "$fixture/tools/propose-trusted-runtime-archives.sh" "$destination" > "$state/stdout" 2> "$state/stderr"; then
    echo "accepted $failure proposal evidence" >&2; exit 1
  fi
  [ ! -e "$destination" ]
done
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
  and .env == {GODOT_VERSION:"4.7.1",GODOT_SHA512:"4ccdab7a48eeccbe8819a2fc1f6262f8d72065d98601bcb3743fcbd7ebd39f373758a788ee3293a05ec5b2c48538266c437404312e372225cd2df273945a2de9"}
  and (.jobs | keys) == ["propose"]
  and (.jobs.propose |
    keys == ["name","runs-on","steps","timeout-minutes"]
    and .name == "Disposable archive proposal"
    and ."runs-on" == "ubuntu-latest"
    and ."timeout-minutes" == 30
    and (.steps | length) == 6
    and .steps[0] == {name:"Harden runner",uses:"step-security/harden-runner@ccd8616d44fd3846e67624a50d5aad6d37bf2d25",with:{"egress-policy":"audit"}}
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
