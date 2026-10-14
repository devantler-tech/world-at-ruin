//go:build war_native_trial && war_issued_trial && war_issued_spire && linux

package nakamatrial

import (
	"context"
	"encoding/json"
	"errors"
	"io"
	"maps"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/testfixture/spire"
	"github.com/devantler-tech/world-at-ruin/server/zoneclaim"
)

var originalCustodyCuts = []string{"complete", "lost-enrollment-ack", "cancel-enrollment-ack", "lost-receipt", "changed-binding", "lost-custody-ack", "cancel-custody-ack", "source-death", "lost-pins"}

// Correlation is checked before the response can reach an original HTTP waiter.
func issuedPhase(message issuedMessage, cut, operation string, sequence uint64) bool {
	return message.Case == cut && message.Op == operation && message.Seq == sequence
}

func TestNativeIssuedOriginalClaimCustody(t *testing.T) {
	for _, wrong := range []issuedMessage{
		{Case: "replacement", Op: "receipt", Seq: 2},
		{Case: "complete", Op: "claim", Seq: 2},
		{Case: "complete", Op: "receipt", Seq: 1},
	} {
		if issuedPhase(wrong, "complete", "receipt", 2) {
			t.Fatal("unrelated IPC response adopted")
		}
	}
	for _, cut := range originalCustodyCuts {
		t.Run(cut, func(t *testing.T) {
			c := newIssuedController(t)
			issuer := spire.Start(t, c.ctx, c.directory, "custody", 18443, []spire.Entry{{ID: issuedServerURI, UID: 10001, DNS: issuedServerDNS}}, c.runner)
			coordinator := c.startWorker("custody", 10001, issuer, issuedServerURI, cut)
			handoff := coordinator.read(t)
			if !issuedPhase(handoff, cut, "handoff", 0) || handoff.Token == "" || handoff.Binding.GameServerUID == "" {
				t.Fatal("issued custody handoff missing or unrelated")
			}
			principal := "spiffe://war-fixture.test/zone/" + handoff.Binding.Namespace + "/" + handoff.Binding.GameServerUID
			spire.Register(t, c.ctx, issuer, []spire.Entry{{ID: principal, UID: 10004}}, c.runner)
			zone := c.startWorker("zone", 10004, issuer, principal)
			if ready := zone.read(t); ready.Op != "ready" || ready.ID != principal {
				t.Fatal("exact issued zone not ready before original enrollment")
			}
			if err := coordinator.encoder.Encode(issuedMessage{Op: "begin", Case: cut, Seq: 1}); err != nil {
				t.Fatal("original custody start failed")
			}
			next := coordinator.read(t)
			wantClaim := !strings.Contains(cut, "enrollment")
			if wantClaim {
				if !issuedPhase(next, cut, "claim", 2) || next.Binding != handoff.Binding || next.Token != handoff.Token || next.DNS != issuedServerDNS || next.URI != issuedServerURI || next.Credential != "" {
					t.Fatal("original GET did not request the exact sole claim")
				}
				deadline := time.Now().Add(5 * time.Second)
				if err := zone.encoder.Encode(next); err != nil {
					t.Fatal("issued zone command failed")
				}
				reply := zone.readBefore(t, deadline)
				if !issuedPhase(reply, cut, "claim", 2) || !reply.Accepted || !reply.Receipt.Matches(handoff.Binding, 1) {
					t.Fatal("issued original claim refused or unrelated")
				}
				reply.Op = "receipt"
				if time.Now().After(deadline) || coordinator.encoder.Encode(reply) != nil {
					t.Fatal("original receipt bridge exceeded its deadline")
				}
				next = coordinator.read(t)
			}
			if !issuedPhase(next, cut, "complete", 3) {
				t.Fatal("issued original custody verdict missing or extra claim requested")
			}
			c.close(t)
			if !t.Failed() {
				t.Logf("ISSUED ORIGINAL CUSTODY PASS: cut=%s real_process_snapshots=true original_get_claim=%t restarts_refused=2 exact_joins=true", cut, wantClaim)
			}
		})
	}
}

type custodyIPCResult struct {
	message issuedMessage
	err     error
}

type custodyIPCEvent struct {
	ctx     context.Context
	message issuedMessage
	reply   chan custodyIPCResult
}

