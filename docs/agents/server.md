# Server — native acceptance, allocator experiments and validation

> Part of the [AGENTS.md](../../AGENTS.md) contract. Read it before any `server/`, native-trial
> or allocator change.

## Native acceptance

- **Native Nakama acceptance:** the separate generated `server/nakama-runtime/go.mod`/`go.sum`
  graph builds Nakama 3.40 and its WAR plugin with runtime API 1.47, exact Go 1.27.3
  and native CGO. Keep the ordinary server graph intact. The explicitly experimental
  `server/Dockerfile.nakama-native` image is unpublished;
  `tools/smoke-nakama-native.sh <local-image> --experimental` requires every named
  scenario against fresh disposable PostgreSQL databases, including the built
  sealed zone, native private claims, actual TLS WebSocket replication and opt-in
  authoritative movement, complete read-only journal observations and the joined
  durable registration/real API barrier controls, recovery-owner exclusion and
  complete fresh-process recovery fencing. The sixteen-minute suite budget keeps
  every individual RPC, stage and process deadline unchanged. Both native Linux
  architectures feed the required CI aggregate. The tagged process suite fails
  on missing inputs rather than skipping. See `server/nakamaruntime/README.md`
  and ADRs 0022–0024; production activation and build-flag retirement remain #1177/#1192.
- **Static claims material:** `InitializeWithClaimsMaterial` explicitly accepts
  bounded inspectable DER, a retained signing handle and independently pinned
  server DNS/URI expectations under the existing handoff/claims opt-ins. It
  clones/reparses certificates and verifies chain, purposes, signer, exact
  identity and allocator-key separation before reserving the listener. Current
  ordinary and existing native plugin entries keep projected credentials. The existing registration, rollback
  and actual-drain owner applies; no watcher, refresh or adoption authority is
  added. Run `go -C server test -race -count=1 -timeout 5m ./nakamaruntime`
  and the required native suites. This establishes fixture-backed material/TLS
  adaptation, not successful issuer/native custody composition or gameplay
  admission. #1374/#1346 and retirement #1192 remain open. See ADR 0052 and
  `server/nakamaruntime/README.md` for bounds and signer-lifetime limits.
- **Issued native runtime compatibility:** the separate nested
  `server/nakama-issued-runtime` module selects Nakama 3.41/runtime API 1.48,
  SPIFFE SDK 2.9.0 and gRPC 1.84. The fixed `issued` builder profile records
  nested and inherited server locks, checks SDK presence in the compiled
  plugin and preserves the old native and normal graphs. Both native architectures
  require all 41 storage scenarios plus actual SDK unavailable-issuer startup
  refusal; ordinary plugin builds exclude SDK dependencies and native writers.
  `WAR_ISSUED_SDK_PROBE_ENABLED` is default-off. Its enabled diagnostic request
  precedes initialization and always refuses serving authority, even on success.
  Build with `RUNTIME_PROFILE=issued`; run the native wrapper with `--issued`.
  This establishes compatibility and SDK failure behavior only. Successful
  issuance/native custody remains #1374, gameplay admission #1346 and retirement
  #1192. See ADR 0051 and `server/nakamaruntime/README.md`.
- **Issued claims entry:** only the distinct issued plugin recognizes the strict
  default-off `WAR_ISSUED_CLAIMS_ENABLED` switch. Both handoff/claims switches
  must also be true. One explicit Unix WorkloadAPI SDK fetch is bounded to three
  seconds/256 KiB and closes before shared probe/claims initialization. Independently
  pin expected DNS/URI; the fixed material listener still validates trust and keys.
  No projected claims fallback, refresh or second shutdown owner. Run issued-entry
  source race tests and both required issued native architecture suites. Their
  new positive/refusal/receipt/replay/shutdown proof uses a synthetic issuer that
  transfers fixture keys, not real workload attestation. #1374/#1346 retain the
  actual SPIRE/custody/admission outcomes; #1192 retires this switch. See ADR 0053.
