# Refuse unexpected packages in a trusted runtime

Status: accepted for cold-build identity checking; runtime reuse is not adopted.

The fixed Linux base and ten exact direct APT arguments do not themselves fix
the complete transitive installed package result. A diagnostic inventory records
what happened but cannot reject drift without a separately reviewed expectation.

Generate a complete sorted package lock from a successful source-bound cold
inventory. Bind its name/version/architecture identities to the exact Ubuntu
manifest, snapshot declaration and actual direct install pins. Preserve the
existing APT transaction: naming every inherited package explicitly would change
manual/automatic state and can request versions absent from an older snapshot.

The host checks the lock and prepares canonical installed-state TSV in its private
build context. Every cold build compares a complete successful dpkg observation
with that expectation before returning an executor. The mandatory check follows
the APT layer, so changing the expectation can reuse that layer. Diagnostic
selection cannot bypass the invariant. Both host checking and Docker retain the
existing build deadline, base proofs, package authentication and engine boundary.

This proves an expected installed identity set. It does not independently
authenticate archive bytes, establish selected snapshot URI provenance, authorize
a producer, admit a cached executor or demonstrate warm savings. APT retains its
normal signature, validity and HTTPS checks. Those remaining reuse requirements
stay with #1397. A build-time invariant has no bypass flag.

Local failed-observation controls complement a native changed-expectation refusal
on the actual cold image and the full containment and trusted scene verdicts.
