// Command nakama is the explicit issued-runtime trial's separate plugin entry.
package main

import (
	"context"
	"database/sql"
	"github.com/devantler-tech/world-at-ruin/server/internal/nakamaplugin"
	"github.com/heroiclabs/nakama-common/runtime"
)

func InitModule(ctx context.Context, logger runtime.Logger, _ *sql.DB, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	if err := sdkProbe(ctx, env); err != nil {
		return err
	}
	return nakamaplugin.Initialize(ctx, logger, nk, initializer)
}

func main() {}