- **Native SPIRE role acceptance:** the separate `tools/spire-trial` module
  and unpublished image require explicit experimental build/run opt-in.
  `server/testfixture/spire` owns only disposable issuer bootstrap. Its caller
  supplies registrations and retains all process handles, wait/join ownership,
  containment and deadlines; serving commands never import the helper. Pinned
  SPIRE Server/Agent attest three distinct unprivileged UIDs, each fetching its
  own Workload API SVID/key. The controller has only SETUID/SETGID/KILL; roles
  retain no effective/permitted/inheritable/ambient capabilities. Both native
  architectures are required by CI. Diagnostic mTLS enforces the exact caller,
  expected server and POST /diagnostic, with issuer/key/refusal controls and
  joined cleanup. A separate required native private-claim proof fetches each zone/server
  credential in its own process, snapshots static TLS with ordinary DNS/chain verification
  plus exact server URI authorization, and uses `RequireAndVerifyClientCert` so the unchanged
  handler sees real verified chains. The real v2 client/handler response and replay are checked
  against explicitly synthetic storage. Issued role/zone/server/root and key controls preserve
  zero accepted effects; malformed multiple-URI evidence stays parser-only. Both native proofs
  and their complete verdicts are mandatory. The same-role second-process positive establishes no original
  process or launch ownership. See ADR 0046 and `docs/design/spire-role-trial.md`;
  #1345 supplies the independent original-child outcome; #1346 and #1341 remain separate gates.
- **Issued startup stability measurement:** the manual
  `.github/workflows/issued-native-stability.yaml` binds reviewed main source and
  runs ten fresh complete issued-SPIRE trials per native architecture against one
  immutable local image. Any failed process, observation or cleanup stops the
  measurement; no later pass clears it. Keep ordinary CI and inner deadlines intact.
  Validate its driver and workflow with `tools/issued-native-stability.test.sh`
  and `tools/issued-native-stability-workflow.test.sh`; real evidence requires the
  manual two-architecture run described in `server/nakamaruntime/README.md`.
- **Real issued claims with native storage:** the separate `issued-spire` image
  profile compiles `war_issued_spire` acceptance only in the issued dependency
  union. Run `bash tools/smoke-nakama-native.sh <local-image> --experimental --spire`.
  Its bounded disposable controller uses only SETUID/SETGID/KILL; existing native
  and issued suites retain their unprivileged profiles. The claims-UID worker
  owns the native fixture and Nakama child; a distinct zone UID is registered
  from the actual handoff and retains its own fetched key. Both architectures
  require actual plugin readiness, verified TLS refusals with unchanged SQL,
  complete native receipt/replay comparison and acknowledged descendant cleanup
  before exact joins. The six-minute profile budget is separate from the
  unchanged sixteen-minute native suites. Source vet and tagged vulnerability
  checks include the combined graph. Default invocation refuses before state.
  The same profile also requires all nine original enrollment/receipt/custody
  cuts, with a fresh issuer per case and issued snapshots in every original,
  reader and refused restart process. Only the original GET triggers the sole
  claim; correlated private IPC has a five-second bridge bound. Snapshot logs
  precede full listener validation and grant no authority. #1192 owns retirement;
  protected forwarding, gameplay admission and the independent witness remain
  #1346/#1341. See ADRs 0054–0055.
- **Native owned-child acceptance:** the separate `tools/owned-child-trial`
  module/image requires explicit build and run opt-in. Its trusted controller
  uses the existing SETUID/SETGID/KILL profile; every diagnostic sender has empty
  supplementary groups, matching real/effective/saved IDs, no capabilities and
  no-new-privileges. Launch-time pidfds and per-message seqpacket credentials
  distinguish the original child from same-user transferred/inherited socket
  senders. Both native architectures, source race/lint and the actual tagged
  test vulnerability graph are required. Run
  `bash tools/smoke-owned-child-native.sh <local-image> --experimental`;
  `bash tools/native-private-server-harness.test.sh` checks both private-server
  wrappers. Trusted startup adds process-wide TSYNC exec denial before diagnostic
  admission. Both raw return and errno must be zero. Native existing/future-thread
  exec controls, divergence/error refusals, wrong-policy SIGSYS and explicit ABI
  evidence limits are required. Raw fork descendants stay entirely in audited native
  assembly and report through a private atomic pipe record. Require exact parent mask
  restoration, sender exclusion, launch-time child pidfds, exact terminal wait,
  failed-observation controls and a separate parent-death containment refusal.
  See ADRs 0047–0049 and `docs/design/owned-child-trial.md`.
  This is a diagnostic process boundary, with no serving caller or publication.
  This supplies #1345's original-child outcome; custody composition and witness authority remain
  #1346/#1341. Retire the experimental tooling through #1192 after adoption.

