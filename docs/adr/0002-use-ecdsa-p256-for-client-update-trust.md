# ADR 0002: Use ECDSA P-256 for client update trust

- Status: Accepted
- Date: 2026-07-29
- Decision issue: [#582](https://github.com/devantler-tech/world-at-ruin/issues/582)
- Parent: [#490](https://github.com/devantler-tech/world-at-ruin/issues/490)

## Context

The immutable client shell must verify update manifests, signing-key
certificates, revocation material, and shell authorizations under a public root
key baked into that shell. The update contract already pins the signed bytes to
RFC 8785 JCS, but it also named Ed25519 before the Godot client had a verifier.

The shipped client is a Godot 4.7 GDScript project. Godot's built-in
[`Crypto`](https://docs.godotengine.org/en/stable/classes/class_crypto.html)
API verifies a caller-supplied SHA-256 hash with a `CryptoKey`, and
[`CryptoKey`](https://docs.godotengine.org/en/stable/classes/class_cryptokey.html)
loads RSA or elliptic-curve keys. That API does not expose Ed25519's pure
message-verification operation.

The update root is a recovery boundary. It cannot depend on a hand-written
GDScript implementation of elliptic-curve arithmetic. Adding a native extension
solely for Ed25519 would add a separately compiled and packaged binary to every
desktop target before the pack updater itself exists.

## Decision

All update-trust signatures use ECDSA P-256 with SHA-256 through Godot's
built-in `Crypto` implementation.

The wire contract is fixed:

| Element | Encoding |
|---|---|
| Algorithm identifier | `ecdsa-p256-sha256` |
| Public key | PEM `PUBLIC KEY` containing DER SubjectPublicKeyInfo with `id-ecPublicKey` and `prime256v1` |
| Signed message | UTF-8 RFC 8785 JCS bytes, with the signature field excluded from the object being signed |
| Digest | SHA-256, computed by the verifier from the message bytes |
| Signature | ASN.1 DER ECDSA signature, then canonical RFC 4648 base64 |

`client/scripts/update_trust.gd` is the production verification primitive. It
pins the exact P-256 SubjectPublicKeyInfo prefix before loading a key, rejects
non-canonical base64 and non-DER signatures, hashes the supplied message bytes
itself, and returns success only when `Crypto.verify()` accepts the signature.
Callers never supply a digest.

The same primitive is used for the offline root and short-lived signing keys.
`UpdateTrust.verify_and_decide()` verifies the signing-key certificate with a
caller-supplied offline-root public key, authenticates the embedded revocation
list with that root, refuses a listed certificate id, authenticates the
independently fetched revocation head with the same root and refuses an embedded
list below its published floor, verifies the manifest with only the remaining
certified signing key, and enters `UpdateDecision` last. The head endpoint, its
publication cadence and shell authorizations remain children of #490.

The client still publishes no signing fields and activates no updater. A root
public key, signing custody, revocation publisher, and runtime updater
integration must exist before signed delivery is enabled.

## Verification boundary

`client/tests/data/update_trust_p256_vector.json` carries a fixed signature made
with OpenSSL 3.6.3 and two independently generated P-256 public keys. The
private keys were discarded.

`client/tests/update_trust_test.gd` exercises the production verifier in Godot.
It accepts the independent vector and refuses:

- a one-byte message change;
- a one-bit signature change;
- the same signature with non-minimal DER padding on either integer;
- another valid P-256 public key;
- malformed base64;
- malformed public-key input; and
- a different algorithm identifier.

The vector's message deliberately ends in LF and records its independently
computed SHA-256 digest. The verifier receives those exact bytes; it performs no
newline, JSON, or Unicode normalization.

## Consequences

The trust chain uses a runtime primitive already present in every Godot export,
so it adds no native dependency or platform-specific artifact. P-256 keys and
DER ECDSA signatures are larger and less structurally simple than Ed25519, but
the update path is low-frequency and the representation is fully pinned.

The signer must produce canonical DER signatures and preserve the exact JCS
bytes. A future algorithm change requires a new identifier and an explicit
migration; the existing identifier can never be reinterpreted.
