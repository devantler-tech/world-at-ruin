//go:build war_native_trial

package nakamatrial

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"maps"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
	"github.com/devantler-tech/world-at-ruin/server/internal/zonecustody"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

// originalReceiptEnv carries only the original route and expected observer;
// neither storage readback nor a diagnostic receipt supplies its claim response.
func originalReceiptEnv(t *testing.T, binding agones.ClaimBinding, scenario, control string) map[string]string {
	t.Helper()
	raw, err := json.Marshal(map[string]any{"Binding": binding, "Observer": 1, "OwnerID": "original", "ChildIncarnation": "no-gameplay-child"})
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_ZONE_CUSTODY_PROBE_ENABLED": "true", "WAR_ZONE_CUSTODY_PROBE_SCENARIO": scenario, "WAR_ZONE_CUSTODY_PROBE_RECEIPT_SOURCE": "control", "WAR_ZONE_CUSTODY_PROBE_INPUT": string(raw), "WAR_ZONE_CUSTODY_PROBE_CONTROL": control}
}

// A visible enrollment cannot start a claim; an originating ACK can. Native
// persistence, private claim commitment and reply acceptance are distinct counts.
func TestNativeOriginalClaimCustody(t *testing.T) {
	for _, fault := range []string{"complete", "lost-enrollment-ack", "cancel-enrollment-ack", "lost-receipt", "changed-binding", "lost-custody-ack", "cancel-custody-ack", "source-death", "lost-pins"} {
		t.Run(fault, func(t *testing.T) {
			f := newFixture(t)
			env := maps.Clone(f.env)
			env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
			f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
			token, uid := f.account("original-native-receipt")
			handoff := f.handoff(token)
			gs := f.resource("zone-1")
			binding := agones.ClaimBinding{Namespace: "world-at-ruin", LeaseObjectID: leaseKey(uid), AttemptDigest: gs.Labels[agones.AttemptLabel], AllocationID: gs.Name, GameServerUID: string(gs.UID)}
			before, version, _, _ := f.row(binding.LeaseObjectID)
			allocations, requests := f.counts()
			roots := x509.NewCertPool()
			if !roots.AppendCertsFromPEM(f.claimsPEM) {
				t.Fatal("native fixture claim root missing")
			}
			peer, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/zone/world-at-ruin/"+binding.GameServerUID, false)
			client, err := claimrpc.NewClient("https://localhost:7443/v1/claim", &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{peer}})
			if err != nil {
				t.Fatal(err)
			}
			t.Cleanup(client.Close)
			committedEnrollment, acceptedEnrollment, claimed := newStage(), newStage(), newStage()
			t.Cleanup(committedEnrollment.allow)
			t.Cleanup(acceptedEnrollment.allow)
			t.Cleanup(claimed.allow)
			pins := make(chan zonecustody.Pins, 1)
			var claimCalls, receiptCalls, pinCalls atomic.Int32
			var original zoneclaim.Receipt
			control := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				switch r.URL.Path {
				case "/original-enrollment-written":
					custodyControlHandler(map[string]*capabilityStage{r.URL.Path: committedEnrollment}, pins).ServeHTTP(w, r)
					return
				case "/original-enrolled":
					custodyControlHandler(map[string]*capabilityStage{r.URL.Path: acceptedEnrollment}, pins).ServeHTTP(w, r)
					return
				case "/receipt":
					receiptCalls.Add(1)
					if r.Method != http.MethodGet || claimCalls.Add(1) != 1 {
						t.Error("native original claim repeated")
						w.WriteHeader(409)
						return
					}
					original, err = client.ClaimWithReceipt(r.Context(), binding, handoff.Token, 1)
					if err != nil {
						t.Error("native original claim refused", err)
						w.WriteHeader(502)
						return
					}
					custodyControlHandler(map[string]*capabilityStage{r.URL.Path: claimed}, pins).ServeHTTP(httptest.NewRecorder(), r)
					if fault == "lost-receipt" {
						w.WriteHeader(502)
						return
					}
					reply := original
					if fault == "changed-binding" {
						reply.Fence.GameServerUID = "replacement-uid"
					}
					w.Header().Set("Content-Type", "application/json")
					_ = json.NewEncoder(w).Encode(reply)
					return
				case "/pins":
					pinCalls.Add(1)
					if fault == "lost-pins" {
						w.WriteHeader(502)
						return
					}
				}
				custodyControlHandler(nil, pins).ServeHTTP(w, r)
			}))
			t.Cleanup(control.Close)
			mode := "complete"
			if strings.Contains(fault, "-ack") {
				mode = fault
			}
			if fault == "complete" {
				mode = "copied"
			}
			probeEnv := originalReceiptEnv(t, binding, mode, control.URL)
			source := startRecoveryPeer(t, f, probeEnv)
			stageReached(t, committedEnrollment)
			expected := zonecustody.Observation{Lifetime: zonecustody.Lifetime{Namespace: binding.Namespace, LeaseObjectID: binding.LeaseObjectID, AttemptDigest: binding.AttemptDigest, AllocationID: binding.AllocationID, GameServerUID: binding.GameServerUID}, OwnerID: "original", ChildIncarnation: "no-gameplay-child"}
			custodyRowsFor(t, f, binding, original, 1, 0, expected)
			if claimCalls.Load() != 0 || receiptCalls.Load() != 0 || pinCalls.Load() != 0 {
				t.Fatal("visible enrollment row substituted for original ACK")
			}
			committedEnrollment.allow()
			wantClaim, wantCustody := int32(1), 1
			if strings.Contains(fault, "enrollment") {
				wantClaim, wantCustody = 0, 0
			} else {
				stageReached(t, acceptedEnrollment)
				if claimCalls.Load() != 0 {
					t.Fatal("claim preceded acceptance callback")
				}
				acceptedEnrollment.allow()
				stageReached(t, claimed)
				if fault == "source-death" {
					killJoinedSource(t, source)
				}
				claimed.allow()
				if fault == "source-death" || fault == "lost-receipt" || fault == "changed-binding" {
					wantCustody = 0
				}
			}
			switch fault {
			case "lost-receipt", "changed-binding":
				custodyRefused(t, source, "original receipt unknown")
			case "lost-pins":
				custodyRefused(t, source, "control refused")
			case "source-death":
			default:
				awaitNativeProbeReady(t, source, "7360", custodyPass+" scenario="+mode)
				killJoinedSource(t, source)
			}
			rows := custodyRowsFor(t, f, binding, original, 1, wantCustody, expected)
			if claimCalls.Load() != wantClaim || receiptCalls.Load() != wantClaim || len(pins) != 0 && fault != "complete" {
				t.Fatal("uncertain source exported pins or retried claim")
			}
			value, claimedVersion, _, _ := f.row(binding.LeaseObjectID)
			if wantClaim == 0 {
				if value != before || claimedVersion != version {
					t.Fatal("uncertain enrollment changed private claim")
				}
			} else {
				var lease struct {
					ClaimedAt *int64 `json:"claimed_at_nanos"`
					Observer  uint64 `json:"observer"`
				}
				if json.Unmarshal([]byte(value), &lease) != nil || lease.ClaimedAt == nil || *lease.ClaimedAt <= 0 || lease.Observer != 1 || claimedVersion == version || original.Fence.LeaseVersion != claimedVersion || original.Fence.Generation.UnixNano() != *lease.ClaimedAt || !original.Matches(binding, 1) {
					t.Fatal("originating native receipt differs from durable private claim")
				}
			}
			if fault == "complete" {
				if len(pins) != 1 || pinCalls.Load() != 1 {
					t.Fatal("original storage acknowledgments not delivered")
				}
				retained := <-pins
				if !retained.Receipt.Equal(original) || retained.EnrollmentVersion != rows[zonecustody.EnrollmentCollection].Version || retained.CustodyVersion != rows[zonecustody.CustodyCollection].Version {
					t.Fatal("original ACK pins changed actual receipt or storage versions")
				}
				reader := startRecoveryPeer(t, f, custodyReadEnv(t, retained))
				awaitNativeProbeReady(t, reader, "7360", custodyPass+" scenario=read writes=0 pins=true")
				reader.stop(t)
			}
			// Both same-correlation and replacement processes lose the immutable
			// enrollment create before receipt retrieval; readback restores no handle.
			for _, child := range []string{"no-gameplay-child", "replacement"} {
				restart := maps.Clone(probeEnv)
				restart["WAR_ZONE_CUSTODY_PROBE_SCENARIO"] = "complete"
				if child == "replacement" {
					restart["WAR_ZONE_CUSTODY_PROBE_INPUT"] = strings.Replace(restart["WAR_ZONE_CUSTODY_PROBE_INPUT"], "no-gameplay-child", child, 1)
				}
				rejected := startRecoveryPeer(t, f, restart)
				custodyRefused(t, rejected, "enrollment unknown")
			}
			if !equalCustodyRows(rows, custodyRowsFor(t, f, binding, original, 1, wantCustody, expected)) || claimCalls.Load() != wantClaim || receiptCalls.Load() != wantClaim {
				t.Fatal("fresh process adopted custody or reclaimed the receipt")
			}
			if gotAllocations, gotRequests := f.counts(); gotAllocations != allocations || gotRequests != requests+int(wantClaim) {
				t.Fatal("receipt composition produced extra provider effects")
			}
			t.Logf("ORIGINAL CLAIM CUSTODY PASS: cut=%s enrollment=1 claim=%d custody=%d accepted_pins=%t restarts_refused=2 gameplay_spawns=0", fault, wantClaim, wantCustody, fault == "complete")
		})
	}
}