## Allocator and recovery experiments

- **Allocator fence reference:** `server/internal/fencereference/` is default-off,
  owns only an in-memory ledger and is not imported by production composition.
  Its generation check and owned mutation share one authority lock; its real TLS
  generated Allocate RPC tests must show an unfenced late commit and a fenced
  refusal, including canceled/deadline-expired requests. Run
  `go -C server test -race -count=1 -timeout 2m ./internal/fencereference`.
  Follow [ADR 0012](../../docs/adr/0012-keep-allocator-fence-authority-at-the-commit-boundary.md):
  process-local receipts cannot authorize native Agones writes, durable recovery
  or production quarantine release. Production fencing remains #793 work.
- **Exact GameServer commit experiment:** `server/internal/gameservercommit/`
  remains explicitly enabled only by tests, outside production composition.
  Run `tools/test-gameserver-commit.sh` for the required real kube-apiserver/etcd
  proof with the pinned Agones CRD, plus `go -C server test -race -count=1
  ./internal/gameservercommit ./internal/fencereference` for capability and import
  guards. [ADR 0028](../../docs/adr/0028-fence-an-inactive-exact-version-gameserver-mutation.md)
  binds receipts to one frozen UID/version mutation and its process incarnation.
  Changed histories remain unknown; no receipt releases production quarantine.
  `gameservercommit.Generation` privately owns the complete issued capability set
  under one immutable open generation observation. It closes preparation and
  commit admission before networking, and accepts a process-local receipt only
  after every issued capability has an acknowledged exact storage barrier.
  Partial proofs leave admission closed without a receipt; barriers are not
  retried. The real-storage trial includes multiple held writes, canceled callers,
  mixed allocation outcomes and incomplete-proof controls. Actor membership is
  attribution, not authenticated exclusive allocator authority. See
  [ADR 0031](../../docs/adr/0031-close-the-complete-issued-gameserver-capability-set.md)
  for the durable journal, recovery and retained-reader activation gates.
  Its explicitly enabled `JournalReader` reads a complete, private exact-version
  inventory against independently pinned generation, membership, incarnation and
  issued-set expectations. The StorageRead-only interface cannot write journals.
  The shared read-only leaf also supplies the default-off Nakama startup probe.
  Source and candidate readback are diagnostic data and cannot recreate grants or receipts.
  The native trial demonstrates that journal readback alone leaves unfenced old
  writes able to allocate and that a fresh owner rejects a prior receipt.
  [ADR 0032](../../docs/adr/0032-read-issued-grant-journals-without-restoring-authority.md)
  keeps journal writers and serving-reader/retained-artifact activation separate.
  [ADR 0035](../../docs/adr/0035-observe-journals-through-the-packaged-nakama-candidate.md)
  adds native candidate readback while preserving those activation gates.
- **Complete native acceptance:** native and issued CI profiles opt into four isolated
  same-image workers on both architectures. The real compiled inventory, exact disjoint
  verdict union and owned container/database/network retirement must all complete before
  success. Keep the one-worker default and the independent serial issued-SPIRE profile;
  never cache a test verdict or shorten scenario deadlines to meet a feedback target.
  Run `bash tools/nakama-native-harness.test.sh` and
  `bash tools/native-acceptance-workflow.test.sh`; these hermetic controls do not replace
  real hosted native timing and correctness evidence. See [ADR 0061](../../docs/adr/0061-partition-complete-native-acceptance.md).
