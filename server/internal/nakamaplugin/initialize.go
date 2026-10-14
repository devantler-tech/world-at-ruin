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
	return initialize(ctx, logger, nk, initializer, nil)
}

// InitializeWithClaimsMaterial keeps native probe ordering while selecting the
// runtime's fixed static-material listener. The initializing process retains
// the signer for the complete runtime lifetime.
func InitializeWithClaimsMaterial(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, initializer runtime.Initializer, material nakamaruntime.ClaimsTLSMaterial) error {
	return initialize(ctx, logger, nk, initializer, &material)
}

func initialize(ctx context.Context, logger runtime.Logger, nk runtime.NakamaModule, initializer runtime.Initializer, material *nakamaruntime.ClaimsTLSMaterial) error {
	if err := nakamajournalprobe.Run(ctx, nk, func(report nakamajournalprobe.Report) {
		logger.Info("NAKAMA JOURNAL PROBE PASS: grants=%d observation_sha256=%s", report.GrantCount, report.ObservationSHA256)
	}); err != nil {
		return err
	}
	if err := admissionTrial(ctx, logger, nk); err != nil {
		return err
	}
	if material != nil {
		return nakamaruntime.InitializeWithClaimsMaterial(ctx, logger, nk, initializer, *material)
	}
	return nakamaruntime.InitializeWithLogger(ctx, logger, nk, initializer)
}
