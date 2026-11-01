# Run the complete server race suite in a local Linux VM

Use this optional path on an **Apple Silicon Mac with macOS 13.5 or newer** when native macOS
tests cannot complete the private-interface transport prerequisite. It runs the unchanged suite
against a real Linux network interface. Keep the host's security settings intact; a loopback-only
substitute does not establish allocator transport acceptance.

The VM uses 2 CPUs, 4 GiB RAM and a 16 GiB virtual disk. Its configuration pins an Ubuntu image
and Go archive by SHA-256; first boot downloads those and installs GCC and Git inside the guest.
Lima plain mode disables host mounts, application port forwarding, containerd and the guest agent.
SSH uses invocation-specific keys, with no host SSH-agent or proxy-environment forwarding.
After cleanup, the Mac retains the Lima package and its normal download cache. There is no Docker context or
production connection to configure.

## Install the optional host tool

Install [Lima](https://lima-vm.io/docs/installation/) through Homebrew and check the version:

```sh
brew install lima
limactl --version
```

This procedure was exercised with **Lima 2.2.1**. Other architectures need a separately verified
image and Go archive; do not remove the digest checks or use an unpinned fallback image.

## Start a private instance

Run these commands from your isolated **repository root**, in one Bash terminal. Commit the
changes you intend to test first: `git archive` copies tracked bytes from the selected commit,
including their licence, rather than uncommitted files or the host's Git configuration.
Only execute source you are authorized to run locally.

```bash
set -euo pipefail
war_revision=$(git --no-replace-objects rev-parse --verify HEAD)
war_linux_dir=$(mktemp -d /tmp/war-linux.XXXXXXXX)
export LIMA_HOME="$war_linux_dir/lima"
printf 'Temporary directory: %s\nLIMA_HOME: %s\n' "$war_linux_dir" "$LIMA_HOME"
limactl validate tools/local-server-linux.yaml
limactl start --tty=false --name=server --timeout=10m tools/local-server-linux.yaml
```

The short `/tmp` path leaves room for Lima's Unix sockets. The separate `LIMA_HOME` prevents this
instance from using another developer's instance, keys or default configuration.

## Copy and test the selected revision

```bash
git --no-replace-objects archive --format=tar.gz \
  --output="$war_linux_dir/source.tar.gz" "$war_revision"
war_source_sum=$(shasum -a 256 "$war_linux_dir/source.tar.gz" | awk '{print $1}')
printf 'Testing source %s, archive %s\n' "$war_revision" "$war_source_sum"
limactl copy --tty=false --backend=scp "$war_linux_dir/source.tar.gz" server:/tmp/world-source.tar.gz
limactl shell --tty=false --workdir=/tmp server sh -c \
  'printf "%s  %s\n" "$1" /tmp/world-source.tar.gz | sha256sum --check --strict' sh "$war_source_sum"
limactl shell --tty=false --workdir=/tmp server bash -c '
  set -euo pipefail
  mkdir /tmp/world-source
  tar -xzf /tmp/world-source.tar.gz -C /tmp/world-source
  declared=$(awk '\''$1 == "go" { print $2 }'\'' /tmp/world-source/server/go.mod)
  test "$(/usr/local/go/bin/go env GOVERSION)" = "go$declared"
  env GOTOOLCHAIN=local GOMAXPROCS=2 CGO_ENABLED=1 \
    /usr/local/go/bin/go -C /tmp/world-source/server test -race -count=1 ./...
'
```

The archive check must report `OK`; the complete Go command must exit zero. `-count=1` runs the
tests again instead of reusing a test result. The toolchain check refuses a mismatch with
`server/go.mod`: update the pinned archive and its [official checksum](https://go.dev/dl/?mode=json)
together before retrying.
Retain the source revision, archive checksum and complete result in your private validation notes.

This supplies the ordinary local server race suite, including private-interface TLS/RPC tests.
It does not replace formatting, vet, build, lint, vulnerability and duplication checks, or the
separate hosted native suites, review and protected merge described in [CONTRIBUTING.md](../CONTRIBUTING.md).

## Retire the instance

Run cleanup in the same terminal **even if provisioning, copying or tests fail**. If `set -e`
ended the script, first set `war_linux_dir` to this invocation's printed temporary directory; never
select a different instance or use force deletion as a substitute for verified shutdown.

```sh
(
  set -euo pipefail
  : "${war_linux_dir:?Set the printed temporary directory for this invocation first}"
  case "$war_linux_dir" in
    /tmp/war-linux.????????) ;;
    *) echo 'Unexpected temporary directory; retain it for inspection' >&2; exit 1 ;;
  esac
  export LIMA_HOME="$war_linux_dir/lima"
  if [ -d "$LIMA_HOME/server" ]; then
    limactl stop --tty=false server
    war_status=$(limactl list --format '{{.Status}}' server)
    test "$war_status" = Stopped
    limactl delete --tty=false server
  fi
  war_instances=$(limactl list --json)
  test -z "$war_instances"
  rm -r -- "$war_linux_dir"
)
```

This block independently enables error handling, verifies `Stopped` before deletion and verifies
the instance inventory is empty before removing its control directory. A failure before instance
creation can therefore still be cleaned up. It retires the guest's
test processes, network listeners, copied source and disk; Lima's normal image download cache
and the installed host package remain. If shutdown or deletion fails, retain the invocation's
directory and report cleanup as incomplete.
After successful cleanup, run `unset LIMA_HOME` or close this dedicated terminal to discard its
temporary environment.
