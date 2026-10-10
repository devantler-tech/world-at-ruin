package nakamaadmissionprobe

import (
	"context"
	"github.com/heroiclabs/nakama-common/runtime"
	"testing"
)

func TestDisabledProbeReturnsBeforeDependencies(t *testing.T) {
	for _, flag := range []string{"", "false"} {
		ctx := probeContext{Context: context.Background(), env: map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": flag, "WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL": "invalid"}}
		if e := Run(ctx, nil, nil); e != nil {
			t.Fatal(e)
		}
	}
}
func TestProbeRefusesInvalidEnablement(t *testing.T) {
	ctx := probeContext{Context: context.Background(), env: map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": "TRUE"}}
	if e := Run(ctx, nil, nil); e == nil {
		t.Fatal("invalid flag accepted")
	}
}

type probeContext struct {
	context.Context
	env map[string]string
}

func (c probeContext) Value(key any) any {
	if key == runtime.RUNTIME_CTX_ENV {
		return c.env
	}
	return c.Context.Value(key)
}
