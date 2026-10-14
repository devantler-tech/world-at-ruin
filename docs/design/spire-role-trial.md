# Disposable attested-role experiment

Issues #1344/#1367 and [ADR 0046](../adr/0046-prove-attested-roles-before-launch-composition.md)
exercise role issuance and private-claim TLS interoperability behind the server foundation. This is
independent of the forty-scenario native Nakama suite and cannot activate a server.

Build and run on native Linux amd64 or arm64 with Docker:

```sh
docker build --build-arg EXPERIMENTAL=true -f tools/spire-trial/Dockerfile -t war-spire:local .
bash tools/smoke-spire-native.sh war-spire:local --experimental
```

Missing either explicit opt-in refuses. The image defaults to a non-root user;
only the enabled disposable wrapper selects the root credential-switch controller.
The wrapper uses no external network,
no published ports, no host mounts and no shared credentials. The root filesystem
is read-only; state lives in private bounded tmpfs. Only the test controller has
SETUID, SETGID and KILL. Every role checks its real credentials, empty groups,
zero effective/permitted/inheritable/ambient capabilities, no-new-privileges and
permission-denied access to the known-existing issuer state.

SPIRE Server and Agent **1.15.3** come from their official
[release assets](https://github.com/spiffe/spire/releases/expanded_assets/v1.15.3).
The amd64-musl archive SHA256 is
`ca1a4d1155317bdd2afc7f36663828a10410c7c840e54725b90b4064b0a301c7`;
arm64-musl is
`a9982b3ca7de489def22265fd4586d8e13091ecb6fddf6adcea9291313b18886`.
Both binaries are verified before execution. SPIRE and go-spiffe **v2.9.0** use
Apache-2.0 licensing; dependencies and the Go toolchain live solely in this
experiment's module/build graph. No downloaded executable is committed or
included in normal gameplay/Nakama images.

`server/testfixture/spire` supplies the disposable issuer bootstrap mechanism.
The native fixture supplies its exact registrations and retains every started
process, its sole wait owner, stop/join deadlines and private logs. The helper
returns public socket/bundle paths and the private-state refusal path; it exports
no workload key or authority. Socket readiness never substitutes for each
workload's own attested credential fetch. Serving commands do not import it.

Two independent issuer pairs use the same test trust-domain/principal spelling
with separate fresh keys and state. Each role process fetches its own SVID and
private key through its issuer's Workload API. A narrow diagnostic cycle permits
supervisor → custodian → child → supervisor. Both TLS peers verify issuer trust
and the exact SPIFFE ID. Only POST /diagnostic increments the diagnostic counter.
X.509 SVIDs have no audience field; the expected peer and method/path policy supply
these boundaries. Requests use fresh connections without session resumption.

Mandatory native controls cover all three positive roles, six other role pairs,
wrong method/path/query, missing/mismatched keys, wrong expected server, an
unregistered UID's specific PermissionDenied issuer response, and an alternative
valid issuer with identical principal spelling. The alternate credential first
succeeds against its own issuer. Its cross-issuer negative then trusts the original
server bundle while presenting the alternate key, so client-side server rejection
cannot substitute for the original server's rejection of the caller's issuer.
Every refusal retains the authenticated effect count.

A separately started legitimate process with the same registered UID fetches a
valid credential and succeeds. SPIRE can share/cache an SVID and key for this
role. This control proves why role identity alone cannot bind original launch,
process lifetime, allocation ownership, custody or receipt authority.

## Private claim interoperability

A separate native proof registers distinct zone, wrong-zone, claims-server and server-control
UIDs. The zone has the sole URI `spiffe://war-fixture.test/zone/world/uid-1`; the claims server
has the sole URI `spiffe://war-fixture.test/claims/private` and the fixed DNS SAN
`claims.fixture.test`. These names are disposable fixture policy, not production enrollment.
Each worker obtains its own certificate and key through its own attested Workload API connection.
Keys stay in that worker; the controller receives aggregate verdicts and non-secret receipt fences.

The client snapshots its issued chain/key and fetched issuer roots into static TLS material.
Ordinary Go chain and DNS verification stays enabled; an additive check requires the exact server
URI. The owned loopback endpoint uses the fixed TLS server name and does not resolve external DNS.
The server uses `RequireAndVerifyClientCert`, so Go populates actual `VerifiedChains` before the
unchanged private handler applies its one exact zone-URI check. Callback-only SPIFFE verification
cannot substitute for this evidence.

The actual `claimrpc.NewClient` selects `/v2/claim` through `ClaimWithReceipt`. The actual handler
uses the shared **synthetic Nakama storage fake** and a synthetic resolver. The calling process
validates the originating response; the controller compares its version and generation with the
server's stored claim. Replay must preserve that original receipt without another storage write.
This proves TLS and handler/client response interoperability, not native Nakama acknowledgement
provenance, original launch, custody, or completion authority.

Mandatory controls use actual issued supervisor, child, wrong-zone, wrong-server and URI-only-server
credentials, two independent issuer roots, and missing/mismatched keys. Expected DNS and server URI
controls remain independent. Refusals return no receipt and preserve both accepted-claim counts and
the observed storage version/generation. The alternate issuer must also supply its own successful
zone/server positive. A malformed multiple-URI certificate is a separately labelled SDK parser
fixture; it is never presented as an invalid SVID issued by SPIRE.

The wrapper requires both named native proofs and both verdict markers. Missing the private-claim
proof fails acceptance. The ordinary server module is unchanged; only this separate trial module
imports the real client/handler through a local module replacement.

## Deadlines and validation

Server startup is bounded to thirty seconds, role startup/replies to ten seconds,
requests to three seconds, and each native proof to four minutes inside a shared
five-minute test timeout and twelve-minute CI job. Owned process handles receive
TERM, then KILL if needed, with bounded join before private-state removal.
Failed retirement fails the experiment. Issuer logs, bootstrap tokens and
token-bearing CLI replies stay private and are never printed into CI.

The disposable Server cache reload and Agent entry synchronization intervals
are explicitly one second. SPIRE's separate default five-second cycles can leave
an initially empty authorized-entry cache beyond the eight-second credential
bound. Socket existence therefore establishes transport only; each registered
role's own exact SVID fetch establishes its actual readiness. That credential
bound and the single-shot unregistered refusal remain unchanged. Worker stdout
uses an explicitly owned pipe whose bytes survive process exit and Cmd.Wait;
the unregistered control is deliberately decoded only after joined exit.

Local source checks:

```sh
go -C tools/spire-trial test -race ./...
GOOS=linux CGO_ENABLED=0 go -C tools/spire-trial vet -tags=war_spire_trial ./...
cd tools/spire-trial
GOOS=linux CGO_ENABLED=0 govulncheck -test -tags=war_spire_trial ./...
```

CI requires native amd64 and arm64 results and scans the tagged module on PRs and
main. Original-child enforcement is implemented by #1345; launch-to-custody integration
remains #1346; protected acknowledgement pins and independent monotonic witness
remain #1341/#1336. This experiment supplies no production enrollment, completion,
recovery or rollback resistance. #1192 owns its eventual retirement.