// The worker's main goroutine exclusively owns the private protocol. The native
// subtest and its HTTP handlers exchange bounded events; they never use FD3.
func issuedCustodyWorker(t *testing.T, input *os.File, encoder *json.Encoder, decoder *json.Decoder) {
	if !containsCustodyCut(*issuedCut) {
		t.Fatal("unknown original custody cut")
	}
	ctx, cancel := context.WithTimeout(t.Context(), 45*time.Second)
	defer cancel()
	events := make(chan custodyIPCEvent)
	done := make(chan bool, 1)
	exchange := func(request context.Context, message issuedMessage) (issuedMessage, error) {
		event := custodyIPCEvent{ctx: request, message: message, reply: make(chan custodyIPCResult, 1)}
		select {
		case events <- event:
		case <-request.Done():
			return issuedMessage{}, request.Err()
		case <-ctx.Done():
			return issuedMessage{}, ctx.Err()
		}
		select {
		case result := <-event.reply:
			if request.Err() != nil || ctx.Err() != nil {
				return issuedMessage{}, errors.New("late original receipt refused")
			}
			return result.message, result.err
		case <-request.Done():
			return issuedMessage{}, request.Err()
		case <-ctx.Done():
			return issuedMessage{}, ctx.Err()
		}
	}
	go func() {
		done <- t.Run("owned-native", func(t *testing.T) {
			f := newFixture(t)
			env := f.issuedClaimsEnv(*issuedAPI)
			env["WAR_HANDOFF_CLAIMS_TRUST_DOMAIN"] = "war-fixture.test"
			env["WAR_ISSUED_CLAIMS_SERVER_DNS"] = issuedServerDNS
			env["WAR_ISSUED_CLAIMS_SERVER_URI"] = issuedServerURI
			main := f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
			issuedSnapshot(t, main)
			token, user := f.account("issued-original-receipt")
			handoff := f.handoff(token)
			gs := f.resource("zone-1")
			binding := agones.ClaimBinding{Namespace: "world-at-ruin", AllocationID: gs.Name, GameServerUID: string(gs.UID), LeaseObjectID: leaseKey(user), AttemptDigest: gs.Labels[agones.AttemptLabel]}
			request := issuedMessage{Op: "handoff", Case: *issuedCut, Seq: 0, Token: handoff.Token, Binding: binding}
			if _, err := exchange(ctx, request); err != nil {
				t.Fatal("original source readiness coordination failed")
			}
			peerEnv := maps.Clone(env)
			peerEnv["WAR_HANDOFF_CLAIMS_ADDRESS"] = "127.0.0.1:7444"
			exerciseOriginalClaimCustody(t, *issuedCut, originalCustodyTrial{f: f, binding: binding, peerEnv: peerEnv, observe: issuedSnapshot, claim: func(parent context.Context) (zoneclaim.Receipt, error) {
				bridge, stop := context.WithTimeout(parent, 5*time.Second)
				defer stop()
				message := issuedMessage{Op: "claim", Case: *issuedCut, Seq: 2, Token: handoff.Token, Binding: binding, DNS: issuedServerDNS, URI: issuedServerURI}
				reply, err := exchange(bridge, message)
				if err != nil || !reply.Accepted || !reply.Receipt.Matches(binding, 1) {
					return zoneclaim.Receipt{}, errors.New("original issued receipt unknown")
				}
				return reply.Receipt, nil
			}})
		})
	}()
	phase := uint64(0)
	for {
		select {
		case event := <-events:
			operation, sequence := "begin", uint64(1)
			valid := phase == 0 && issuedPhase(event.message, *issuedCut, "handoff", 0)
			if phase == 1 && issuedPhase(event.message, *issuedCut, "claim", 2) && !strings.Contains(*issuedCut, "enrollment") {
				operation, sequence, valid = "receipt", 2, true
			}
			result := custodyIPCResult{err: errors.New("original protocol phase refused")}
			if valid && event.ctx.Err() == nil {
				deadline, ok := event.ctx.Deadline()
				if !ok {
					deadline = time.Now().Add(5 * time.Second)
				}
				if input.SetReadDeadline(deadline) == nil && encoder.Encode(event.message) == nil {
					var reply issuedMessage
					if decoder.Decode(&reply) == nil && event.ctx.Err() == nil && issuedPhase(reply, *issuedCut, operation, sequence) {
						result = custodyIPCResult{message: reply}
						phase++
					}
				}
			}
			event.reply <- result
			if result.err != nil {
				cancel()
			}
		case passed := <-done:
			want := uint64(2)
			if strings.Contains(*issuedCut, "enrollment") {
				want = 1
			}
			if !passed || phase != want || ctx.Err() != nil {
				t.Error("issued custody subtest or complete protocol failed")
				return
			}
			// t.Run returns only after every fixture/peer cleanup and DB drop.
			if encoder.Encode(issuedMessage{Op: "complete", Case: *issuedCut, Seq: 3}) != nil {
				t.Error("complete issued custody reply failed")
				return
			}
			var extra issuedMessage
			if input.SetReadDeadline(time.Now().Add(50*time.Second)) != nil || !errors.Is(decoder.Decode(&extra), io.EOF) {
				t.Error("unexpected command after original custody completion")
			}
			return
		}
	}
}

func containsCustodyCut(cut string) bool {
	for _, candidate := range originalCustodyCuts {
		if candidate == cut {
			return true
		}
	}
	return false
}

// A selected snapshot is not the later listener validation or original handle.
func issuedSnapshot(t *testing.T, process *nativeProcess) {
	t.Helper()
	if strings.Count(process.log.String(), "ISSUED CLAIMS SNAPSHOT FETCHED") != 1 {
		t.Fatal("exact native process did not select its own issued snapshot")
	}
}
