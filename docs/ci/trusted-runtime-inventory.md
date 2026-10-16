# Observe the cold runtime's dependencies

`WAR_TRUSTED_RUNTIME_INVENTORY=1 bash tools/build-trusted-regression-runtime.sh`
builds the pinned Linux/amd64 runtime and emits one
`TRUSTED_RUNTIME_INVENTORY` JSON report on stderr. Stdout remains the immutable
image configuration digest. The default and `0` omit collection; other values
refuse before building. Install the verified Linux Godot executable with
`tools/install-ci-godot.sh` first, using the version and ZIP checksum in CI.
Go, jq, Docker and GNU timeout must be available.

The report records every installed package, including base and transitive
packages; the package architecture and installed state; SHA-256 identities and
sizes of APT indexes, source/configuration files, archive keyring and copied CA
bundle; the installed engine checksum; twenty-two builder/helper, base-proof, package-lock and archive-lock source identities;
and the resulting image's Linux/amd64, non-root, working-directory and
entrypoint contract. APT performs its ordinary signature and HTTPS checks.
Its index observations are captured before the package lists are removed.

The selected diagnostic wraps the same ten direct install arguments. It records
APT's installed version, every pre-install package identity, and the complete
very-quiet print-URIs plan with explicit SHA-256 selection. APT downloads into an
empty invocation-local cache before any package scripts run. Each archive's
regular-file identity, link count, byte count and complete SHA-256 must match the
plan. Package/version/architecture comes from `dpkg-deb`, never from a filename.
The inherited identities plus the acquired tuples must exactly explain the
reviewed installed-package expectation. Failed or partial readers, unexpected
plan output, duplicate destinations/packages, missing/extra/linked archives,
pending partial files and changed baseline state refuse installation.

Before the offline install, the repository-built origin helper reads the complete
bounded set of package targets that APT 2.8.3 marks trusted. It hashes each retained
Packages file exactly as stored and uses APT's fixed helper to decode supported
compressed indexes for bounded deb822 parsing. It derives each target's local
InRelease path from APT's base URI naming rule, hashes the regular single-link
Packages and InRelease files, and requires every acquired tuple to match one or
more byte-identical targets on the effective archive repository derived from each
Packages target URI, plus APT-encoded package filename,
package/version/architecture, byte count and SHA-256. A missing, untrusted,
partial, linked, duplicate or conflicting target refuses before package scripts execute.

The same arguments and cache then run with `--no-download`, without missing-file
tolerance or a download fallback. The existing final installed-set verifier still
runs from freshly copied expected bytes. Normal and selected diagnostic builds
enforce the reviewed archive expectation; the default omits transaction
publication. A selected build publishes no complete transaction after a failed
acquisition, verification or no-download installation.

`inventory.transaction` carries `apt_version`, `direct_arguments`,
`preinstall_packages`, `apt_targets` and `downloaded_archives`. Each target retains
its trusted Release identity and exact Packages/InRelease file identities. Each
archive includes its observed tuple, basename, bytes, SHA-256, `requested_uri` and
the complete nonempty `apt_origins` set joined to those targets. Every pre-install
plan/acquired-archive pair must join only to byte-identical members of the complete
authenticated target set before the report is emitted. Transaction
archives explain new or changed packages; they are not the full installed set.
`direct_arguments` is the canonically sorted set of direct package pins; the
wrapper preserves the original invocation order across all three APT commands.
The plan is limited to 1,024 archives, 64 MiB per archive and 256 MiB total before
download. Private cache bytes are deleted on every exit within the existing build
deadline and do not remain in a successful image layer.

The selected build uses the existing 900-second build limit. Image inspection,
fixed-path extraction, container absence verification and report validation
share the existing 30-second inspection phase. The extraction container has
no network, capabilities, project mounts or writable root filesystem. It runs
as `1001:1001`; cancellation cleanup tracks only its invocation-owned name.
An incomplete command, overflow, missing record, wrong pin, unexpected package
state, mismatched engine or unverified cleanup refuses the report. The raw
inventory is limited to 1 MiB, 2,048 packages and 256 input files.

The candidate sandbox job selects this observation for its initial containment
image using `WAR_TRUSTED_RUNTIME_INVENTORY_PROBE=1`. The subsequent historical
regression controller retains its ordinary build selection. Both containment
and the complete trusted scene suite must still succeed with cleanup. The
report measures the first image only.

This is an **observed cold-build inventory**. The builder separately verifies
the [platform-specific base metadata proof](trusted-runtime-bases.md) before
Docker runs; the inventory binds those proof and checker bytes to this observation.
Every build also enforces the [complete installed identity expectation](trusted-runtime-packages.md).
APT's download-only phase retains its normal authentication. Print-URIs runs
before APT's archive authentication and is not itself an authentication receipt;
the origin helper therefore joins the acquired bytes to APT's trusted target and
the exact Packages/InRelease inputs retained after the authenticated update. The
helper does not replace APT's signature verifier or let its own report authorize a
future executor. The separately reviewed
[archive expectation](trusted-runtime-archives.md) now admits an exact cold-build
closure before package scripts execute. This diagnostic can propose that lock;
it cannot approve it. It publishes no executor archive, enables no reuse and
proves no warm saving. Producer, custody and reuse decisions belong to
[#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).
Caller engine version/ZIP checksum fields describe the selected installer;
the separate executable checksum joins the host engine to the observed image.

For archive-lock maintenance, the manually dispatched **Propose trusted runtime
archives** workflow is the only hosted path that may set the paired proposal and
inventory selectors. It retains one complete successful native report, source
image digest and generated lock as a seven-day review artifact. Proposal mode
skips only comparison with the stale archive expectation; authentication,
complete origin joins, archive bounds and hashes, final package equality and the
same-cache offline install remain mandatory. It removes the disposable image
after extraction. Verify the exact source/job/recipe identities independently
before reviewing any proposed expectation. A report cannot authorize its own
executor. An unavailable snapshot/package or a mismatched tuple stops the build:
review the generated change and prove the final locked path in ordinary CI.
Never disable authentication or validity checks to recover. Generate and review
the expectation with the [archive maintenance procedure](trusted-runtime-archives.md).

Validate with:

```sh
go test -race tools/trusted-runtime-inventory/main.go tools/trusted-runtime-inventory/main_test.go
go test -race tools/trusted-runtime-origin/main.go tools/trusted-runtime-origin/main_test.go
go test -race tools/trusted-runtime-archives/main.go tools/trusted-runtime-archives/main_test.go
bash tools/trusted-runtime-inventory.test.sh
bash tools/trusted-runtime-transaction.test.sh
bash tools/propose-trusted-runtime-archives.test.sh
bash tools/client-proof-workflow-guard.test.sh
bash tools/trusted-regression-deadlines.test.sh
```

A real hosted cold build supplies the package/index observation; these local
parser and command controls alone do not supply it.
