# Contributing to World at Ruin

World at Ruin is **source-available and proprietary**, rather than open source. Read the
[licence](LICENSE.md) before building or forking: it permits personal evaluation and a GitHub fork
for preparing a contribution, but does not grant general redistribution or public-server rights.
All external contributions, including documentation, require the [CLA](CLA.md), which assigns
copyright. The CLA check explains the signing step on your pull request; sign it yourself only
after reading and accepting the agreement.

## Choose a change

Discuss substantial work in a [GitHub issue](https://github.com/devantler-tech/world-at-ruin/issues)
before implementing it. Explain the problem, who it affects, and what a successful result looks
like. Check existing issues and pull requests to avoid duplicating work. Fork the repository and
create a descriptive branch for the agreed change; keep unrelated changes out of the pull request.

Read [AGENTS.md](AGENTS.md), especially its product laws and [Maintenance](AGENTS.md#maintenance)
checks. Existing characters must survive updates without resets or silent loss. Unfinished
experiments stay off by default. Player-visible work also needs an in-game dev-log entry and
rendered evidence compared with the intended reference; original art must meet the repository's
provenance rules.

## Install only the tools your change needs

- Client work uses **Godot 4.7.1**, matching client CI. Install it from the
  [official archive](https://godotengine.org/download/archive/) and check `godot --version`.
  On macOS, `/Applications/Godot.app/Contents/MacOS/Godot` can replace `godot` in the commands below.
  Exporting needs the matching **4.7.1** export templates; running from source does not.
- Server work uses **Go 1.27.2**, as declared in `server/go.mod`. Check `go version`; automatic
  toolchain selection may download the pinned version when you enter the module. Race tests need
  cgo enabled (`go env CGO_ENABLED` must print `1`); on Linux, install a C compiler such as GCC or
  Clang. See the [Go race-detector requirements](https://go.dev/doc/articles/race_detector#Requirements).
  The security checks use **govulncheck 1.7.0**, pinned in CI. Client play does not require a server,
  cluster, credentials, or Go.
- Optional humanoid regeneration uses Blender **5.2.0 LTS** and MPFB **2.0.16**. Follow the
  [kit guide](tools/artgen/humanoid_kit/README.md) before installing extensions or downloading packs.
- Optional local GameServer storage trials have platform and download prerequisites in the
  [trial guide](tools/gameserver-commit-trial/README.md). They are separate from ordinary client play.

The [CI workflow](.github/workflows/ci.yaml) records the other check-tool pins, including
gdtoolkit **4.5.0**, golangci-lint **2.14.0**, and the duplication scanner. Follow the hash-locked
GDScript setup there rather than installing an arbitrary latest linter. You do not need to run an
art bake, install a cluster, or obtain production access for a documentation-only contribution.

## Run the client with disposable saves

Start in the **repository root**. Import assets before running scenes:

```sh
godot --headless --editor --quit --path client
```

The import must exit zero without script errors. It creates an ignored `client/.godot/` cache.
Separate checkouts still share Godot's default user-data directory, so a development launch needs
all four save redirects. In the same terminal, create a fresh directory and export these values
before launching:

```sh
war_trial_dir=$(mktemp -d)
export WAR_SAVE_PATH="$war_trial_dir/character.json"
export WAR_VAULT_PATH="$war_trial_dir/vault.json"
export WAR_BOOT_RECOVERY_PATH="$war_trial_dir/boot_recovery.json"
export WAR_UPDATE_HISTORY_PATH="$war_trial_dir/update_history.json"
export WAR_ZONE_URL=
export WAR_UPDATE_CHECK=0
godot --path client
```

This runs offline with disposable character, vault, recovery, and update-history files. On this
fresh save, the character creator opens first: shape your wanderer and select **Wake** to enter
the starter cave. Movement stays disabled until Wake. Then `WASD` moves, `C` opens character
reshaping, and `L` opens the dev log. Close the game before inspecting or removing that temporary
directory. Keep these variables set for every
launch in this terminal. A launch from another terminal or the app icon uses its own environment
and can reach your regular saves. Never delete the normal Godot user-data directory to fix a test.

## Check your change

These small checks give a first success signal, from the repository root:

```sh
git diff --check
bash tools/run-client-test.sh world_gen_determinism_test
go -C server test -race -count=1 -timeout 2m ./sim
```

Run the client command after importing with the pinned Godot version. It requires `TEST PASS`
and rejects test failures and script errors; that scene does not enter the player game or touch
character saves. Run the Go command for server changes; it must print `ok` for the simulation
package and exit zero.
Neither check proves the full game or server is ready.

Before submitting, follow the full applicable [Maintenance checks](AGENTS.md#maintenance): the
client import, an isolated 120-frame boot with `BOOT_OK` and no script errors, the complete client
regression suite and GDScript lint; or server formatting, vet, race tests, build, lint, and
`govulncheck ./...` from both `server/` and `.github/scripts/release-credential-boundary/`. All
regression scenes under `client/tests/` are required; selected tests are only the earlier first
success signal. The CI workflow records the complete suite and its dedicated named checks. Run player
tests through the repository's save-isolation helpers, not by launching their scenes directly.
Record a missing tool or unexecuted optional trial accurately instead of reporting a pass.

Pull-request CI also runs independent client regressions, native server proofs on both supported
architectures, security and quality checks, and the export/boot checks. Passing a short local check
does not replace those checks or review. Fix failures at their cause; never silence or weaken a
check to get a green result.

## Submit a pull request

Use signed commits and open a **draft** pull request with a Conventional Commit title, such as
`docs: clarify the source launch setup` or `fix: preserve a character during an update`. Keep the
inherited template's **Why**, **What**, and **Fixes #** structure: describe the problem and outcome
in plain language and link the agreed issue. If you used AI assistance, state that in the pull
request description and take responsibility for the submitted code, its licence and validation.
Do not present AI-assisted work as unaided human work.

Record which checks and user-facing paths you actually exercised, including any limits, in a
pull-request comment. Address review feedback and wait for the current commit's required checks
before marking the draft ready. A passing check or an open pull request is not delivery; the
change must merge through the repository's normal review and branch-protection process.

## Report a security problem privately

Use [GitHub's private vulnerability form](https://github.com/devantler-tech/world-at-ruin/security/advisories/new)
under **Security → Report a vulnerability**. Include enough information to reproduce the problem,
but do not put vulnerability details, credentials, personal save data, or private infrastructure
information in a public issue or pull request.
