// Command nakama is built with -buildmode=plugin for Nakama's Go runtime.
package main

import (
	"context"
	"database/sql"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaplugin"
	"github.com/heroiclabs/nakama-common/runtime"
)

// InitModule is Nakama's plugin entry point. The handoff feature is default-off.
func InitModule(ctx context.Context, logger runtime.Logger, _ *sql.DB, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	return nakamaplugin.Initialize(ctx, logger, nk, initializer)
}

func main() {}
