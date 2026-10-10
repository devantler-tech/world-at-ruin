//go:build war_native_trial

package nakamacapabilityprobe

import (
	"context"
	"strings"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

func TestRecoveryOwnerProbeRequiresExplicitInputsBeforeDependencies(t *testing.T) {
	for _, flag := range []string{"", "false", "TRUE", "1", "true"} {
		t.Run("flag="+flag, func(t *testing.T) {
			env := map[string]string{"WAR_DURABLE_RECOVERY_OWNER_PROBE_ENABLED": flag, "WAR_DURABLE_RECOVERY_OWNER_PROBE_ID": "a", "WAR_DURABLE_RECOVERY_OWNER_PROBE_SCENARIO": "reserve", "WAR_DURABLE_RECOVERY_OWNER_PROBE_CONTROL": "http://127.0.0.1:1", "WAR_DURABLE_RECOVERY_OWNER_PROBE_PINS": "{} trailing"}
			ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, env)
			reports := 0
			err := RunRecoveryOwner(ctx, nil, func(string) { reports++ })
			if flag == "" || flag == "false" {
				if err != nil {
					t.Fatal("disabled probe inspected inputs")
				}
			} else if err == nil || !strings.Contains(err.Error(), "recovery owner probe:") {
				t.Fatal("invalid enablement accessed dependencies or reported success")
			}
			if reports != 0 {
				t.Fatal("unexamined reservation reported success")
			}
		})
	}
}
