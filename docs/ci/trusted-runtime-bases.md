# Verify the trusted runtime's Linux bases

The trusted regression builder consumes two Linux/amd64 image manifests. The
certificate stage and Ubuntu runtime retain their original independently pinned
multi-platform index roots in
`.github/containers/trusted-runtime-bases.sources.json`. The generated sibling
lock contains the original index, selected manifest and image configuration bytes
as base64. Keeping the bytes preserves their SHA-256 identities across formatting.

Before Docker runs, `tools/trusted-runtime-bases/main.go --check` verifies each
index against its source root, requires exactly one Linux/amd64 descriptor,
verifies the child manifest and configuration sizes and digests, checks the
configuration platform, and joins both actual Dockerfile `FROM` references.
Missing, partial, altered, ambiguous, oversized or mismatched inputs refuse the
build before Docker is invoked. The wrapper selects `--platform linux/amd64`.
This check and Docker share the existing 900-second build/pull phase; image-ID-only
stdout, inspection, cancellation and cleanup contracts remain in effect.

Ordinary builds verify the committed proof offline. Only explicit maintenance
resolution contacts Docker Hub's public metadata and anonymous pull-token
endpoints; it never reads local Docker credentials. Responses are bounded to
1 MiB each, complete reads are mandatory, and resolution has a two-minute overall
deadline with 30-second HTTP request limits. Redirects are restricted to the
registry and its observed public metadata CDN, `production.cloudfront.docker.com`;
the CDN never receives the registry bearer token. A changed destination requires
a reviewed policy update. An unsuccessful resolution produces no usable lock.

To update the bases, first review the desired public image tags and immutable
index roots in the source file. Generate into a temporary file, then replace the
lock only after the command completes successfully:

```sh
temporary="$(mktemp)"
if go run tools/trusted-runtime-bases/main.go --resolve "$PWD" > "$temporary"; then
  mv "$temporary" .github/containers/trusted-runtime-bases.lock.json
else
  rm "$temporary"
  exit 1
fi
```

Read the selected `manifests` entry from each decoded index and update the two
Dockerfile references to those child digests. Keep the image names/tags equal to
the source declarations. Never edit generated proof bytes. Then run:

```sh
go run tools/trusted-runtime-bases/main.go --check "$PWD"
go test -race tools/trusted-runtime-bases/main.go tools/trusted-runtime-bases/main_test.go
bash tools/trusted-runtime-bases.test.sh
bash tools/trusted-runtime-inventory.test.sh
bash tools/trusted-regression-deadlines.test.sh
```

The checker authenticates metadata, not downloaded layer contents. Docker checks
the layer bytes during the real build. Hosted CI must demonstrate the actual cold
build, engine/image contract, containment, complete trusted scene suite and
cleanup. The default-off [inventory](trusted-runtime-inventory.md) includes the
source declarations, generated lock, checker and wrapper among its fourteen
recipe identities so that the observation can be joined to the tested commit.

This increment does not change APT snapshot policy, independently establish an
expected package closure, publish an executor, authorize a producer or enable
warm reuse. Those remaining decisions belong to
[#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).

The proof follows the OCI [image index](https://specs.opencontainers.org/image-spec/image-index/),
[descriptor](https://specs.opencontainers.org/image-spec/descriptor/) and
[configuration](https://github.com/opencontainers/image-spec/blob/main/config.md)
contracts. Metadata retrieval uses Docker's
[registry API](https://docs.docker.com/reference/api/registry/latest/) and
[token authentication](https://docs.docker.com/reference/api/registry/auth/).
