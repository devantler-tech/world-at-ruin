#!/usr/bin/env bash
# Controls for tools/server-dependents-tidy.sh and the workflow that runs it (#1654).
# `go` and `gh` are stubbed: the controls check which modules are tidied, what is committed,
# and that the scheduled workflow only hands its write token to the commit of tidied
# Dependabot server updates.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
script="$root/tools/server-dependents-tidy.sh"
workflow=${1:-$root/.github/workflows/dependabot-server-tidy.yaml}
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}

# Stub go: `go -C DIR mod tidy` appends a marker to DIR/go.mod, or fails when DIR is listed
# in STUB_GO_FAIL. Every call is logged.
mkdir -p "$work/bin"
cat >"$work/bin/go" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
[ "$1" = -C ] && [ "$3" = mod ] && [ "$4" = tidy ] || { echo "unexpected go call: $*" >&2; exit 2; }
echo "$2" >>"$STUB_LOG/go.calls"
if [ "${STUB_GO_FAIL:-}" = "$2" ]; then exit 1; fi
if [ "${STUB_GO_NOOP:-}" != 1 ] && [ ! -e NOOP ]; then printf '// tidied\n' >>"$2/go.mod"; printf 'sum\n' >>"$2/go.sum"; fi
STUB
cat >"$work/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [ "$1" = pr ]; then echo "$*" >"$STUB_LOG/gh.list-args"; cat "$STUB_LOG/prs.json"; exit 0; fi
cat >"$STUB_LOG/gh.request"
cat "$STUB_LOG/gh.request" >>"$STUB_LOG/gh.requests"
echo "$*" >"$STUB_LOG/gh.args"
echo 0123456789abcdef0123456789abcdef01234567
STUB
chmod +x "$work/bin/go" "$work/bin/gh"
export PATH="$work/bin:$PATH" STUB_LOG="$work"

fixture() {
  local repo=$work/repo
  rm -rf "$repo" "$work/go.calls" "$work/gh.request" "$work/gh.requests" "$work/gh.args"
  mkdir -p "$repo/server/issued" "$repo/tools/trial" "$repo/tools/other" "$repo/server/testdata/x"
  printf 'module github.com/devantler-tech/world-at-ruin/server\n\ngo 1.27.4\n' >"$repo/server/go.mod"
  printf 'module issued\n\ngo 1.27.4\n\nreplace github.com/devantler-tech/world-at-ruin/server => ..\n' >"$repo/server/issued/go.mod"
  printf 'module trial\n\ngo 1.27.4\n\nreplace (\n\tgithub.com/devantler-tech/world-at-ruin/server v0.0.0 => ../../server\n)\n' >"$repo/tools/trial/go.mod"
  printf 'module other\n\ngo 1.27.4\n\nreplace github.com/devantler-tech/world-at-ruin/server => github.com/example/fork v1.0.0\n' >"$repo/tools/other/go.mod"
  printf 'module fixture\n\nreplace github.com/devantler-tech/world-at-ruin/server => ../..\n' >"$repo/server/testdata/x/go.mod"
  touch "$repo/server/issued/go.sum" "$repo/tools/trial/go.sum"
  git -C "$repo" init -q
  git -C "$repo" add .
  git -C "$repo" -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm fixture
  cd "$repo"
}

# 1. Discovery finds exactly the local-path replacements, in both directive shapes.
fixture
[ "$("$script" list)" = "$(printf 'server/issued\ntools/trial')" ] || fail "list did not find exactly the two local-path dependents"

# 2. Tidy runs in each dependent and reports only their locks.
out=$("$script" tidy)
[ "$(cat "$work/go.calls")" = "$(printf 'server/issued\ntools/trial')" ] || fail "tidy did not run in exactly the dependents"
[ "$out" = "$(printf 'server/issued/go.mod\nserver/issued/go.sum\ntools/trial/go.mod\ntools/trial/go.sum')" ] || fail "tidy reported the wrong files: $out"

