#!/usr/bin/env bash
# The required native profile is independent of any worker's reported verdicts.
native_scenarios() {
  scenarios=(
    TestLockedBundleLoadsAndRejectsMismatch TestDisabledNativeStartup
    TestEnabledNativeStartupRefusesInvalidDependencies TestNativeSessionAuthenticatesHandoff
    TestNativePrivateStorageAndCAS TestNativeRestartRetainsReplayAndAmbiguity
    TestNativePrivateClaimPersistsExactWorkload TestNativePeriodicExpiryRetriesExactCleanup
    TestNativeHistoricalRowsRemainMutationIneligible TestNativeAdmissionDefaultOff
    TestNativeAdmissionConditionalTransitions TestNativeDurableCapabilityComposition
    TestNativeRecoveryHandoff TestNativeRecoveryOwner TestNativeRecoveryFence TestNativeRecoveryPublication
    TestNativeZoneCustodyDefaultOff TestNativeZoneCustodyPersistence TestNativeZoneCustodyCrashCuts
    TestNativeZoneCustodyCompetingProcesses TestNativeZoneCustodyReaderRefusals TestNativeOriginalClaimCustody
    TestNativeJournalDefaultOff TestNativeJournalReadback TestNativeJournalRefusals
    TestNativeOrphanSupervisionPreservesEvidence TestNativeSIGTERMStopsAdmissionAndCancelsWork
    TestClosedLoopSealedBootstrap TestClosedLoopAccountSnapshot TestClosedLoopClaimBeforeUpgrade
    TestClosedLoopClaimAfterZoneDeath TestClosedLoopAcknowledgedZoneDeath TestClosedLoopWorkloadIdentity
    TestClosedLoopSiblingIsolation TestClosedLoopRevisionFence TestClosedLoopRestartProtection
    TestClosedLoopWrappingRotation TestClosedLoopAmbiguousAllocation TestClosedLoopShutdownOwnership
    TestClosedLoopAuthoritativeMovement TestClosedLoopMovementAfterWatchLoss
  )
  if [[ ${1:-} == --issued ]]; then
    scenarios+=(TestNativeIssuedSDKStartupBoundary TestNativeIssuedClaimsPlugin)
  fi
}
