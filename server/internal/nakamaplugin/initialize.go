// Package nakamaplugin supplies the shared WAR plugin initialization order.
package nakamaplugin

import (
	"context"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamajournalprobe"
	"github.com/devantler-tech/world-at-ruin/server/nakamaruntime"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Initialize runs native probes before registering the default-off handoff.
// The normal build's admissionTrial has no admission/custody writer imports.
func Initialize(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	if err := nakamajournalprobe.Run(ctx, nk, func(report nakamajournalprobe.Report) {
		logger.Info("NAKAMA JOURNAL PROBE PASS: grants=%d observation_sha256=%s", report.GrantCount, report.ObservationSHA256)
	}); err != nil {
		return err
	}
	if err := admissionTrial(ctx, logger, nk); err != nil {
		return err
	}
	return nakamaruntime.InitializeWithLogger(ctx, logger, nk, initializer)
}
