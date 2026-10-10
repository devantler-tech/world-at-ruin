//go:build war_native_trial

package nakamacapabilityprobe

import (
	"context"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

func TestDisabledProbeNeverInspectsMaterialOrStorage(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, map[string]string{"WAR_DURABLE_GENERATION_PROBE_ENABLED": flag, "WAR_DURABLE_GENERATION_PROBE_MATERIAL": "/invalid", "WAR_DURABLE_GENERATION_PROBE_CONTROL": "invalid"})
		if err := Run(ctx, nil, nil); err != nil {
			t.Fatal("default-off probe inspected dependencies")
		}
	}
}

func TestDisabledHandoffProbeNeverInspectsDependencies(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, map[string]string{
			"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_ENABLED":  flag,
			"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_MATERIAL": "/invalid",
			"WAR_DURABLE_RECOVERY_HANDOFF_PROBE_PINS":     "invalid",
		})
		if err := RunHandoff(ctx, nil, nil); err != nil {
			t.Fatal("default-off handoff probe inspected dependencies")
		}
	}
}

func TestControlRefusesNonlocalAndRedirectDestinations(t *testing.T) {
	for _, value := range []string{"https://example.com", "http://localhost:12", "http://127.0.0.1:12/path", "http://user@127.0.0.1:12", "http://127.0.0.1:12?next=other", "http://127.0.0.1:12#other"} {
		if localEndpoint(value) {
			t.Fatalf("accepted non-fixture target %q", value)
		}
	}
	if !localEndpoint("http://127.0.0.1:1234") {
		t.Fatal("owned fixture endpoint refused")
	}
}
