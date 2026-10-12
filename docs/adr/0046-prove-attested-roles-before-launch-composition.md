# Prove attested roles before launch composition

Status: Accepted for a default-off disposable experiment; production authority unproven.

## Problem

Original custody storage under ADR 0045 proves database exclusion but uses
diagnostic identities. It cannot establish that a caller obtained its own
credential from a workload issuer or that private methods enforce role boundaries.
Issue #1344 closes that assumption before original-child launch composition.

## Decision

Run pinned SPIRE 1.15.3 Server and Agent processes in an explicitly built,
unpublished Linux acceptance image on both native architectures. Use fresh
private issuer state and Unix UID attestation with executable discovery disabled.
Register three distinct unprivileged users as supervisor, custodian and child.
Each process fetches its own X.509 SVID and key from the Workload API; no delegated
identity API, controller-distributed private key or fixture CA supplies a positive.

The image defaults to a non-root user. Only the explicitly enabled disposable
runner selects the root controller. That controller retains its own child process handles and needs only
SETUID, SETGID and KILL. Role processes have empty supplementary groups, no
effective, permitted, inheritable or ambient capabilities, and inherited
no-new-privileges. Issuer state is root-only; the public Workload API socket has
a separate traversable parent. No issuer admin socket is exposed to roles.

Exercise a diagnostic cycle: supervisor calls custodian, custodian calls child,
and child calls supervisor. Both peers verify the SPIRE trust bundle and exact
SPIFFE identity. Only POST /diagnostic is permitted; count effects after transport
authentication and method/path authorization. This endpoint grants no launch,
claim, custody, completion or storage authority. X.509 SVIDs have no audience
claim; expected server identity and method/path permissions are the actual gates.

Require all three positive key-possession controls, all six other role pairs,
an unregistered UID with the specific Workload API refusal, missing and mismatched
private keys, a wrong expected server, and an independently issued credential
with the same principal spelling. The alternative issuer must first succeed
against its own trust bundle. Refusals must leave effect counts unchanged.

Start another legitimate process with the same registered UID and require its
own Workload API fetch and authenticated call to succeed. SPIRE may cache/share
an SVID and key for an entry. Role authorization therefore proves neither an
original process nor an exclusive allocation lifetime. No certificate uniqueness
or launch-ownership claim follows from this positive control.

## Ordering and limits

Issue #1367 adds a separate default-off private-claim interoperability proof. Register a zone
with its sole `/zone/world/uid-1` URI and a distinct claims-server UID with its sole server URI
plus fixed `claims.fixture.test` DNS SAN. Each obtains its own SVID/key. Snapshot that issued
material into ordinary Go TLS: retain DNS and chain verification plus exact server URI
authorization, and use `RequireAndVerifyClientCert` to populate the unchanged handler's actual
verified chains. No callback-only verification or constructed chain evidence substitutes.

Run the real private client and handler over native HTTPS `/v2/claim`, with explicitly synthetic
storage/resolution. Require the originating response and original version/generation receipt,
idempotent replay, independently issued wrong-role/zone/server/root controls, wrong DNS/expected
URI, absent/mismatched keys, and a real URI-only server refusal. Every refusal preserves accepted
effects and storage. Keep malformed multiple-URI parser evidence separate from native issuance.
The fixture does not select production DNS, prove a native Nakama ACK, or compose launch custody.

Require explicit opt-in before creating state or starting any process. Bound
startup, individual requests, suite execution and stop/join. Signal only retained
handles of processes this invocation started. Join every child before removing
private state; failed retirement must fail the trial. The ordinary server/Nakama
graphs, serving images and forty-scenario native suite remain unchanged.

Pin disposable Server-cache and Agent-entry synchronization to one-second
intervals. Socket existence is transport readiness only: every registered role
must fetch its own exact SVID within the unchanged eight-second credential bound.
Decode the unregistered refusal after its joined exit through a controller-owned
pipe; process reaping must not discard its unread response.

The separate experiment is not a production issuer or credential configuration.
Original child ownership is implemented by #1345; authenticated launch-to-custody composition
remains #1346. Protected original acknowledgement custody and an independent
monotonic witness remain #1341/#1336 gates. Production completion stays #1318/#567.
Retire this experiment through #1192 after the separately reviewed composition.
