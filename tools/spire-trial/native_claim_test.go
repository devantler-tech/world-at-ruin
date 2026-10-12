//go:build war_spire_trial && linux

package spiretrial

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

// TestNativeSPIREPrivateClaim proves actual issuance and the real v2 handler/client
// seam. The resolver and storage remain synthetic, without Nakama ACK or custody.
func TestNativeSPIREPrivateClaim(t *testing.T) {
	if err := verifyController(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	f := newNativeFixture(t, ctx)
	primary := f.startIssuer("claims-primary", 18445)
	alternate := f.startIssuer("claims-alternate", 18446)
	zone := f.startWorker("zone", primary)
	server := f.startWorker("claims", primary)
	wrongZone := f.startWorker("wrong-zone", primary)
	supervisor := f.startWorker("supervisor", primary)
	child := f.startWorker("child", primary)
	uriOnly := f.startWorker("URI-only-claims", primary)
	wrongServer := f.startWorker("wrong-claims", primary)
	altZone := f.startWorker("zone", alternate)
	altServer := f.startWorker("claims", alternate)
	call := func(caller, target *nativeWorker, c command) response {
		c.Op = "claim"
		c.Address = target.ready.Address
		c.Expiry = target.ready.Expiry
		return caller.exchange(c)
	}
	stats := func(w *nativeWorker) response {
		r := w.exchange(command{Op: "stats"})
		if r.Error != "" {
			t.Fatal("claims storage observation failed")
		}
		return r
	}
	initial := stats(server)
	if initial.Claimed || initial.Effects != 0 || initial.Writes != 1 || initial.Generation != 0 {
		t.Fatal("claims fixture did not begin unclaimed")
	}
	var original response
	t.Run("issued-zone-original-v2-response", func(t *testing.T) {
		original = call(zone, server, command{})
		s := stats(server)
		if original.Error != "" || !original.Receipt || !s.Claimed || !s.Verified || s.Effects != 1 || s.Writes != 2 || original.Version != s.Version || original.Generation != s.Generation || s.Generation <= 0 {
			t.Fatal("issued zone did not receive the original verified v2 storage receipt")
		}
	})
	t.Run("replay-keeps-original-receipt", func(t *testing.T) {
		before := stats(server)
		r := call(zone, server, command{})
		after := stats(server)
		if r.Error != "" || !r.Receipt || r.Version != original.Version || r.Generation != original.Generation || after.Version != before.Version || after.Generation != before.Generation || after.Writes != before.Writes || after.Effects != before.Effects+1 {
			t.Fatal("replay did not preserve original response without another mutation")
		}
	})
	controls := []struct {
		name           string
		caller, target *nativeWorker
		change         command
		code           string
	}{
		{"supervisor-is-not-zone", supervisor, server, command{}, "Request"},
		{"child-is-not-zone", child, server, command{}, "Request"},
		{"issued-wrong-zone", wrongZone, server, command{}, "Request"},
		{"wrong-expected-DNS", zone, server, command{DNS: "other.fixture.test"}, "Request"},
		{"wrong-expected-server-URI", zone, server, command{Server: "wrong-claims"}, "Request"},
		{"issued-wrong-server-URI", zone, wrongServer, command{}, "Request"},
		{"issued-URI-only-server", zone, uriOnly, command{Server: "URI-only-claims"}, "Request"},
		{"missing-client-key-constructor", zone, server, command{Credential: "missing"}, "Constructor"},
		{"mismatched-client-key-handshake", zone, server, command{Credential: "mismatched"}, "Request"},
		{"wrong-server-root", zone, altServer, command{}, "Request"},
		{"alternate-caller-root", altZone, server, command{TrustBundle: primary.bundle}, "Request"},
	}
	for _, control := range controls {
		t.Run(control.name, func(t *testing.T) {
			before := stats(control.target)
			r := call(control.caller, control.target, control.change)
			after := stats(control.target)
			if r.Error == "" || r.Code != control.code || r.Receipt || r.Version != "" || r.Generation != 0 {
				t.Fatal("negative control returned a receipt or failed at an unintended stage")
			}
			if after.Effects != before.Effects || after.Writes != before.Writes || after.Version != before.Version || after.Generation != before.Generation || after.Claimed != before.Claimed {
				t.Fatal("negative control changed accepted claims or storage")
			}
		})
	}
	t.Run("alternative-issuer-positive", func(t *testing.T) {
		r := call(altZone, altServer, command{})
		s := stats(altServer)
		if r.Error != "" || !r.Receipt || !s.Verified || !s.Claimed || s.Effects != 1 || s.Writes != 2 || r.Version != s.Version || r.Generation != s.Generation {
			t.Fatal("alternate real issuer did not supply an independently valid positive")
		}
	})
	f.close()
	if _, err := os.Stat(f.dir); !os.IsNotExist(err) {
		t.Fatal("private claim state survived joined cleanup")
	}
	fmt.Println("SPIRE CLAIM NATIVE PASS: own issued zone and DNS+URI server; standard verified chains; actual v2 handler response and original replay; role/zone/root/server/key refusals; synthetic storage only; owned cleanup")
}
