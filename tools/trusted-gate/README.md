# Historical App-overlap inspector

This read-only diagnostic retains the complete overlap checks from the unactivated
App-publisher design in [ADR 0027](../../docs/adr/0027-bind-repository-protection-to-independent-verdicts.md).
The resolver, publisher and their workflow are retired.
[ADR 0062](../../docs/adr/0062-retire-unused-app-publisher-after-shared-admission.md)
records the active shared reviewed-base runner and native adoption evidence.

## Commands

```sh
go -C tools/trusted-gate test -race -count=1 ./...
go -C tools/trusted-gate vet ./...
# Explicit read token; numeric ID of the historical organization App.
go -C tools/trusted-gate run . inspect --app-id <org-app-id>
```

Inspection reads every ruleset page and joins full live details. Only the exact
historical active repository context/App/default-branch rule with no bypass,
alongside the unchanged active original organization rule, produces
`protection_overlap_verified=true`. It also emits `activation_ready=unknown`:
rule shape never proves credential confinement or native behavior.

The old rule is now disabled and the App alternative was not activated. This
historical overlap diagnostic is therefore expected to refuse; that refusal does
not imply the active shared runner is broken. It does not verify today's shared
workflow or executed-result bindings. Missing, partial, unreadable or ambiguous
observations still exit unsuccessfully; no summaries substitute for full details.

Only body-free GET requests are permitted. Retired `resolve` and `publish`
commands always fail before network or output-file effects, regardless of old
activation variables. Nothing here changes protection, App permissions, secrets
or configuration. No activation procedure remains in this tool.
