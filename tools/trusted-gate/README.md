# World-owned trusted regression gate

This standard-library Go tool resolves proposed World changes independently,
publishes a dedicated App verdict, and inspects the protection needed for safe
cutover. [ADR 0027](../../docs/adr/0027-bind-repository-protection-to-independent-verdicts.md)
defines the authority boundary. The established organization-required gate is
still active; this replacement is default-off.

## Commands

```sh
go -C tools/trusted-gate test -race -count=1 ./...
go -C tools/trusted-gate vet ./...
# Supply an explicit read token through GITHUB_TOKEN; this command writes no settings.
go -C tools/trusted-gate run . inspect --app-id <dedicated-app-id>
```

`inspect` reads every ruleset page and joins full live details. Only the exact
active repository context/App/default-branch rule with no bypass, alongside
the unchanged established organization rule, produces `replacement_ready=true`.
Missing protection is not ready; unreadable, partial or ambiguous observations
are unknown and exit unsuccessfully. Rule shape does not establish producer
credentials or behavioral canaries.

`resolve --run-id <id> --output <path>` and
`publish --identity <resolved-json> --verdict <pending|failure|success>` are
reviewed-main workflow entrypoints. They require the canonical `workflow_run`
source, exact workflow SHA, explicit scoped token and enabled flag. Unset or
`false` emits `admitted=false` without reading candidate identity or publishing.
Other flag values are refused. Successful publication requires the entire
evaluated identity to remain current and exact API acknowledgement/readback.

## Publisher prerequisites

The dedicated App is installed only on World at Ruin. Its token requests Checks
write and Actions, Contents and Pull Requests read. Its private key is the
`WAR_TRUSTED_GATE_PRIVATE_KEY` environment secret in
`world-trusted-gate-publisher`, whose custom deployment branch policy permits
only `main`. Neither organization nor repository secrets may carry that key.
`WAR_TRUSTED_GATE_APP_ID` identifies this independent producer; a general
automation App or the Actions App does not provide the intended separation.

Keep `WAR_REPOSITORY_TRUSTED_GATE_ENABLED` unset until these prerequisites are
read back. Enable the producer under established protection, observe actual
frozen scenes and positive/negative canaries, then introduce the active
repository binding through declarative GitHub configuration. Retiring the old
rule and central game workflow follows independent overlap proof and release
readback. Turning the producer off while its verdict is required blocks merging;
restore and verify established protection before any recovery change.