# 3. Commit sends one signed-by-GitHub commit with the tidied locks, pinned to the expected head.
GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin dependabot/go_modules/server/x 0123456789abcdef0123456789abcdef01234567 >/dev/null
[ "$(cat "$work/gh.args")" = "api graphql --input - --jq .data.createCommitOnBranch.commit.oid" ] || fail "commit did not call the GraphQL mutation"
jq -e '.variables.input.expectedHeadOid == "0123456789abcdef0123456789abcdef01234567"
  and .variables.input.branch.branchName == "dependabot/go_modules/server/x"
  and .variables.input.branch.repositoryNameWithOwner == "devantler-tech/world-at-ruin"
  and ([.variables.input.fileChanges.additions[].path] == ["server/issued/go.mod","server/issued/go.sum","tools/trial/go.mod","tools/trial/go.sum"])
  and (.variables.input.fileChanges.deletions == null)
  and (.query | test("createCommitOnBranch"))' "$work/gh.request" >/dev/null || fail "commit request is wrong"
[ "$(jq -r '.variables.input.fileChanges.additions[0].contents | @base64d' "$work/gh.request")" = "$(cat server/issued/go.mod)" ] || fail "commit contents do not match the tidied file"

# 3b. Large locks: the request must not pass file contents as one command-line argument. Linux
# caps a single argument at 128 KiB and macOS caps all of them at 1 MiB, so a real go.sum
# failed with "Argument list too long" (#1654 follow-up). 2 MiB of lock exceeds both.
fixture
"$script" tidy >/dev/null
head -c 2097152 /dev/zero | tr '\0' 'h' >>server/issued/go.sum
GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null ||
  fail "commit failed on a lock larger than the argument limit"
jq -j '.variables.input.fileChanges.additions[1].contents | @base64d' "$work/gh.request" | cmp -s - server/issued/go.sum ||
  fail "a large lock did not reach the commit request whole"

# 3c. A changed lock that cannot be read fails the commit before GitHub sees a partial request,
# even when it is not the last file.
fixture
"$script" tidy >/dev/null
rm server/issued/go.sum
if GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  fail "a commit with an unreadable lock was accepted"
fi
[ ! -e "$work/gh.request" ] || fail "a partial commit request reached GitHub"

# 4. Nothing changed: no commit request at all.
fixture
STUB_GO_NOOP=1 "$script" tidy >/dev/null
GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 2>/dev/null
[ ! -e "$work/gh.request" ] || fail "commit called GitHub with nothing to commit"

# 5. Fail closed.
fixture
if STUB_GO_FAIL=tools/trial "$script" tidy >/dev/null 2>&1; then fail "a failed tidy was accepted"; fi
fixture
echo changed >>server/go.mod
if "$script" tidy >/dev/null 2>&1; then fail "tidy ran on a dirty work tree"; fi
git checkout -q -- server/go.mod
"$script" tidy >/dev/null
echo changed >>server/go.mod
if GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then
  fail "a change outside the dependents' locks was committed"
fi
[ ! -e "$work/gh.request" ] || fail "an unexpected change reached GitHub"
git checkout -q -- server/go.mod
if GH_TOKEN=x "$script" commit devantler-tech/world-at-ruin b deadbeef >/dev/null 2>&1; then fail "a short expected head was accepted"; fi
if "$script" commit devantler-tech/world-at-ruin b 0123456789abcdef0123456789abcdef01234567 >/dev/null 2>&1; then fail "commit ran without a token"; fi
rm -rf server/issued tools/trial
if "$script" list >/dev/null 2>&1; then fail "no dependents was accepted"; fi

