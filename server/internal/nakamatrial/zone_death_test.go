//go:build war_native_trial

package nakamatrial

import (
	"context"
	"encoding/json"
	"path/filepath"
	"reflect"
	"syscall"
	"testing"
	"time"
)

// killZone joins the exact owned child after an abrupt, non-cooperative death.
func (z *trialZone) killZone() {
	z.f.t.Helper()
	if err := z.process.cmd.Process.Kill(); err != nil {
		z.f.t.Fatal("kill exact owned zone", err)
	}
	select {
	case <-z.process.done:
	case <-time.After(5 * time.Second):
		z.f.t.Fatal("killed zone was not joined")
	}
	status, ok := z.process.cmd.ProcessState.Sys().(syscall.WaitStatus)
	if !ok || !status.Signaled() || status.Signal() != syscall.SIGKILL {
		z.f.t.Fatal("zone did not exit through the requested abrupt death")
	}
}

// TestClosedLoopClaimAfterZoneDeath distinguishes process exit from remote commit.
func TestClosedLoopClaimAfterZoneDeath(t *testing.T) {
	for _, peer := range []string{"ordinary", "delayed-disconnect"} {
		t.Run(peer, func(t *testing.T) {
			f, z := expiryFixture(t, peer)
			account, uid := f.account("claim-death-closed-loop")
			got := f.handoff(account)
			canary, _ := f.account("claim-death-canary")
			f.handoff(canary)
			before, version, _, _ := f.row(leaseKey(uid))
			wait, release := f.claimBlock()
			pending := z.pending(got)
			wait()
			if f.blockedClaims() != 1 {
				t.Fatal("death control did not isolate exactly one native claim writer")
			}
			writerPID := f.heldClaimWriter()
			z.killZone()
			select {
			case err := <-pending:
				if err == nil {
					t.Fatal("dead zone acknowledged pending admission")
				}
			case <-time.After(time.Second):
				t.Fatal("socket admission did not retire after exact zone death")
			}
			if peer == "ordinary" {
				waitFor(t, time.Second, "zone disconnect canceled the held native write", func() bool { return f.claimWriterRetired(writerPID) })
			} else {
				select {
				case <-z.claimDisconnected:
				case <-time.After(time.Second):
					t.Fatal("transparent transport did not observe exact zone EOF")
				}
				if f.blockedClaims() != 1 {
					t.Fatal("delayed disconnect lost the original accepted native request")
				}
			}
			after, heldVersion, _, _ := f.row(leaseKey(uid))
			if after != before || heldVersion != version {
				t.Fatal("held transaction changed original claim ownership")
			}
			release()
			waitFor(t, 2*time.Second, "original native request settled", func() bool { return f.claimWriterRetired(writerPID) })
			if peer == "ordinary" {
				after, newVersion, _, _ := f.row(leaseKey(uid))
				if after != before || newVersion != version {
					t.Fatal("canceled native request changed private ownership")
				}
				t.Log("ZONE DEATH CONTROL: ordinary disconnect canceled the original held write; private version unchanged")
				return
			}
			waitFor(t, 2*time.Second, "late native claim committed after exact zone join", func() bool {
				_, observedVersion, _, _ := f.row(leaseKey(uid))
				return observedVersion != version
			})
			claimed, claimedVersion := f.claimed(leaseKey(uid))
			if claimedVersion == version {
				t.Fatal("delayed disconnect did not commit the original claim after child join")
			}
			var originalFields, claimedFields map[string]any
			if json.Unmarshal([]byte(before), &originalFields) != nil || json.Unmarshal([]byte(claimed), &claimedFields) != nil {
				t.Fatal("decode exact private claim binding")
			}
			delete(originalFields, "claimed_at_nanos")
			delete(claimedFields, "claimed_at_nanos")
			if !reflect.DeepEqual(originalFields, claimedFields) {
				t.Fatal("late native claim changed the original allocation binding")
			}
			f.retainDeadClaim(account, uid)
			t.Log("ZONE DEATH CONTROL: delayed disconnect committed after exact child join; unacknowledged claim retained")
		})
	}
}

// TestClosedLoopAcknowledgedZoneDeath catches cleanup after a claim's zone exits.
func TestClosedLoopAcknowledgedZoneDeath(t *testing.T) {
	f, z := expiryFixture(t, "")
	account, uid := f.account("acknowledged-death-closed-loop")
	conn := z.snapshot(f.handoff(account))
	_ = conn.CloseNow()
	f.claimed(leaseKey(uid))
	canary, _ := f.account("acknowledged-death-canary")
	f.handoff(canary)
	z.killZone()
	f.retainDeadClaim(account, uid)
	t.Log("ZONE DEATH CONTROL: acknowledged claim retained after exact child join and native restart")
}

// retainDeadClaim proves active cleanup and public retry cannot adopt a diagnostic row.
// It captures no original receipt and invokes no session-completion authority.
func (f *fixture) retainDeadClaim(account, uid string) {
	f.t.Helper()
	claimed, version := f.claimed(leaseKey(uid))
	f.mu.Lock()
	allocations := f.allocationCalls
	f.mu.Unlock()
	f.process.stop(f.t)
	if f.resource("zone-b") == nil {
		f.t.Fatal("unclaimed expiry canary retired before restart")
	}
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	for range 2 {
		if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
			f.t.Fatal("dead claim admitted a replacement handoff")
		}
	}
	waitFor(f.t, 50*time.Second, "native expiry reclaimed unclaimed canary after zone death", func() bool { return f.resource("zone-b") == nil })
	if code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", account, "{}"); code == 200 {
		f.t.Fatal("expired dead claim admitted a replacement handoff")
	}
	after, afterVersion := f.claimed(leaseKey(uid))
	f.mu.Lock()
	calls := f.allocationCalls
	f.mu.Unlock()
	if after != claimed || afterVersion != version || f.resource("zone-a") == nil || calls != allocations {
		f.t.Fatal("zone death or restart released, refreshed or redispatched claimed ownership")
	}
}

// heldClaimWriter pins the independently observed PostgreSQL backend before death.
func (f *fixture) heldClaimWriter() int {
	f.t.Helper()
	ctx, cancel := context.WithTimeout(f.t.Context(), time.Second)
	defer cancel()
	var pid int
	if err := f.db.QueryRowContext(ctx, "SELECT pid FROM pg_stat_activity WHERE datname=$1 AND wait_event_type='Lock' AND query ILIKE '%storage%'", f.dbName).Scan(&pid); err != nil || pid <= 0 {
		f.t.Fatal("identify original held native storage backend")
	}
	return pid
}

// claimWriterRetired refuses settlement while the original statement remains active.
// Idle or departed is an observation of this request, never session-end authority.
func (f *fixture) claimWriterRetired(pid int) bool {
	f.t.Helper()
	ctx, cancel := context.WithTimeout(f.t.Context(), time.Second)
	defer cancel()
	var active int
	if err := f.db.QueryRowContext(ctx, "SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND pid=$2 AND state='active'", f.dbName, pid).Scan(&active); err != nil {
		f.t.Fatal("observe original native storage backend settlement")
	}
	return active == 0
}
