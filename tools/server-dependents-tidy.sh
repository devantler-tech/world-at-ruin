#!/usr/bin/env bash
# Keeps the Go modules that replace the server module with the local tree in step with a
# Dependabot update to server/go.mod (#1654).
#
# Dependabot rewrites only server/go.mod and server/go.sum. Every module that points at the
# local server tree with a `replace` directive keeps its own locks, so its -mod=readonly
# builds and tests fail with "updates to go.mod needed" until `go mod tidy` runs there.
#
#   server-dependents-tidy.sh list
#       Print every module directory whose go.mod replaces the server module with a local path.
#   server-dependents-tidy.sh tidy
#       Run `go mod tidy` in each of those modules and print the go.mod/go.sum files it changed.
#   server-dependents-tidy.sh commit REPOSITORY BRANCH EXPECTED_HEAD_SHA
#       Commit the changed go.mod/go.sum files to BRANCH through the GraphQL
#       createCommitOnBranch mutation (GH_TOKEN), so GitHub signs the commit. The mutation
#       refuses if BRANCH moved past EXPECTED_HEAD_SHA. Nothing is committed when nothing changed.
#   server-dependents-tidy.sh prepare REPOSITORY DIRECTORY
#       For every open same-repository Dependabot pull request on a server branch, check its
#       head out under DIRECTORY and tidy it there. The ones that changed are listed in
#       DIRECTORY/pending.tsv, and `pending=true|false` goes to $GITHUB_OUTPUT when set.
#   server-dependents-tidy.sh commit-prepared REPOSITORY DIRECTORY
#       Run `commit` for every pull request in DIRECTORY/pending.tsv.
#
# Every mode runs from the repository root (prepare from the trusted default-branch checkout)
# and fails closed: no dependent module, a failed tidy, or a change outside the dependents'
# go.mod/go.sum is an error.
set -euo pipefail

readonly server_module='github.com/devantler-tech/world-at-ruin/server'
readonly headline='ci: tidy the modules that replace the server module'

die() {
  echo "server-dependents-tidy: $*" >&2
  exit 1
}

dependents() {
  local mod dir found=0
  while IFS= read -r mod; do
    dir=${mod%/go.mod}
    dir=${dir#./}
    # A local-path replace of the server module, written either as a single directive or
    # inside a replace block.
    if grep -Eq "^[[:space:]]*(replace[[:space:]]+)?${server_module//./\\.}([[:space:]]+v[^[:space:]]+)?[[:space:]]+=>[[:space:]]+\.\.?(/|[[:space:]]|$)" "$mod"; then
      printf '%s\n' "$dir"
      found=1
    fi
  done < <(find . -name go.mod -not -path './.git/*' -not -path '*/testdata/*' | LC_ALL=C sort)
  [ "$found" -eq 1 ] || die "no module replaces $server_module with a local path"
}

changed_files() {
  local allowed=$1 path dir ok
  git diff --name-only -- . | LC_ALL=C sort | while IFS= read -r path; do
    ok=0
    while IFS= read -r dir; do
      if [ "$path" = "$dir/go.mod" ] || [ "$path" = "$dir/go.sum" ]; then
        ok=1
      fi
    done <<<"$allowed"
    [ "$ok" -eq 1 ] || die "unexpected change outside the dependents' locks: $path"
    printf '%s\n' "$path"
  done
}

cmd_list() {
  dependents
}

cmd_tidy() {
  local list dir
  list=$(dependents)
  [ -z "$(git status --porcelain --untracked-files=no)" ] || die "the work tree must be clean before tidying"
  while IFS= read -r dir; do
    echo "server-dependents-tidy: go mod tidy in $dir" >&2
    go -C "$dir" mod tidy || die "go mod tidy failed in $dir"
  done <<<"$list"
  changed_files "$list"
}

cmd_commit() {
  [ "$#" -eq 3 ] || die "usage: commit REPOSITORY BRANCH EXPECTED_HEAD_SHA"
  local repository=$1 branch=$2 head=$3 list files query request status
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $repository"
  [[ "$head" =~ ^[0-9a-f]{40}$ ]] || die "expected head must be a full commit SHA"
  [ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is required to commit"

  list=$(dependents)
  files=$(changed_files "$list")
  if [ -z "$files" ]; then
    echo "server-dependents-tidy: the dependent modules are already tidy; nothing to commit" >&2
    return 0
  fi

  # The file contents reach jq through files and stdin only, never as an argument: a real
  # go.sum is larger than one command-line argument may be ("Argument list too long"). The
  # whole request is built before GitHub is called, so a lock that cannot be read fails the
  # commit instead of sending the files encoded before it.
  query="mutation(\$input: CreateCommitOnBranchInput!) { createCommitOnBranch(input: \$input) { commit { oid } } }"
  request=$(mktemp) || die "could not create the commit request file"
  if ! while IFS= read -r path; do
    jq -n --arg path "$path" --rawfile contents "$path" '{path: $path, contents: ($contents | @base64)}' || exit 1
  done <<<"$files" | jq -s \
    --arg query "$query" \
    --arg repository "$repository" \
    --arg branch "$branch" \
    --arg head "$head" \
    --arg headline "$headline" \
    --arg body "Ran go mod tidy in every module that replaces the server module with the local tree, so their read-only builds accept this server update (#1654)." \
    '. as $additions | {query: $query, variables: {input: {
        branch: {repositoryNameWithOwner: $repository, branchName: $branch},
        expectedHeadOid: $head,
        message: {headline: $headline, body: $body},
        fileChanges: {additions: $additions}
      }}}' >"$request"; then
    rm -f "$request"
    die "could not read every changed lock; nothing was committed"
  fi

  status=0
  gh api graphql --input - --jq '.data.createCommitOnBranch.commit.oid' <"$request" || status=$?
  rm -f "$request"
  return "$status"
}

