# World-owned regression publisher

This standard-library Go tool resolves proposed World changes independently,
publishes through the existing organization App, and inspects protection overlap.
[ADR 0027](../../docs/adr/0027-bind-repository-protection-to-independent-verdicts.md)
defines the publication boundary. Established organization enforcement remains
active; this replacement is default-off.

## Commands

```sh
go -C tools/trusted-gate test -race -count=1 ./...
go -C tools/trusted-gate vet ./...
# Explicit read token; numeric ID from the existing organization APP_ID variable.
go -C tools/trusted-gate run . inspect --app-id <org-app-id>
```

`inspect` reads every ruleset page and joins full live details. Only the exact
active repository context/App/default-branch rule with no bypass, alongside
the unchanged established organization rule, produces
`protection_overlap_verified=true`. It also emits `activation_ready=unknown`:
protection shape does not establish credentials, App permissions or live canaries.
Missing protection is not ready; unreadable, partial or ambiguous observations
are unknown and exit unsuccessfully. Inspection never changes settings.

When `WAR_REPOSITORY_TRUSTED_GATE_ENABLED` is `true`,
`resolve --run-id <id> --output <path>` and
`publish --identity <resolved-json> --verdict <pending|failure|success>` require
the canonical `workflow_run` source, exact workflow SHA and an explicit scoped
token. Unset or `false` emits `admitted=false` before validating the source or
token, resolving the App ID, decoding candidate identity or publishing. Other
flag values are refused. Successful
publication re-resolves the evaluated identity and verifies the API
acknowledgement and fresh App/name/head/status/conclusion readback.

## Publisher prerequisites

Reuse the existing organization configuration: `APP_CLIENT_ID` and
`APP_PRIVATE_KEY` mint the token, while numeric `APP_ID` binds admission and
check readback. No World-specific App ID or private-key secret is required.
Activation requires the `world-trusted-gate-publisher` environment to permit
deployments from `main` only; read back its live branch policy before enabling
the producer. The environment needs no separate App key. The evaluator remains read-only
and receives no App key. The requested token is limited to World at Ruin with
Checks write and Actions, Contents and Pull Requests read.

A main-only job does not confine an organization secret used elsewhere. Another
workflow with the shared key and suitable App permissions can publish the same
App/context; neither client ID nor App binding authenticates workflow origin.
Verify actual permission and credential boundaries and the live tamper canaries
on #746 before any cutover. Source preparation changes no App permission,
credential, activation flag or active ruleset.

Keep `WAR_REPOSITORY_TRUSTED_GATE_ENABLED` unset until activation prerequisites
are read back. Observe actual frozen scenes and positive/negative canaries under
established protection before introducing a repository requirement. Retiring the
old rule and central game workflow requires reviewed overlap and release readback.
Turning the producer off while its verdict is required blocks merging; restore
and verify established protection before any recovery change.
