//go:build war_native_trial && war_issued_trial

package nakamatrial

import (
	"net"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// The actual loaded plugin invokes the SDK before the shared initializer. An
// unavailable issuer must never register a ready server or private listener.
func TestNativeIssuedSDKStartupBoundary(t *testing.T) {
	f := newFixture(t)
	modules := filepath.Join(*bundle, "modules")
	for _, enable := range []string{"", "false"} {
		p := f.launch(map[string]string{"WAR_ISSUED_SDK_PROBE_ENABLED": enable, "WAR_ISSUED_SDK_PROBE_SOCKET": "malformed"}, modules, 10, true)
		if !strings.Contains(p.log.String(), "Go runtime modules loaded") {
			t.Fatal("disabled SDK probe did not load the actual plugin")
		}
		p.stop(t)
	}
	missing := filepath.Join(f.dir, "missing-workload.sock")
	for _, env := range []map[string]string{
		{"WAR_ISSUED_SDK_PROBE_ENABLED": "true", "WAR_ISSUED_SDK_PROBE_SOCKET": missing},
		{"WAR_ISSUED_SDK_PROBE_ENABLED": "true", "WAR_ISSUED_SDK_PROBE_SOCKET": missing, "WAR_HANDOFF_ENABLED": "true", "WAR_HANDOFF_CLAIMS_ENABLED": "true", "WAR_HANDOFF_CLAIMS_ADDRESS": "127.0.0.1:7443"},
	} {
		p := f.launch(env, modules, 10, false)
		log := p.log.String()
		if p.err == nil || !strings.Contains(log, "issued SDK WorkloadAPI unavailable") || strings.Contains(log, "Go runtime modules loaded") || strings.Contains(log, missing) {
			t.Fatal("actual unavailable-issuer SDK startup refusal not established")
		}
		conn, err := net.DialTimeout("tcp", "127.0.0.1:7443", 100*time.Millisecond)
		if err == nil {
			_ = conn.Close()
			t.Fatal("uncertain SDK startup bound a private claim listener")
		}
	}
	if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
		t.Fatal("SDK startup refusal reached provider effects")
	}
	t.Log("ISSUED SDK NATIVE PASS: loaded plugin; default off; actual WorkloadAPI unavailable; zero provider effects; no serving authority")
}