- **Durable admission experiment:** `server/internal/allocatoradmission/` uses one
  private generation-wide conditional document for registration and irreversible drain.
  Snapshots are diagnostic and cannot release quarantine or restore capabilities.
  Only the explicitly built native trial plugin composes the startup writer;
  normal plugin artifacts have no writer import or activation path. Run `go -C server
  test -race ./internal/allocatoradmission ./internal/nakamaadmissionprobe` and the
  amd64/arm64 native acceptance for actual Nakama CAS, competing incarnations,
  registration/drain races and committed writes with lost replies. See
  [ADR 0036](../../docs/adr/0036-serialize-durable-grant-registration-and-drain.md).
  Production authority, retained-reader adoption and real barrier recovery remain #793 gates.
- **Durable capability composition:** `gameservercommit.NewDurableGeneration` derives
  registration from its private frozen grant, retains the original actor/attempt/UID/version,
  and exports only after the native admission acknowledgment while still locally open.
  A separate bounded storage gate never delays local closure. Registered-but-unexposed
  grants enter the complete drained/barriered set; unknown writes close the owner without
  retry, refresh or restoration. The native-only `nakamacapabilityprobe` requires
  `WAR_DURABLE_GENERATION_PROBE_ENABLED=true` and private local fixture inputs.
  Normal builds exclude both the probe and capability composition. Run the capability
  race suite, the production import guards and the amd64/arm64 native acceptance.
  The latter joins actual Nakama transactions and held real kube-apiserver/etcd writes,
  including late acknowledgments and committed registrations with lost replies.
  [ADR 0037](../../docs/adr/0037-register-frozen-capabilities-before-exposure.md) preserves
  independent recovery #1315 and production authority #793 as separate gates.
- **Durable handoff experiment:** `Generation.CloseForRecovery` selects handoff
  instead of barriers, closes before networking and accounts for pending registration.
  Only the originating writer's acknowledged drain can publish once; lost replies
  export no pins. `ReadHandoff` uses a StorageRead-only interface with independently
  retained original root binding and handoff version. Its default-off native probe,
  `WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED`, is retired by #1316. Both native
  architectures exercise source termination, fresh readback and an original held
  PUT that still returns HTTP 200 with zero barriers. Handoff readback does not
  restore grants, receipts or quarantine release; barrier recovery remains #1315.
  See [ADR 0038](../../docs/adr/0038-retain-an-acknowledged-drain-handoff.md).
- **Recovery-owner experiment:** `allocatoradmission.NewRecoveryOwner` freezes independently
  retained original pins. One read-and-create attempt has a shared deadline; a private
  generation-wide create-only row arbitrates all owner IDs. Only its exact ACK produces
  a process-local reservation; detached diagnostics and the permanent schema-1 reader
  cannot reconstruct it. Copies share the same consumed attempt. Unknown replies or
  owner death never permit retry, refresh, expiry, takeover, deletion or resumption.
  The native-only `WAR_DURABLE_RECOVERY_OWNER_PROBE_ENABLED` defaults off and is retired
  by #1316 with its ID, scenario, control and retained-pin inputs. Both architectures
  exercise two actual competing Nakama processes, source/owner death cuts, lost/canceled
  ACKs and changed original documents. The held old PUT still allocates with zero
  barriers. Production authenticated pin custody and independent barrier recovery
  remain #1315/#793 gates. See
  [ADR 0039](../../docs/adr/0039-reserve-one-acknowledged-recovery-owner.md).
