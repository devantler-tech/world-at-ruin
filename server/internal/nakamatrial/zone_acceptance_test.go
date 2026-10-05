//go:build war_native_trial

package nakamatrial

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"maps"
	"net"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	sdkproto "agones.dev/agones/pkg/sdk"
	"github.com/devantler-tech/world-at-ruin/server/agones"
)

// TestClosedLoopSealedBootstrap catches allocation before observed zone readiness.
func TestClosedLoopSealedBootstrap(t *testing.T) {
	verifyZoneArtifact(t)
	for _, scenario := range []string{"held observation", "failed publication"} {
		t.Run(scenario, func(t *testing.T) {
			f := closedFixture(t)
			peer := ""
			if scenario == "failed publication" {
				peer = "publication-failed"
			}
			z := f.startZone("zone-a", f.key, peer, true)
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			account, _ := f.account("bootstrap-closed-loop")
			code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}")
			if code == 200 || z.sidecar.ReadyCalls() != 0 {
				t.Fatal("unobserved zone became allocatable")
			}
			if allocated, _ := f.counts(); allocated != 0 {
				t.Fatal("unready zone allocated")
			}
			if scenario == "failed publication" {
				select {
				case <-z.process.done:
				case <-time.After(8 * time.Second):
					t.Fatal("failed seal publication did not settle")
				}
				if z.process.err == nil {
					t.Fatal("failed publication succeeded")
				}
				return
			}
			z.sidecar.ReleaseWatchEvents()
			z.ready()
			// The refused account retains ambiguity; a new account can use Ready capacity.
			readyAccount, _ := f.account("ready-closed-loop")
			z.snapshot(f.handoff(readyAccount))
		})
	}
}

// TestClosedLoopAccountSnapshot catches fake minting, routing or missing replication.
func TestClosedLoopAccountSnapshot(t *testing.T) {
	f := closedFixture(t)
	z := f.startZone("zone-a", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("snapshot-closed-loop")
	got := f.handoff(account)
	bad := got
	bad.Token = "invalid"
	z.refuse(bad)
	before, version, _, _ := f.row(leaseKey(uid))
	z.snapshot(got)
	claimed, newVersion := f.claimed(leaseKey(uid))
	if claimed == before || newVersion == version {
		t.Fatal("real snapshot preceded native ownership")
	}
	if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", "", "{}"); code == 200 {
		t.Fatal("anonymous handoff succeeded")
	}
}

