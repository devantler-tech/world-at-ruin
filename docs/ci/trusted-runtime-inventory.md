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
bundle; the installed engine checksum; seventeen builder/helper, base-proof and package-lock source identities;
and the resulting image's Linux/amd64, non-root, working-directory and
entrypoint contract. APT performs its ordinary signature and HTTPS checks.
Its index observations are captured before the package lists are removed.

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
The inventory does not independently authenticate package archive bytes,
producer authorization, artifact provenance or future cache admission. It
publishes no executor archive, enables no reuse and proves no warm saving.
Those decisions and whether to retain this diagnostic after adoption belong
to [#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).
Caller engine version/ZIP checksum fields describe the selected installer;
the separate executable checksum joins the host engine to the observed image.

Validate with:

```sh
go test -race tools/trusted-runtime-inventory/main.go tools/trusted-runtime-inventory/main_test.go
bash tools/trusted-runtime-inventory.test.sh
bash tools/client-proof-workflow-guard.test.sh
bash tools/trusted-regression-deadlines.test.sh
```

A real hosted cold build supplies the package/index observation; these local
parser and command controls alone do not supply it.