- **Fresh recovery barriers:** `gameservercommit.NewRecovery` accepts only an opaque
  live acknowledged reservation. Copies and independent wrappers share one terminal
  consumption before the first Kubernetes read. One bounded attempt derives every
  target from the complete original handoff and emits only metadata barriers; exact
  ACKs and readbacks preserve observed Spec/Status and original actor/attempt/UID.
  Only complete success exports a process-local result. Unknown or partial results
  cannot retry, resume, reconstruct receipts or release quarantine. The native-only
  `WAR_DURABLE_RECOVERY_FENCE_PROBE_ENABLED` defaults off, with ID, scenario, control,
  material and original-pin inputs; #1316 owns retirement. Both native architectures
  exercise two actual targets, mixed outcomes, competing owners, omitted inventory,
  lost/canceled replies, death after submission/ACK and death after final accepted
  readback before supervisor export. Complete-proof publication uses the separate
  experiment below; production authenticated custody remains a #1315/#793 gate. Run the capability race
  suite, native probe tests, normal-artifact import guards and full native acceptance.
  See [ADR 0040](../../docs/adr/0040-fence-the-complete-acknowledged-recovery-inventory.md).
- **Complete recovery publication:** `gameservercommit.NewRecoveryPublisher` accepts
  only the live originating complete result. Copies and independent wrappers consume
  one shared publication attempt before storage I/O. One private generation-scoped
  create-only proof needs exact ACK and private same-version readback of complete
  evidence, with original owner/handoff/root pins verified. Ambiguous replies and
  restart never restore publication or allocation authority. The permanent strict
  reader returns diagnostics only from independently retained complete pins.
  `WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ENABLED` defaults off; its ID, scenario,
  control, private material, original pins and publication-pin inputs are retired by
  #1316. Both native architectures join two actual targets, mixed results, independent
  publisher races, changed proof contents, reply loss, cancellation and four actual
  process-death seams through native storage. Production authenticated durable custody,
  exclusive authorization, serving/retained reader adoption and quarantine release
  remain #1315/#793 gates. Run the full capability race suite, native probe tests,
  fourteen-family storage-history guard and all required native scenarios.
  See [ADR 0041](../../docs/adr/0041-publish-an-acknowledged-complete-recovery-proof.md).
- **Claim lifetime after zone death:** the native acceptance includes the exact owned
  zone's kill/join during a PostgreSQL-held claim, ordinary disconnect cancellation,
  and a bounded transparent mutual-TLS transport that permits the original request
  to commit after its zone exits. Late unacknowledged and acknowledged claims must
  remain unchanged across native restart, public handoff refusal and active cleanup
  of an unclaimed canary. Run both native architectures and the ordinary transport
  race controls. These test-only observations capture no original completion receipt
  and grant no session-end authority. [ADR 0020](../../docs/adr/0020-retain-exact-claim-receipts-for-private-completion.md)
  keeps independent production authority and protected receipt custody under #1318.
- **Movement authority after watch loss:** mandatory native acceptance suspends the exact
  owned zone child, observes its stopped state through Linux procfs, ends the generated
  SDK watch and resumes that same child. Repeated fresh admission must return HTTP 401
  before handoff expiry while health continues; the original v3 socket must apply a
  never-used post-resume sequence at a newer tick with bounded actual movement. The
  original private claim bytes/version and private TCP connection count stay fixed.
  The count is connection-scoped and does not establish zero private RPCs. Fixture
  cleanup resumes stopped children and bounds cooperative shutdown and kill/join;
  the socket reader is separately canceled and joined. Run both native architectures
  and the ordinary stopped-child cleanup race control. This experiment proves watch
  loss, not Pod/node deletion or production session-end authority; #1318 stays open.
- **Allocator peer transport:** `server/allocatorpeer/` is opt-in and has no production caller.
  Run `go -C server test -race -count=1 -timeout 2m ./allocatorpeer` for native mutual-TLS
  allocation, source/readiness changes, lost responses and the production-import guard.
  Test setup first proves a complete bidirectional exchange on each owned private
  candidate under a bounded budget, closes and joins unsuccessful probes, and
  retains the same still-bound listener for TLS. Missing transport fails with a
  sanitized explicit prerequisite error; it never skips or relaxes the TLS proof.
  [ADR 0018](../../docs/adr/0018-observe-pinned-generations-before-authenticated-allocator-calls.md)
  keeps bindings observational: no allocator error or discovery result grants quarantine release.

## Server save history and update publication