// TestClosedLoopClaimBeforeUpgrade catches an upgrade ahead of PostgreSQL commit.
func TestClosedLoopClaimBeforeUpgrade(t *testing.T) {
	f := closedFixture(t)
	z := f.startZone("zone-a", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("blocked-claim-closed-loop")
	got := f.handoff(account)
	_, version, _, _ := f.row(leaseKey(uid))
	wait, release := f.claimBlock()
	pending := z.pending(got)
	wait()
	select {
	case err := <-pending:
		t.Fatalf("admission settled before private commit: %v", err)
	default:
	}
	_, blockedVersion, _, _ := f.row(leaseKey(uid))
	if blockedVersion != version {
		t.Fatal("held write changed version")
	}
	release()
	select {
	case err := <-pending:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(4 * time.Second):
		t.Fatal("claim did not settle")
	}
	_, claimedVersion := f.claimed(leaseKey(uid))
	if claimedVersion == version {
		t.Fatal("admission did not commit")
	}
	z.snapshot(got)
}

// TestClosedLoopWorkloadIdentity catches private credential substitution in the command.
func TestClosedLoopWorkloadIdentity(t *testing.T) {
	for _, peer := range []string{"wrong", "untrusted", "matching"} {
		t.Run(peer, func(t *testing.T) {
			f := closedFixture(t)
			z := f.startZone("zone-a", f.key, peer, false)
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			account, uid := f.account("workload-closed-loop")
			got := f.handoff(account)
			before, version, _, _ := f.row(leaseKey(uid))
			if peer == "matching" {
				z.snapshot(got)
				f.claimed(leaseKey(uid))
				return
			}
			waitFor(t, 2*time.Second, "refused workload reached actual native private TLS", func() bool {
				z.refuse(got)
				return z.claimConnections.Load() > 0
			})
			after, newVersion, _, _ := f.row(leaseKey(uid))
			if after != before || newVersion != version {
				t.Fatal("refused workload changed native ownership")
			}
		})
	}
}

// TestClosedLoopSiblingIsolation catches a shared secret or mismatched envelope acceptance.
func TestClosedLoopSiblingIsolation(t *testing.T) {
	f := closedFixture(t)
	a := f.startZone("zone-a", f.key, "", false)
	b := f.startZone("zone-b", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	aa, auid := f.account("sibling-a-closed-loop")
	bb, buid := f.account("sibling-b-closed-loop")
	aGot, bGot := f.handoff(aa), f.handoff(bb)
	av, aver, _, _ := f.row(leaseKey(auid))
	bv, bver, _, _ := f.row(leaseKey(buid))
	cross := aGot
	cross.ServerName = bGot.ServerName
	cross.Port = bGot.Port
	b.refuse(cross)
	cross = bGot
	cross.ServerName = aGot.ServerName
	cross.Port = aGot.Port
	a.refuse(cross)
	av2, aver2, _, _ := f.row(leaseKey(auid))
	bv2, bver2, _, _ := f.row(leaseKey(buid))
	if av != av2 || aver != aver2 || bv != bv2 || bver != bver2 {
		t.Fatal("crossed tokens changed native ownership")
	}
	f.mu.Lock()
	original := f.servers["zone-a"].Annotations[agones.AdmissionEnvelopeAnnotation]
	f.servers["zone-a"].Annotations[agones.AdmissionEnvelopeAnnotation] = f.servers["zone-b"].Annotations[agones.AdmissionEnvelopeAnnotation]
	f.mu.Unlock()
	a.refuse(aGot)
	av2, aver2, _, _ = f.row(leaseKey(auid))
	if av != av2 || aver != aver2 {
		t.Fatal("sibling envelope changed native lease")
	}
	f.mu.Lock()
	f.servers["zone-a"].Annotations[agones.AdmissionEnvelopeAnnotation] = original
	f.mu.Unlock()
	a.snapshot(aGot)
	b.snapshot(bGot)
}

// TestClosedLoopRevisionFence catches acceptance of a late claim after SDK invalidation.
func TestClosedLoopRevisionFence(t *testing.T) {
	for _, change := range []string{"missing", "conflicting", "recreated"} {
		t.Run(change, func(t *testing.T) {
			f := closedFixture(t)
			z := f.startZone("zone-a", f.key, "", false)
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			account, uid := f.account("revision-closed-loop")
			got := f.handoff(account)
			_, beforeVersion, _, _ := f.row(leaseKey(uid))
			wait, release := f.claimBlock()
			pending := z.pending(got)
			wait()
			original, err := z.sidecar.GetGameServer(t.Context(), &sdkproto.Empty{})
			if err != nil {
				t.Fatal(err)
			}
			changed, err := z.sidecar.GetGameServer(t.Context(), &sdkproto.Empty{})
			if err != nil {
				t.Fatal(err)
			}
			switch change {
			case "missing":
				delete(changed.ObjectMeta.Annotations, agones.ClaimLocatorAnnotation)
			case "conflicting":
				digest, err := agones.CorrelationLabel("conflicting-native-attempt")
				if err != nil || digest == changed.ObjectMeta.Labels[agones.AttemptLabel] {
					t.Fatal("conflicting locator control did not change the attempt binding")
				}
				changed.ObjectMeta.Annotations[agones.ClaimLocatorAnnotation] = "v1." + leaseKey(uid) + "." + digest
			case "recreated":
				changed.ObjectMeta.Uid = "replacement-uid"
			}
			z.sidecar.PublishGameServer(changed)
			waitFor(t, 2*time.Second, "SDK invalidation reached local admission", func() bool {
				before := z.claimConnections.Load()
				ctx, cancel := context.WithTimeout(t.Context(), 150*time.Millisecond)
				defer cancel()
				conn, err := z.dial(ctx, got)
				if conn != nil {
					_ = conn.CloseNow()
					t.Fatal("invalidated observation admitted without claim")
				}
				return err != nil && strings.Contains(err.Error(), "zone HTTP 401:") && z.claimConnections.Load() == before
			})
			waitFor(t, time.Second, "invalidation probes retired their native writes", func() bool { return f.blockedClaims() == 1 })
			z.sidecar.PublishGameServer(original)
			// A second held native write proves restoration reached a fresh zone observation.
			probeCtx, cancelProbe := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancelProbe()
			probeDone := make(chan error, 1)
			go func() {
				for {
					conn, err := z.dial(probeCtx, got)
					if conn != nil {
						_ = conn.CloseNow()
					}
					if err == nil || probeCtx.Err() != nil || !strings.Contains(err.Error(), "zone HTTP 401:") {
						probeDone <- err
						return
					}
					time.Sleep(10 * time.Millisecond)
				}
			}()
			waitFor(t, 2*time.Second, "restored observation reached native claim", func() bool { return f.blockedClaims() == 2 })
			cancelProbe()
			if err := <-probeDone; err == nil {
				t.Fatal("restoration probe upgraded while commit remained held")
			}
			waitFor(t, time.Second, "restoration probe cancellation reached PostgreSQL", func() bool { return f.blockedClaims() == 1 })
			select {
			case err := <-pending:
				t.Fatalf("original revision claim ended before its commit barrier: %v", err)
			default:
			}
			release()
			select {
			case err := <-pending:
				if err == nil {
					t.Fatal("late private claim upgraded invalidated zone")
				}
			case <-time.After(4 * time.Second):
				t.Fatal("invalidated admission did not settle")
			}
			claimed, claimedVersion := f.claimed(leaseKey(uid))
			if claimedVersion == beforeVersion {
				t.Fatal("revision control did not exercise a committed native claim")
			}
			z.snapshot(got)
			after, afterVersion := f.claimed(leaseKey(uid))
			if after != claimed || afterVersion != claimedVersion {
				t.Fatal("fresh observation replaced the committed claim")
			}
		})
	}
}

// TestClosedLoopRestartProtection catches claim loss across real Nakama restart and cleanup.
func TestClosedLoopRestartProtection(t *testing.T) {
	f := closedFixture(t)
	f.env["WAR_HANDOFF_LEASE_TTL"] = "45s"
	f.env["WAR_HANDOFF_TOKEN_TTL"] = "45s"
	z := f.startZone("zone-a", f.key, "", false)
	f.startZone("zone-b", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("restart-closed-loop")
	got := f.handoff(account)
	conn := z.snapshot(got)
	_ = conn.CloseNow()
	claimed, version := f.claimed(leaseKey(uid))
	canary, _ := f.account("restart-closed-loop-canary")
	f.handoff(canary)
	f.process.stop(t)
	if f.resource("zone-b") == nil {
		t.Fatal("unclaimed canary expired before native restart")
	}
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	z.snapshot(got)
	again, againVersion := f.claimed(leaseKey(uid))
	if again != claimed || againVersion != version {
		t.Fatal("idempotent admission replaced claim generation")
	}
	waitFor(t, 50*time.Second, "real cleanup reclaimed unclaimed canary", func() bool { return f.resource("zone-b") == nil })
	after, afterVersion := f.claimed(leaseKey(uid))
	if after != claimed || afterVersion != version || f.resource("zone-a") == nil {
		t.Fatal("native restart cleanup stole active ownership")
	}
}

// TestClosedLoopWrappingRotation catches selection of old Ready seals or lost retained material.
func TestClosedLoopWrappingRotation(t *testing.T) {
	f := closedFixture(t)
	old := f.startZone("zone-a", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("rotation-old-closed-loop")
	got := f.handoff(account)
	newKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	f.startZone("zone-aa", f.key, "", false)
	current := f.startZone("zone-b", newKey, "", false)
	keys, _ := json.Marshal([]string{f.zoneFile("new-unwrap.pem", pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(newKey)})), filepath.Join(f.dir, "unwrap.pem")})
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_UNWRAP_KEYS"] = string(keys)
	f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	newAccount, _ := f.account("rotation-new-closed-loop")
	newGot := f.handoff(newAccount)
	current.snapshot(newGot)
	before, version, _, _ := f.row(leaseKey(uid))
	keys, _ = json.Marshal([]string{filepath.Join(f.dir, "new-unwrap.pem")})
	missing := maps.Clone(env)
	missing["WAR_HANDOFF_UNWRAP_KEYS"] = string(keys)
	f.launch(missing, filepath.Join(*bundle, "modules"), 10, true)
	old.refuse(got)
	if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
		t.Fatal("removed unwrap key admitted old allocation")
	}
	after, afterVersion, _, _ := f.row(leaseKey(uid))
	if after != before || afterVersion != version {
		t.Fatal("missing key replaced native ownership")
	}
	f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	old.snapshot(got)
	f.claimed(leaseKey(uid))
	if allocated, _ := f.counts(); allocated != 2 {
		t.Fatal("rotation redispatched an existing allocation")
	}
}

// TestClosedLoopAmbiguousAllocation catches redispatch when a real zone commit loses its reply.
func TestClosedLoopAmbiguousAllocation(t *testing.T) {
	for _, evidence := range []string{"singleton", "missing", "duplicate"} {
		t.Run(evidence, func(t *testing.T) {
			f := closedFixture(t)
			z := f.startZone("zone-a", f.key, "", false)
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			account, uid := f.account("ambiguity-closed-loop")
			f.mu.Lock()
			f.ambiguous = true
			f.mu.Unlock()
			if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
				t.Fatal("lost allocator acknowledgement succeeded")
			}
			before, version, _, _ := f.row(leaseKey(uid))
			f.mu.Lock()
			if evidence == "missing" {
				delete(f.servers, "zone-a")
			}
			if evidence == "duplicate" {
				copy := f.servers["zone-a"].DeepCopy()
				copy.Name = "duplicate"
				copy.UID = "duplicate-uid"
				f.servers[copy.Name] = copy
			}
			f.mu.Unlock()
			f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
			if evidence == "singleton" {
				z.snapshot(f.handoff(account))
				f.claimed(leaseKey(uid))
			} else {
				for range 2 {
					if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
						t.Fatal("incomplete allocation evidence admitted")
					}
				}
				after, afterVersion, _, _ := f.row(leaseKey(uid))
				if before != after || version != afterVersion {
					t.Fatal("ambiguous ownership changed")
				}
			}
			f.mu.Lock()
			calls, effects := f.allocationCalls, f.allocations
			f.mu.Unlock()
			if calls != 1 || effects != 1 {
				t.Fatal("restart redispatched ambiguous allocation")
			}
		})
	}
}

