//go:build war_native_trial

package nakamacapabilityprobe

import (
	"context"
	"github.com/heroiclabs/nakama-common/runtime"
	"testing"
)

// Missing enablement must not inspect private storage, material or pins.
type publicationTestContext struct {
	context.Context
	env map[string]string
}

// Value implements the native runtime's environment key without changing it.
func (ctx publicationTestContext) Value(key any) any {
	if key == runtime.RUNTIME_CTX_ENV {
		return ctx.env
	}
	return ctx.Context.Value(key)
}

func TestRecoveryPublicationProbeDefaultOffAndInvalidInputs(t *testing.T) {
	for _, flag := range []string{"", "false", "true", "invalid"} {
		ctx := publicationTestContext{Context: context.Background(), env: map[string]string{"WAR_DURABLE_RECOVERY_PUBLICATION_PROBE_ENABLED": flag}}
		err := RunRecoveryPublication(ctx, nil, nil)
		if (flag == "" || flag == "false") && err != nil {
			t.Fatal("disabled publication probe inspected dependencies")
		}
		if (flag == "true" || flag == "invalid") && err == nil {
			t.Fatal("enabled publication probe accepted missing private inputs")
		}
	}
}
