//go:build !war_native_trial

package main

import (
	"context"
	"github.com/heroiclabs/nakama-common/runtime"
)

// Normal plugin artifacts have no admission writer dependency or activation path.
func admissionTrial(context.Context, runtime.Logger, runtime.NakamaModule) error { return nil }
