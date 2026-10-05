package nakamaruntime

import (
	"context"
	"errors"

	"github.com/devantler-tech/world-at-ruin/server/orphanreaper"
	"github.com/heroiclabs/nakama-common/runtime"
)

// orphanObservation publishes only bounded counts and fixed classifications.
// A provider error's text is never passed to the logger, including wrapped
// errors that may carry credential paths or resource/player identities.
func orphanObservation(logger runtime.Logger) func(orphanreaper.Report, error) {
	if logger == nil {
		return nil
	}
	return func(report orphanreaper.Report, err error) {
		outcome := "complete"
		switch {
		case errors.Is(err, context.Canceled):
			outcome = "canceled"
		case errors.Is(err, context.DeadlineExceeded):
			outcome = "deadline"
		case errors.Is(err, orphanreaper.ErrCleanup):
			outcome = "cleanup-pending"
		case err != nil:
			outcome = "incomplete"
		}
		const format = "zone orphan sweep: outcome=%s scanned=%d waiting=%d protected=%d deleted=%d changed=%d failed=%d"
		if err != nil {
			logger.Warn(format, outcome, report.Scanned, report.Waiting, report.Protected, report.Deleted, report.Changed, report.Failed)
		} else {
			logger.Info(format, outcome, report.Scanned, report.Waiting, report.Protected, report.Deleted, report.Changed, report.Failed)
		}
	}
}
