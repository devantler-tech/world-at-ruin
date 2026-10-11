# Disposable attested-role experiment

Issue #1344 and [ADR 0046](../adr/0046-prove-attested-roles-before-launch-composition.md)
exercise the issuer assumption behind the private server foundation. This is
independent of the forty-scenario native Nakama suite and cannot activate a server.

Build and run on native Linux amd64 or arm64 with Docker:

```sh
docker build --build-arg EXPERIMENTAL=true -f tools/spire-trial/Dockerfile -t war-spire:local .
bash tools/smoke-spire-native.sh war-spire:local --experimental
```

Missing either explicit opt-in refuses. The wrapper uses no external network,
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
Both binaries are verified before execution. SPIRE and go-spiffe **v2.7.0** use
Apache-2.0 licensing; dependencies and the Go toolchain live solely in this
experiment's module/build graph. No downloaded executable is committed or
included in normal gameplay/Nakama images.

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

Server startup is bounded to thirty seconds, role startup/replies to ten seconds,
requests to three seconds, and the native suite to four minutes inside a
five-minute test timeout and twelve-minute CI job. Owned process handles receive
TERM, then KILL if needed, with bounded join before private-state removal.
Failed retirement fails the experiment. Issuer logs, bootstrap tokens and
token-bearing CLI replies stay private and are never printed into CI.

Local source checks:

```sh
go -C tools/spire-trial test -race ./...
GOOS=linux CGO_ENABLED=0 go -C tools/spire-trial vet -tags=war_spire_trial ./...
cd tools/spire-trial
GOOS=linux CGO_ENABLED=0 govulncheck -tags=war_spire_trial ./...
```

CI requires native amd64 and arm64 results and scans the tagged module on PRs and
main. Original-child enforcement remains #1345; launch-to-custody integration
remains #1346; protected acknowledgement pins and independent monotonic witness
remain #1341/#1336. This experiment supplies no production enrollment, completion,
recovery or rollback resistance. #1192 owns its eventual retirement.
