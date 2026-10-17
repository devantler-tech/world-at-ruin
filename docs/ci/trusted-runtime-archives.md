# Maintain the trusted runtime archive expectation

Every Linux cold build enforces
`.github/containers/trusted-runtime-archives.lock.json` before APT may execute
package scripts. The lock fixes all 55 archives selected by the current Ubuntu
snapshot: package/version/architecture, basename, requested URI, byte count,
SHA-256 and every matching trusted Packages/InRelease origin. It also binds the
complete eight-target authenticated APT census, including targets that supplied
no selected archive, plus the runtime manifest, snapshot, ten direct arguments
and exact base/package lock bytes. Normal and diagnostic builds enforce this
lock. A separately selected, disposable maintenance build can produce evidence
for a replacement after an intentional snapshot or pin change; it cannot admit
a runtime or update the repository.

The first lock was derived from the complete report emitted by successful CI run
[38911091987, job 117006833815](https://github.com/devantler-tech/world-at-ruin/actions/runs/38911091987/job/117006833815).
The committed source-report digest and image ID let a reviewer match the proposed
lock to those retained job logs. They do not make the report an authority.

## Update procedure

1. Change the snapshot, direct pins, base proof or installed-package lock in one
   reviewable branch. Do not weaken APT authentication, validity or HTTPS.
2. Dispatch **Propose trusted runtime archives** for that exact branch and type
   `PROPOSE` in its confirmation input. The workflow has read-only repository
   permission and uploads a seven-day artifact containing the complete report,
   source image digest and generated lock proposal.
3. Verify the workflow run, job, commit, source image and recipe identities
   independently. The workflow is equivalent to this local extraction command;
   never hand-edit the generated lock:

   ```sh
   go run tools/trusted-runtime-archives/main.go \
     --from-report /path/to/complete-report.json . \
     > /tmp/trusted-runtime-archives.lock.json
   ```

4. Review the full archive/origin diff and source-report binding, then replace
   `.github/containers/trusted-runtime-archives.lock.json` with the artifact's
   generated proposal.
5. Prove the exact head in ordinary hosted CI. The real locked cold build and complete
   trusted scene suite must succeed; local fixtures cannot replace that result.

The proposal workflow sets both `WAR_TRUSTED_RUNTIME_INVENTORY=1` and
`WAR_TRUSTED_RUNTIME_ARCHIVE_PROPOSAL=1`. The pair is required: detached,
misspelled or partial selections stop before Docker. The build still validates
the base and installed-package locks, uses authenticated APT targets, joins every
archive to the complete trusted origin set, checks size and SHA-256, proves the
final package set, and installs from the same private cache with `--no-download`.
It skips only equality with the old archive expectation, publishes evidence,
and deletes its disposable image. Never select proposal mode in normal CI or
treat its artifact as merge authority.

An unavailable snapshot, package, index or archive stops the build. Collect a
new proposal from a disposable authenticated cold build and review all affected
locks. Never remove the verifier, use an unpinned fallback, ignore missing
archives, admit a partial origin set or switch to an unauthenticated source to
recover availability.

Validate local code paths with:

```sh
go test -race tools/trusted-runtime-archives/main.go tools/trusted-runtime-archives/main_test.go
bash tools/trusted-runtime-transaction.test.sh
bash tools/propose-trusted-runtime-archives.test.sh
go test -race tools/trusted-runtime-inventory/main.go tools/trusted-runtime-inventory/main_test.go
bash tools/trusted-runtime-inventory.test.sh
bash tools/client-proof-workflow-guard.test.sh
```

The mutation controls cover missing, extra or detached targets and archives,
duplicate records, wrong tuples, wrong sizes, corrupt bytes, truncation and
linked inputs. They also prove a failed comparison cannot reach the offline
install. The lock authorizes only the current cold build. It
does not authorize an archive producer, store, publication mechanism or warm
reuse; those remain in [#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).
