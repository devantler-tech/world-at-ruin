# 0022: Prove the native Nakama runtime with disposable storage

Status: accepted

The native trial builds the pinned Nakama 3.40 server and World at Ruin Go plugin
from one separate, locked dependency graph. That graph selects the runtime API
1.47 implemented by the pinned server. The ordinary server module keeps its own
runtime API 1.48 selection; compiling a plugin under that graph does not certify
that the packaged Nakama process can load it.

Both artifacts use Go 1.27.1, native CGO, and matching shared-package build flags.
The builder refuses implicit execution, existing output and missing locks. It
uses read-only module resolution, verifies the locks remain unchanged, and
records toolchain, architecture, graph hashes and artifact hashes. The native
trial additionally requires a deliberately incompatible plugin to fail loading.
The full native server and plugin are scanned for reachable vulnerabilities.

The explicitly experimental acceptance image is unpublished and runs as UID
10001. Its private fixture network contains disposable PostgreSQL and generated
allocator/Kubernetes API fixtures. PostgreSQL receives a new, unpredictable
trial database per scenario; existing caller databases are never migrated.
The process is joined before its database and dependency fixtures are retired.
Fixture credentials live only in the disposable container and its temporary
files. Ordinary invocation refuses the missing opt-in.

Acceptance uses actual Nakama session authentication, HTTP RPC and native private
storage. It checks system-owner rows and native versions directly, including
concurrent requests, retained PostgreSQL across process restart, private mutual-TLS
claims, periodic no-show cleanup, storage pagination beyond 100 rows, historical
reader-only protection, orphan grace and actual SIGTERM shutdown hooks. A public
same-key storage write may create a separate player-owned row; privacy is proved
by the system-owned row remaining hidden and unchanged.

CI executes these scenarios on native Linux amd64 and arm64 runners. Both results
feed the required CI aggregate in the pull-request and merge-group workflow.
The build tag selects the separate acceptance binary; it is not a silent skip
inside the ordinary unit suite. Missing fixture inputs fail that binary.

This artifact proves source composition against disposable providers. Production
activation, retained serving artifacts, platform rollout, attested certificate
issuance, irreversible session authority and allocator fencing remain separate
acceptance gates. The trial does not publish, deploy or enable any live feature.
