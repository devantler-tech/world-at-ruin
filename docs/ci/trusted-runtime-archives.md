# Maintain the trusted runtime archive expectation

Every Linux cold build enforces
`.github/containers/trusted-runtime-archives.lock.json` before APT may execute
package scripts. The lock fixes all 55 archives selected by the current Ubuntu
snapshot: package/version/architecture, basename, requested URI, byte count,
SHA-256 and every matching trusted Packages/InRelease origin. It also binds the
runtime manifest, snapshot, ten direct arguments and exact base/package lock
bytes. Diagnostic mode controls report publication only; it does not bypass the
archive check.

The first lock was derived from the complete report emitted by successful CI run
[38911091987, job 117006833815](https://github.com/devantler-tech/world-at-ruin/actions/runs/38911091987/job/117006833815).
The committed source-report digest and image ID let a reviewer match the proposed
lock to those retained job logs. They do not make the report an authority.

## Update procedure

1. Change the snapshot, direct pins, base proof or installed-package lock in one
   reviewable proposal. Do not weaken APT authentication, validity or HTTPS.
2. Run a disposable hosted build with
   `WAR_TRUSTED_RUNTIME_INVENTORY=1` and retain its single complete
   `TRUSTED_RUNTIME_INVENTORY` JSON line. Verify the workflow run, job, commit and
   recipe identities independently.
3. Generate a proposal; never hand-edit the lock:

   ```sh
   go run tools/trusted-runtime-archives/main.go \
     --from-report /path/to/complete-report.json . \
     > /tmp/trusted-runtime-archives.lock.json
   ```

4. Review the full archive/origin diff and the source report binding, then move
   the reviewed file into `.github/containers/trusted-runtime-archives.lock.json`.
5. Prove the exact head in hosted CI. The real locked cold build and complete
   trusted scene suite must succeed; local fixtures cannot replace that result.

An unavailable snapshot, package, index or archive stops the build. Collect a
new proposal from a disposable authenticated cold build and review all affected
locks. Never remove the verifier, use an unpinned fallback, ignore missing
archives, admit a partial origin set or switch to an unauthenticated source to
recover availability.

Validate local code paths with:

```sh
go test -race tools/trusted-runtime-archives/main.go tools/trusted-runtime-archives/main_test.go
bash tools/trusted-runtime-transaction.test.sh
go test -race tools/trusted-runtime-inventory/main.go tools/trusted-runtime-inventory/main_test.go
bash tools/trusted-runtime-inventory.test.sh
bash tools/client-proof-workflow-guard.test.sh
```

The mutation controls cover missing, extra, duplicate, wrong-tuple, wrong-size,
corrupt, truncated and linked inputs. They also prove a failed comparison cannot
reach the offline install. The lock authorizes only the current cold build. It
does not authorize an archive producer, store, publication mechanism or warm
reuse; those remain in [#1397](https://github.com/devantler-tech/world-at-ruin/issues/1397).
