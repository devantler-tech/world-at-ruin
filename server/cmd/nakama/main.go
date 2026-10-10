// Command nakama is built with -buildmode=plugin for Nakama's Go runtime.
package main

import (
	"context"
	"database/sql"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamajournalprobe"
	"github.com/devantler-tech/world-at-ruin/server/nakamaruntime"
	"github.com/heroiclabs/nakama-common/runtime"
)

// InitModule is Nakama's plugin entry point. The handoff feature is default-off.
func InitModule(ctx context.Context, logger runtime.Logger, _ *sql.DB, nk runtime.NakamaModule, initializer runtime.Initializer) error {
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

func main() {}
