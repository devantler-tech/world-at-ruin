# 0016: Check update control documents only with installation authority

Status: Accepted

The experimental installed-client checker starts after the world reaches its boot checkpoint.
It requires `WAR_UPDATE_CHECK=1` and an explicit `WAR_UPDATE_CHECK_CONFIG` path. The configuration
is exact canonical JSON containing `channel`, `manifest_url`, `revocation_head_url` and
`root_public_key`. Only the live channel, distinct unambiguous HTTPS document URLs and one P-256
public root are supported. These facts are copied before asynchronous work. No endpoint or root
is taken from the fetched manifest, and no production configuration is supplied by this repository.

Native HTTPS verifies the CA chain and requested hostname. Redirects, unsafe TLS, hostname
overrides, non-200 replies, bodies over 128 KiB and noncanonical JSON are refused. Both requests
share a ten-second monotonic deadline, including verification. A separately fetched root-signed
revocation head is mandatory before the complete trust chain reaches the update decision core.
Cancellation and detachment refuse the check. Unreadable installed player state also refuses it;
readable state uses conservative reader ceilings so requirements cannot be understated.

This is an advisory check. It does not fetch, stage, mount or promote executable packs and does
not block gameplay when an origin is unavailable. The opt-in native proof uses ephemeral TLS and
signing keys on a loopback listener, with positive trust and intercepted-negative controls.
Production activation and immutable startup recovery remain tracked by #1114.
