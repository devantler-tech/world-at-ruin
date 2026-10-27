# 0061: Partition complete native acceptance within one fresh image

Status: accepted

The native and issued acceptance profiles execute their complete scenario sets
in four isolated test containers when `WAR_NATIVE_WORKERS=4` is explicitly
selected. The default remains one worker. Other values fail; the privileged
issued-SPIRE profile retains its independent single-worker acceptance.

All workers use one resolved immutable image ID from that job's fresh,
profile-specific build. Test and vulnerability verdicts are not cached or
transferred between jobs. The actual compiled top-level test inventory must
exactly match the required profile before any worker starts. A deterministic
round-robin partition covers each required scenario exactly once; missing,
unexpected or duplicated tests cannot become a smaller passing suite.

Separate container network namespaces preserve fixed process ports and private
temporary state. The workers share only the disposable internal fixture network
and PostgreSQL server. Every scenario creates its own unpredictable database,
joins its processes and drops that database. Existing scenario, RPC, expiry and
process deadlines remain unchanged. Four two-gigabyte test-container limits plus
the one-gigabyte database limit fit within the documented public Linux runner's
16 GB, with actual resource behavior still subject to native measurement.

Each worker must exit successfully and produce exactly its assigned complete
top-level passing verdicts. The parent joins all launchers and retires every
owned container before accepting their union. Failed inventory reads, plausible
partial output followed by failure, malformed or reused evidence, cancellation
and unknown retirement observations fail closed. Final success is reported only
after the disposable database and network are also retired. The complete receipt
binds the profile, resolved image, integration source, run and attempt.

Resource observations are diagnostic and separate from the complete test verdict.
Before each worker exits, its unprivileged wrapper reads its private cgroup-v2 peak
memory in bytes and cumulative CPU use in microseconds. The receipt retains each
worker's observation beside its elapsed time, plus the runner's observed logical
CPU count and total memory. Unavailable, invalid or ambiguous counters remain
`null` with `complete: false`; they are never zero or a claimed measurement.
The test process's exit status and all existing retirement checks remain binding.
Configured limits are not measured use, and the sum of worker peaks is not a
simultaneous whole-runner peak. See the [kernel counter definitions](https://docs.kernel.org/admin-guide/cgroup-v2.html).

The ordinary serial path remains an explicit recovery option, not an automatic
fallback that could hide a failed parallel observation. CI selects four workers
for native and issued profiles on both architectures. This does not activate a
production experiment, publish an image, alter runtime authority or relax a
required aggregate. Normal source builds, opt-in refusal, complete SPIRE
acceptance and all original scenario checks remain required.

This decision targets a measured serial bottleneck, not a claim that complete PR
feedback is already below fifteen minutes. Current-head native timings, queue
time, resource behavior and cold/warm distinctions determine the result. The
whole-feedback outcome remains in #1495, including independent visual evidence.

References: [native partition acceptance #1517](https://github.com/devantler-tech/world-at-ruin/issues/1517),
[native trial boundary](0022-prove-the-native-nakama-runtime-with-disposable-storage.md),
[GitHub runner specifications](https://docs.github.com/en/actions/reference/runners/github-hosted-runners).