cmd_prepare() {
  [ "$#" -eq 2 ] || die "usage: prepare REPOSITORY DIRECTORY"
  local repository=$1 directory=$2 prs number branch head files
  [[ "$repository" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "invalid repository: $repository"
  [ ! -e "$directory" ] || die "the work directory must not exist yet: $directory"
  mkdir -p "$directory"
  : >"$directory/pending.tsv"

  prs="$directory/pull-requests.json"
  gh pr list --repo "$repository" --state open --author app/dependabot --limit 100 \
    --json number,headRefName,headRefOid,isCrossRepository,author >"$prs" ||
    die "could not list open Dependabot pull requests"
  jq -e 'type == "array"' "$prs" >/dev/null || die "unexpected pull request list"

  while IFS=$'\t' read -r number branch head; do
    [[ "$number" =~ ^[0-9]+$ && "$head" =~ ^[0-9a-f]{40}$ ]] || die "unexpected pull request entry: $number $head"
    echo "server-dependents-tidy: #$number $branch at $head" >&2
    git fetch --quiet --no-tags --depth=1 origin "$head" || die "could not fetch $head"
    git worktree add --quiet --detach "$directory/$number" "$head" || die "could not check out $head"
    files=$(cd "$directory/$number" && cmd_tidy)
    if [ -n "$files" ]; then
      printf '%s\t%s\t%s\n' "$number" "$branch" "$head" >>"$directory/pending.tsv"
    fi
  done < <(jq -r '.[]
    | select(.author.login == "app/dependabot" and .isCrossRepository == false)
    | select(.headRefName | startswith("dependabot/go_modules/server/"))
    | [.number, .headRefName, .headRefOid] | @tsv' "$prs")

  local pending=false
  [ ! -s "$directory/pending.tsv" ] || pending=true
  echo "server-dependents-tidy: $(wc -l <"$directory/pending.tsv" | tr -d ' ') pull request(s) need a tidy commit" >&2
  [ -z "${GITHUB_OUTPUT:-}" ] || echo "pending=$pending" >>"$GITHUB_OUTPUT"
}

cmd_commit_prepared() {
  [ "$#" -eq 2 ] || die "usage: commit-prepared REPOSITORY DIRECTORY"
  local repository=$1 directory=$2 number branch head
  [ -f "$directory/pending.tsv" ] || die "nothing was prepared in $directory"
  while IFS=$'\t' read -r number branch head; do
    (cd "$directory/$number" && cmd_commit "$repository" "$branch" "$head")
  done <"$directory/pending.tsv"
}

[ "$#" -ge 1 ] || die "usage: server-dependents-tidy.sh list|tidy|commit|prepare|commit-prepared ..."
mode=$1
shift
case "$mode" in
  list) cmd_list "$@" ;;
  tidy) cmd_tidy "$@" ;;
  commit) cmd_commit "$@" ;;
  prepare) cmd_prepare "$@" ;;
  commit-prepared) cmd_commit_prepared "$@" ;;
  *) die "unknown mode: $mode" ;;
esac
