//go:build war_native_trial

package main

import (
	"context"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaadmissionprobe"
	"github.com/heroiclabs/nakama-common/runtime"
)

func admissionTrial(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule) error {
	return nakamaadmissionprobe.Run(ctx, nk, func(r nakamaadmissionprobe.Report) {
		logger.Info("NAKAMA ADMISSION PROBE PASS: scenario=%s phase=%s grants=%d", r.Scenario, r.Phase, r.GrantCount)
	})
}