- **Server save history:** every persisted server schema uses
  `server/<package>/testdata/shipped_<family>_versions.txt` and
  `golden_<family>_v<N>.json`. The server durability check discovers ledgers in both the reviewed base
  and candidate tree, preserves all historical fixture bytes, validates complete additions, and refuses
  any Nakama collection literal in production Go files without its own family ledger in the same
  package. Each ledger has a sibling `shipped_<family>_collection.txt` containing the exact collection
  name; mappings are immutable once shipped, and independent schemas may share a collection.
  `server/persisted-write-sites.txt` separately binds each production `StorageWrite` method reference
  and imported `playerstate.RecordWrite` reference to its schema ledger(s), by source file, enclosing
  receiver/function, boundary and ordinal. Missing, stale or duplicate registrations fail. This includes
  imported collection constants, method values, closures, package initializers and aliased imports;
  persistence-boundary dot imports are refused. The collection-literal scan remains an additional check.
  This inventory is a review tripwire, not semantic schema inference: multiplexing formats inside an
  existing site, type aliases or a new persistence API still require explicit schema-owner review and
  complete family registration. New persistence boundaries must extend the scanner before use.
  Run `BASE_SHA=<reviewed-base> ./tools/google-binding-durability-guard.sh` from the repository root
  and its adjacent `.test.sh` regression suite. Each family also names its exact historical Go test,
  production source file and raw-JSON decoder function in `shipped_<family>_reader.txt`. The guard compiles the
  package test binary, requires that test to pass without skips and cover the named production reader,
  then marks each private fixture with harmless internal JSON whitespace. The marked control must pass;
  returning zero values only for marked decoder input must fail the same test. Corrupting each fixture
  must also fail. These probes bind fixture input and reader-output assertions; they do not certify
  every field or array shape. `tools/server-reader-contract.test.sh` exercises that registration.
  Store tests retain the semantic assertions:
  character, binding and audit tests assert preserved fields; lease fixtures retain each shipped shape's fields
  alongside separate transition tests. Fixture immutability alone does not prove lossless reading.
  Follow [the server save-data contract](../../docs/design/server-save-data.md) for schema changes.
- **Offline update publication:** `server/cmd/updatepublisher` requires `-experimental` for every operation.
  It is not imported by runtime composition and does not configure or publish production keys.
  Run `GODOT_BIN=godot bash tools/test-updatepublisher.sh` after the client import to prove
  actual command output reaches the native verifier. See
  [offline publication](../../docs/design/offline-update-publisher.md) and ADR 0013.

## Validate the server

- **Validate the server before every PR:** from `server/`, `gofmt -l .` (must print nothing),
  `go vet ./...`, `golangci-lint run ./...`, `go test -race ./...` (includes the tick-determinism
  and golden-hash tests), `go build ./...`, and `govulncheck ./...`; run `govulncheck ./...` from
  `.github/scripts/release-credential-boundary/` too. CI installs the pinned scanner and runs both
  modules under the exact Go toolchain each `go.mod` declares. The pull-request and merge-group
  matrix feeds `CI - Required Checks`; `go-vulnerability-scan.yaml` repeats the same two scans on
  every `main` push so an advisory published after merge makes branch health red. The `Server CI
  (Go)` job runs the format, vet, lint, test and build commands above. `server/.golangci.yml` enables
  a correctness-focused linter
  set by name — the classes that bite a process expected to stay up (an unchecked error return, a
  response body never closed, a request with no context, an unguarded integer conversion on the
  wire) — rather than inheriting a default set. It covers the **whole module**, so every finding
  blocks wherever it is: an untouched file cannot hide a regression, and deleting a safeguard
  (a `defer resp.Body.Close()`, a context, an error check) fails the gate even though the
  diagnostic lands on a line the change did not edit. Do not silence a
  finding with `//nolint` — fix it, or if it is genuinely wrong, record the exclusion in the config
  with the reason. Simulation determinism is a product-law requirement: the sim is integer-only with no
  wall-clock or unseeded randomness in the authoritative path, and changing the committed golden
  hash (`server/sim`) is a deliberate, reviewed act — never a rubber-stamp.