// TestClosedLoopShutdownOwnership catches SDK shutdown before socket/admission drain.
func TestClosedLoopShutdownOwnership(t *testing.T) {
	f := closedFixture(t)
	z := f.startZone("zone-a", f.key, "", false)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("shutdown-closed-loop")
	got := f.handoff(account)
	conn := z.snapshot(got)
	claimed, version := f.claimed(leaseKey(uid))
	// Hold the exact real generated resource lookup used by repeat private admission.
	f.mu.Lock()
	f.apiHold = make(chan struct{})
	f.apiEntered = make(chan struct{}, 1)
	entered, hold := f.apiEntered, f.apiHold
	f.mu.Unlock()
	t.Cleanup(func() { close(hold) })
	pending := z.pending(got)
	select {
	case <-entered:
	case <-time.After(3 * time.Second):
		t.Fatal("pending admission never reached native resource lookup")
	}
	retired := make(chan error, 1)
	z.sidecar.SetShutdownHook(func() {
		peer, err := net.DialTimeout("tcp", "127.0.0.1:"+strconv.Itoa(z.port), 100*time.Millisecond)
		if err == nil {
			_ = peer.Close()
			t.Error("SDK shutdown preceded listener refusal")
		}
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		for {
			if _, _, err := conn.Read(ctx); err != nil {
				if ctx.Err() != nil {
					t.Error("SDK shutdown preceded active socket drain")
				}
				break
			}
		}
		select {
		case err := <-pending:
			retired <- err
		case <-time.After(time.Second):
			t.Error("SDK shutdown preceded pending admission drain")
			retired <- nil
		}
	})
	_ = z.process.cmd.Process.Signal(syscall.SIGTERM)
	select {
	case err := <-retired:
		if err == nil {
			t.Fatal("pending shutdown admission upgraded")
		}
	case <-time.After(5 * time.Second):
		t.Fatal("pending admission survived shutdown")
	}
	select {
	case <-z.process.done:
	case <-time.After(8 * time.Second):
		t.Fatal("zone shutdown did not join")
	}
	if z.process.err != nil || z.sidecar.ShutdownCalls() != 1 {
		t.Fatalf("zone shutdown failed: %s", z.process.log.String())
	}
	after, afterVersion := f.claimed(leaseKey(uid))
	if after != claimed || afterVersion != version {
		t.Fatal("process exit released durable ownership")
	}
	if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
		t.Fatal("zone exit authorized replacement")
	}
}
