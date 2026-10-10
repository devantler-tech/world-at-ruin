//go:build war_native_trial

package main

import (
	"context"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaadmissionprobe"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamacapabilityprobe"
	"github.com/heroiclabs/nakama-common/runtime"
)

// admissionTrial composes native-only probes whose individual enablement flags
// keep ordinary startup free of experimental admission and recovery writes.
func admissionTrial(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule) error {
	if err := nakamacapabilityprobe.RunRecoveryFence(ctx, nk, func(s string) { logger.Info("NAKAMA RECOVERY FENCE PROBE PASS: owner=%s", s) }); err != nil {
		return err
	}
	if err := nakamacapabilityprobe.RunRecoveryOwner(ctx, nk, func(s string) { logger.Info("NAKAMA RECOVERY OWNER PROBE PASS: owner=%s", s) }); err != nil {
		return err
	}
	if err := nakamacapabilityprobe.RunHandoff(ctx, nk, func(s string) { logger.Info("NAKAMA HANDOFF PROBE PASS: scenario=%s", s) }); err != nil {
		return err
	}
	if err := nakamacapabilityprobe.Run(ctx, nk, func(scenario string) { logger.Info("NAKAMA CAPABILITY PROBE PASS: scenario=%s", scenario) }); err != nil {
		return err
	}
	return nakamaadmissionprobe.Run(ctx, nk, func(r nakamaadmissionprobe.Report) {
		logger.Info("NAKAMA ADMISSION PROBE PASS: scenario=%s phase=%s grants=%d", r.Scenario, r.Phase, r.GrantCount)
	})
}
