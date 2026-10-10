//go:build war_native_trial

package nakamacapabilityprobe

import (
	"context"
	"github.com/heroiclabs/nakama-common/runtime"
	"testing"
)

// Disabled native probes never inspect storage; enabled probes need all private
// inputs before they can begin a reservation or contact the supervisor.
func TestRecoveryFenceProbeDefaultOffAndInvalidInputs(t *testing.T) {
	for _, flag := range []string{"", "false", "true", "invalid"} {
		ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, map[string]string{"WAR_DURABLE_RECOVERY_FENCE_PROBE_ENABLED": flag})
		err := RunRecoveryFence(ctx, nil, nil)
		if (flag == "" || flag == "false") && err != nil {
			t.Fatal("disabled probe inspected dependencies")
		}
		if (flag == "true" || flag == "invalid") && err == nil {
			t.Fatal("enabled recovery fence accepted missing private inputs")
		}
	}
}
