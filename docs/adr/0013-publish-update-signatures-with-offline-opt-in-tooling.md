# 0013: Publish update signatures with offline opt-in tooling

Status: accepted.

The update publisher uses Go's standard-library P-256 implementation and the client's
integer-only RFC 8785 profile. The existing shared vectors pin UTF-16 key ordering,
minimal escaping and exact numbers. Ambiguous JSON, invalid Unicode, duplicate keys,
oversized input and unsupported numbers are refused before signing.

The operator supplies every key file and an explicit observation time. The tool does
not discover credentials, read environment credentials, contact an endpoint or publish.
An offline root issues signing-key certificates, revocation lists and independent heads.
A leaf can sign a manifest only after the complete root-authenticated chain verifies.
Verification checks signed bytes and current trust evidence; the client decision core
remains the authority for installation compatibility and forward-only admission.

Issuance permits certificate windows through 31 days and head expiry through 24 hours.
These are maximum tooling budgets, not a production rotation or hosting policy.
Verification preserves the existing client's historical signed-window contract.
Operators must obtain the head independently, using the installation's configured
channel endpoint. A head embedded by a manifest signer is insufficient.

Every command requires an explicit experimental opt-in. Outputs are staged privately
and published atomically only to a new path. Existing files and symlinks are refused.
Private keys are unencrypted P-256 PEM files with owner-only permissions and never
appear in output or diagnostics. The tool neither creates nor configures production keys.

Production custody, root installation, head hosting, refresh and rotation procedures,
immutable startup recovery and retained pack targets remain activation prerequisites
tracked by #490, #699 and #1114. The release manifest continues to withhold trust and
delivery fields until their actual production owners are configured and verified.