# 6. Prepare tidies only same-repository Dependabot server pull requests, each at its own head,
# and lists only the ones that changed.
fixture
commit_on() {
  git checkout -q -b "$1" main
  shift
  "$@"
  git add -A .
  git -c user.name=t -c user.email=t@example.invalid -c commit.gpgsign=false commit -qm change
  git rev-parse HEAD
}
git branch -q -m main
main_sha=$(git rev-parse HEAD)
sha_a=$(commit_on dependabot/go_modules/server/a sh -c 'echo "// bump a" >>server/go.mod')
sha_b=$(commit_on dependabot/go_modules/server/b sh -c 'echo "// bump b" >>server/go.mod && touch NOOP')
git checkout -q main
git clone -q "file://$work/repo" "$work/clone"
cd "$work/clone"
cat >"$work/prs.json" <<JSON
[
  {"number": 11, "headRefName": "dependabot/go_modules/server/a", "headRefOid": "$sha_a", "isCrossRepository": false, "author": {"login": "app/dependabot", "is_bot": true}},
  {"number": 12, "headRefName": "dependabot/go_modules/server/b", "headRefOid": "$sha_b", "isCrossRepository": false, "author": {"login": "app/dependabot", "is_bot": true}},
  {"number": 13, "headRefName": "dependabot/go_modules/server/c", "headRefOid": "$main_sha", "isCrossRepository": true, "author": {"login": "app/dependabot", "is_bot": true}},
  {"number": 14, "headRefName": "dependabot/go_modules/server/d", "headRefOid": "$main_sha", "isCrossRepository": false, "author": {"login": "someone", "is_bot": false}},
  {"number": 15, "headRefName": "dependabot/github_actions/e", "headRefOid": "$main_sha", "isCrossRepository": false, "author": {"login": "app/dependabot", "is_bot": true}}
]
JSON
rm -f "$work/go.calls"
GITHUB_OUTPUT="$work/output" "$script" prepare devantler-tech/world-at-ruin "$work/prepared" 2>/dev/null
[ "$(cat "$work/gh.list-args")" = "pr list --repo devantler-tech/world-at-ruin --state open --author app/dependabot --limit 100 --json number,headRefName,headRefOid,isCrossRepository,author" ] ||
  fail "prepare listed the wrong pull requests: $(cat "$work/gh.list-args")"
[ "$(cat "$work/prepared/pending.tsv")" = "$(printf '11\tdependabot/go_modules/server/a\t%s' "$sha_a")" ] || fail "prepare listed the wrong pending pull requests"
[ "$(cat "$work/output")" = pending=true ] || fail "prepare did not report pending work"
[ "$(git -C "$work/prepared/11" rev-parse HEAD)" = "$sha_a" ] && [ "$(git -C "$work/prepared/12" rev-parse HEAD)" = "$sha_b" ] || fail "prepare did not tidy each head"
for skipped in 13 14 15; do [ ! -e "$work/prepared/$skipped" ] || fail "prepare checked out #$skipped"; done
[ -z "$(git status --porcelain)" ] || fail "prepare changed the trusted checkout"
[ ! -e "$work/gh.request" ] || fail "prepare called GitHub with a write"

GH_TOKEN=x "$script" commit-prepared devantler-tech/world-at-ruin "$work/prepared" >/dev/null 2>&1
[ "$(jq -s length "$work/gh.requests")" = 1 ] || fail "commit-prepared did not send exactly one commit"
jq -e --arg head "$sha_a" '.variables.input.expectedHeadOid == $head
  and .variables.input.branch.branchName == "dependabot/go_modules/server/a"
  and ([.variables.input.fileChanges.additions[].path] == ["server/issued/go.mod","server/issued/go.sum","tools/trial/go.mod","tools/trial/go.sum"])' \
  "$work/gh.request" >/dev/null || fail "commit-prepared sent the wrong commit"

# Nothing to do: no pending work and no write.
printf '[]' >"$work/prs.json"
rm -f "$work/output" "$work/gh.request" "$work/gh.requests"
GITHUB_OUTPUT="$work/output" "$script" prepare devantler-tech/world-at-ruin "$work/prepared-empty" 2>/dev/null
[ "$(cat "$work/output")" = pending=false ] || fail "prepare reported work when there was none"
GH_TOKEN=x "$script" commit-prepared devantler-tech/world-at-ruin "$work/prepared-empty" >/dev/null 2>&1
[ ! -e "$work/gh.request" ] || fail "commit-prepared wrote with nothing prepared"

