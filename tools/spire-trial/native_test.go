//go:build war_spire_trial && linux

package spiretrial

import (
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"

	"golang.org/x/sys/unix"
)

var experimental = flag.Bool("war-experimental", false, "enable disposable SPIRE experiment")
var workerRole = flag.String("war-role", "", "private diagnostic worker")
var workerAPI = flag.String("war-api", "", "owned Workload API socket")
var issuerState = flag.String("war-issuer-state", "", "private issuer state refusal control")

// TestMain refuses default execution before state or processes, then enforces
// no-new-privileges for both the controller and independently attested workers.
func TestMain(m *testing.M) {
	flag.Parse()
	if !*experimental {
		fmt.Fprintln(os.Stderr, "SPIRE trial requires explicit opt-in before any state or process")
		os.Exit(2)
	}
	if err := unix.Prctl(unix.PR_SET_NO_NEW_PRIVS, 1, 0, 0, 0); err != nil {
		fmt.Fprintln(os.Stderr, "SPIRE trial cannot enforce no-new-privileges")
		os.Exit(1)
	}
	if *workerRole != "" {
		os.Exit(runWorker(*workerRole, *workerAPI, *issuerState))
	}
	os.Exit(m.Run())
}

// TestNativeSPIREAttestedRoles proves real issuance, exact authorization and
// owned retirement without granting original-process or launch authority.
func TestNativeSPIREAttestedRoles(t *testing.T) {
	if err := verifyController(); err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithTimeout(context.Background(), 4*time.Minute)
	defer cancel()
	f := newNativeFixture(t, ctx)
	primary := f.startIssuer("primary", 18443)
	alternate := f.startIssuer("alternate", 18444)
	roles := []string{"supervisor", "custodian", "child"}
	workers := make(map[string]*nativeWorker)
	for _, role := range roles {
		workers[role] = f.startWorker(role, primary)
	}
	effects := func() uint64 {
		var count uint64
		for _, w := range workers {
			count += w.exchange(command{Op: "stats"}).Effects
		}
		return count
	}
	call := func(caller, server string) response {
		return workers[caller].exchange(command{Op: "call", Address: workers[server].ready.Address, Server: server, Method: "POST", Path: "/diagnostic"})
	}
	for _, server := range roles {
		caller := expectedCaller(server)
		t.Run("issued-key-possession-"+caller+"-to-"+server, func(t *testing.T) {
			r := call(caller, server)
			if r.Status != 204 || r.Error != "" {
				t.Fatalf("positive failed: %+v", r)
			}
		})
	}
	if effects() != 3 {
		t.Fatal("three role positives did not produce exactly three effects")
	}
	for _, server := range roles {
		for _, caller := range roles {
			if caller == expectedCaller(server) {
				continue
			}
			t.Run("wrong-role-"+caller+"-to-"+server, func(t *testing.T) {
				before := effects()
				r := call(caller, server)
				if r.Error == "" || r.Status != 0 {
					t.Fatalf("wrong role reached HTTP: %+v", r)
				}
				if effects() != before {
					t.Fatal("wrong role produced an effect")
				}
			})
		}
	}
	for _, server := range roles {
		for _, bad := range []command{
			{Method: "GET", Path: "/diagnostic"},
			{Method: "POST", Path: "/claim"},
			{Method: "POST", Path: "/diagnostic?authority=launch"},
		} {
			t.Run("method-path-"+server+"-"+bad.Method+"-"+bad.Path, func(t *testing.T) {
				before := effects()
				bad.Op = "call"
				bad.Address = workers[server].ready.Address
				bad.Server = server
				r := workers[expectedCaller(server)].exchange(bad)
				if r.Status != 403 || r.Error != "" {
					t.Fatalf("method/path refusal failed: %+v", r)
				}
				if effects() != before {
					t.Fatal("method/path produced an effect")
				}
			})
		}
	}
	for _, credential := range []string{"missing", "mismatched"} {
		t.Run("key-possession-"+credential, func(t *testing.T) {
			before := effects()
			r := workers["supervisor"].exchange(command{Op: "call", Address: workers["custodian"].ready.Address, Server: "custodian", Method: "POST", Path: "/diagnostic", Credential: credential})
			if r.Error == "" || r.Status != 0 {
				t.Fatalf("key refusal failed: %+v", r)
			}
			if effects() != before {
				t.Fatal("key refusal produced an effect")
			}
		})
	}
	t.Run("wrong-expected-server", func(t *testing.T) {
		before := effects()
		r := workers["supervisor"].exchange(command{Op: "call", Address: workers["custodian"].ready.Address, Server: "child", Method: "POST", Path: "/diagnostic"})
		if r.Error == "" || !strings.Contains(r.Error, "unexpected ID") || r.Status != 0 {
			t.Fatalf("expected-server refusal failed: %+v", r)
		}
		if effects() != before {
			t.Fatal("wrong expected server produced an effect")
		}
	})
	t.Run("unregistered-uid", func(t *testing.T) {
		r := f.startWorker("unregistered", primary).ready
		if r.Code != "PermissionDenied" || !strings.Contains(r.Error, "no identity issued") || r.ID != "" {
			t.Fatalf("not the intended issuer refusal: %+v", r)
		}
	})
	same := f.startWorker("supervisor", primary)
	t.Run("same-role-second-process-is-authorized", func(t *testing.T) {
		if same.cmd.Process.Pid == workers["supervisor"].cmd.Process.Pid || same.ready.ID != workers["supervisor"].ready.ID {
			t.Fatal("not a separate legitimate process with the same principal")
		}
		before := effects()
		r := same.exchange(command{Op: "call", Address: workers["custodian"].ready.Address, Server: "custodian", Method: "POST", Path: "/diagnostic"})
		if r.Status != 204 || r.Error != "" || effects() != before+1 {
			t.Fatalf("same-role control failed: %+v", r)
		}
	})
	altSupervisor := f.startWorker("supervisor", alternate)
	altCustodian := f.startWorker("custodian", alternate)
	t.Run("alternative-issuer-positive", func(t *testing.T) {
		r := altSupervisor.exchange(command{Op: "call", Address: altCustodian.ready.Address, Server: "custodian", Method: "POST", Path: "/diagnostic"})
		if r.Status != 204 || r.Error != "" || altCustodian.exchange(command{Op: "stats"}).Effects != 1 {
			t.Fatalf("alternative issuer not valid: %+v", r)
		}
	})
	t.Run("alternative-issuer-same-principal", func(t *testing.T) {
		if altSupervisor.ready.ID != workers["supervisor"].ready.ID {
			t.Fatal("issuer control did not preserve principal spelling")
		}
		before := effects()
		r := altSupervisor.exchange(command{Op: "call", Address: workers["custodian"].ready.Address, Server: "custodian", Method: "POST", Path: "/diagnostic", TrustBundle: primary.bundle})
		if r.Error == "" || r.Status != 0 {
			t.Fatalf("untrusted issuer reached HTTP: %+v", r)
		}
		if effects() != before {
			t.Fatal("untrusted issuer produced an effect")
		}
	})
	// This unrelated owned canary must survive stopping one worker.
	t.Run("stop-join-preserves-sibling", func(t *testing.T) {
		f.stop(same.process)
		if workers["supervisor"].exchange(command{Op: "stats"}).Error != "" {
			t.Fatal("stop affected an unrelated sibling")
		}
		if r := call("supervisor", "custodian"); r.Status != 204 || r.Error != "" {
			t.Fatalf("original sibling lost authenticated operation after second-process retirement: %+v", r)
		}
	})
	f.close()
	if _, err := os.Stat(f.dir); !os.IsNotExist(err) {
		t.Fatal("private state survived successful stop/join")
	}
	fmt.Println("SPIRE NATIVE PASS: three own Workload API identities; role cycle; six wrong pairs; method/path; key possession; expected server; alternate issuer; unregistered UID; same-role positive; owned cleanup")
}

// runCLI invokes the pinned issuer administrator without a shell. Its output
// can contain bootstrap material and must remain inside the disposable fixture.
func runCLI(ctx context.Context, args ...string) ([]byte, error) {
	c := exec.CommandContext(ctx, "/opt/spire/bin/spire-server", args...)
	return c.Output()
}

// privateJSON decodes issuer replies without disclosing their raw token-bearing bytes.
func privateJSON(data []byte, output any) error {
	if err := json.Unmarshal(data, output); err != nil {
		return fmt.Errorf("private SPIRE CLI reply could not be decoded")
	}
	return nil
}
