# Keep the trusted runtime's installed packages predictable

Every cold runtime build checks the complete installed package set against
`.github/containers/trusted-runtime-packages.lock.json`. Missing or extra packages,
different versions or architectures, and non-installed states refuse the build.
The optional inventory report cannot turn this check off. Stdout from the builder
remains the admitted image digest; successful Docker output contains
`TRUSTED_RUNTIME_PACKAGES verified=147 architecture=amd64` for the current lock.

The host validates the lock's schema, unique sorted identities, exact Ubuntu
manifest, snapshot declaration and direct package arguments before Docker runs.
It emits canonical TSV into the private build context. The image captures one
complete successful `dpkg-query` result, sorts it and compares every byte. A
producer that prints plausible data and then fails cannot pass. The check runs
under the existing 900-second build phase, before the executor can be returned.

## Updating the expectation

Never hand-edit the generated JSON. Obtain a complete successful cold report
from a reviewed source revision using the inventory procedure, verify the native
job's exact source and recipe identities, and inspect all dependency changes.
The initial 147-package expectation comes from signed source
`d8b129efee524c9a78b0a17d9254a7ad522c017a`, successful native sandbox job
`116531238986` in run `38766577565`, and Ubuntu manifest
`sha256:f610ab94648195aa356059f5b41d6085c9d4d903c072430cdd1af7bdb646106b`.

With the single report JSON saved as `cold-report.json`, generate and inspect:

```sh
go run tools/trusted-runtime-packages/main.go --from-report cold-report.json . > .github/containers/trusted-runtime-packages.lock.json
go run tools/trusted-runtime-packages/main.go --emit .
go test -race tools/trusted-runtime-packages/main.go tools/trusted-runtime-packages/main_test.go
bash tools/trusted-runtime-packages.test.sh
```

The generator validates the report's complete JSON envelope and runtime contract;
it cannot authenticate where the report came from. The source/job/recipe join and
review remain mandatory. When a legitimate dependency change makes the old lock
refuse, collect its proposed inventory in a disposable maintenance build and
review the resulting lock. Such a discovery build is never an admitted executor
and must not replace the ordinary trusted workflow. Prove the final locked build
in hosted CI, alongside all trusted scenes, before merge.

The sandbox trial also mounts a changed expected version into the same immutable
image and runs the real verifier as the same non-root user with no network,
capabilities or writable root. It requires the specific identity refusal and
verified owned-container absence under the existing inspection deadline.

Installed identities are narrower evidence than archive digests or provenance.
The lock preserves APT's existing authentication and ten direct arguments; it
does not establish independently authenticated `.deb` bytes or prove which mirror
supplied them. It enables no cache, publication, new App or credentials. Further
admission and reuse remain [#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).