# Fail closed on a reused work directory, a malformed list and a malformed entry.
if "$script" prepare devantler-tech/world-at-ruin "$work/prepared" >/dev/null 2>&1; then fail "prepare reused a work directory"; fi
printf '{}' >"$work/prs.json"
if "$script" prepare devantler-tech/world-at-ruin "$work/prepared-bad" >/dev/null 2>&1; then fail "prepare accepted a malformed list"; fi
printf '[{"number": 16, "headRefName": "dependabot/go_modules/server/f", "headRefOid": "main", "isCrossRepository": false, "author": {"login": "app/dependabot"}}]' >"$work/prs.json"
if "$script" prepare devantler-tech/world-at-ruin "$work/prepared-bad2" >/dev/null 2>&1; then fail "prepare accepted a head that is not a full SHA"; fi
if "$script" commit-prepared devantler-tech/world-at-ruin "$work/missing" >/dev/null 2>&1; then fail "commit-prepared accepted a missing preparation"; fi

# 7. The workflow runs on a schedule from the default branch with a read-only token, and only
# the commit step, after go has run, sees the App token.
cd "$root"
command -v yq >/dev/null || fail "yq is required"
[ "$(yq '.permissions | length' "$workflow")" = 0 ] || fail "workflow-level permissions must be empty"
[ "$(yq '.on | keys | join(",")' "$workflow")" = schedule,workflow_dispatch ] || fail "the workflow must only run on a schedule or by hand"
[ "$(yq -o=json -I=0 '.jobs.tidy.permissions' "$workflow")" = '{"contents":"read","pull-requests":"read"}' ] || fail "the job's GITHUB_TOKEN must only read"
[ "$(yq '.jobs | keys | join(",")' "$workflow")" = tidy ] || fail "expected the one tidy job"
checkouts='[.jobs.tidy.steps[] | select(.uses == "actions/checkout@*")]'
[ "$(yq "$checkouts | length" "$workflow")" = 1 ] || fail "expected one checkout"
[ "$(yq "$checkouts | .[0].with | to_entries | map(.key + \"=\" + (.value | tostring)) | join(\",\")" "$workflow")" = persist-credentials=false ] ||
  fail "the checkout must be the default branch without a persisted credential"
[ "$(yq '[.jobs.tidy.steps[] | select(.uses == "actions/setup-go@*")] | .[0].with.cache' "$workflow")" = false ] || fail "the job must not use the shared Go cache"
token_users=$(yq '[.jobs.tidy.steps[] | select(to_yaml | test("steps\.app-token\.outputs\.token")) | .name] | join(",")' "$workflow")
[ "$token_users" = "Commit the tidied locks" ] || fail "only the commit step may see the App token (saw: $token_users)"
[ "$(yq '.jobs.tidy.steps[] | select(.name == "Commit the tidied locks") | .run' "$workflow")" = "bash tools/server-dependents-tidy.sh commit-prepared \"\$REPOSITORY\" \"\$RUNNER_TEMP/server-tidy\"" ] ||
  fail "the commit step must only commit what was prepared"
[ "$(yq '.jobs.tidy.steps[] | select(.id == "prepare") | .run' "$workflow")" = "bash tools/server-dependents-tidy.sh prepare \"\$REPOSITORY\" \"\$RUNNER_TEMP/server-tidy\"" ] ||
  fail "the prepare step must run the tidy script"
[ "$(yq '.jobs.tidy.steps[] | select(.id == "prepare") | .env.GH_TOKEN' "$workflow")" = "\${{ github.token }}" ] || fail "prepare must use the read-only token"
token_index=$(yq '.jobs.tidy.steps | to_entries | map(select(.value.id == "app-token")) | .[0].key' "$workflow")
prepare_index=$(yq '.jobs.tidy.steps | to_entries | map(select(.value.id == "prepare")) | .[0].key' "$workflow")
[ "$token_index" != null ] && [ "$prepare_index" != null ] && [ "$prepare_index" -lt "$token_index" ] || fail "the App token must be minted after go has run"
[ "$(yq '[.jobs.tidy.steps[] | select(.id == "app-token" or .name == "Commit the tidied locks") | .if] | unique | join(",")' "$workflow")" = "steps.prepare.outputs.pending == 'true'" ] ||
  fail "the token and commit steps must run only when something was prepared"

echo "server-dependents-tidy: PASS"
