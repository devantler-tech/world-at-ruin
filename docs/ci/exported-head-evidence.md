# Exported HEAD evidence

The native export producer publishes the SHA-256 of the archive it actually
built. After the retained-reader, ad-hoc-signature and exported smoke proofs,
that same Mac worker runs the selected exported evidence without allocating a
second Mac. Ordinary build and smoke proof still run when captures are not
selected; missing or unknown selection data is an error.

The capture component is pinned to a reviewed default-branch revision, independent
of the workspace in which the app has already run. Its bytes must match the local
component exercised by the regression suite. Changes to the component therefore
land before a separate workflow-pin update activates them. The component verifies
the archive bytes, immutable integration checkout and clean tracked source before
extracting a fresh evidence app.

The component extracts a fresh app copy and requires fresh save and image paths.
It runs the complete default world, opt-in previews and first-run UI through the
exported entry point. Every capture retains its boot, renderer-error, image,
caption and condition guards. A completion output is emitted only after the
complete image artifact uploads successfully. No cached verdict or old image is
accepted as new evidence.

The smoke app uses its own fresh save, vault, recovery and update-history paths.
The complete capture component retains a fifteen-minute deadline. The stable HEAD
check accepts only a successful native producer and the component's complete-upload
acknowledgement. The independent BASE worker retains its own recipe, source identity
and explicit advisory failure semantics. The terminal comparison requires both
successful producers and exact current integration/run/attempt artifacts before
reporting image differences.

Run `bash tools/exported-head-evidence.test.sh`, the exported-frame report tests,
preview-flag controls and client/native workflow guards after changes. The fast
fixtures prove archive admission and failure propagation, not native rendering.
Actual macOS app capture, artifact inspection and complete hosted timings remain
required before any performance claim.
