# 0018 — Observe pinned generations before authenticated allocator calls

Status: accepted

## Context

Private generation storage, complete allocator discovery and the Agones allocation
boundary have distinct responsibilities. A transport must preserve the selected
incarnation without treating discovery or an allocation error as fence authority.

## Decision

The opt-in `server/allocatorpeer` library connects a caller-pinned generation and
selected Pod UID to one literal socket. Its trusted map includes every generation
member's server name and distinct server SPKI fingerprint. These identities come
from independent operator trust, never from Pod metadata or coordinator credentials.

The constructor owns parsed copies of bounded root certificates, client certificate
chain and PKCS#8 key bytes. TLS 1.3 performs normal chain and hostname verification
before the selected server key is checked. No custom caller TLS configuration,
callbacks, session cache, alternate clock or key-log writer is accepted. Channel
authority carries the trusted server name; an owned dialer targets only the selected
IP and port, bypassing DNS, proxies and service-config routing.

Each bounded operation reads the complete private generation and complete discovery
before connecting, repeats both after readiness, and refuses a changed observation.
Endpoint order is deterministic within the selected UID. There is no alternate
member or endpoint fallback. Existing allocation request and response validation
remains responsible for pool identity, correlation and sealed admission material.

Every failure after invoking Allocate is uncertain. Even an empty-pool answer
cannot prove that a native write will never land. Errors expose no terminal
unallocated sentinel or upstream text; cancellation, deadline and status code remain
available. No positive result or binding accompanies a failed operation.
Canceled and DeadlineExceeded RPC statuses retain the corresponding standard
context error identity even when they arrive before the caller's own timer.
That identity describes the interrupted RPC; it does not prove the caller
context itself is done or that no allocation effect occurred.

Configured RPC retries are disabled and the retry buffer is zero. In the pinned
gRPC unary implementation, sending the nonempty request commits the attempt before
the response is read, so response loss cannot replay that dispatched payload.
Native controls close the authenticated connection after an effect while leaving
the listener available and observe exactly one handler and effect. Transparent
retries may still occur during stream creation before request DATA. This library does **not**
provide at-most-once execution across operations or restarts. The coordinator must
retain its durable dispatched-attempt barrier and quarantine on ambiguity.

## Consequences

Generation and resource versions are observations, not atomic admission tokens.
A change may occur after the last read. No receipt here fences the allocator's
native Kubernetes commit, proves process termination or permits quarantine release.
Production entrypoints do not import the library; an AST guard prevents accidental
activation. Native tests compose the real generation decoder, namespaced HTTPS
discovery and generated mutual-TLS Allocate RPC with private hermetic services.
Their storage backend is in-memory and their API server is a fixture. They do not
prove a deployed Nakama, Kubernetes or Agones integration.

The commit-boundary and durable incarnation recovery work in #793, and the live
provider evaluation in #569, remain required before production fencing is enabled.
