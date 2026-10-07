//go:build war_native_trial

package nakamatrial

import (
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"maps"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"syscall"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/claimrpc"
)

// TestLockedBundleLoadsAndRejectsMismatch proves an actual plugin load, not a compile.
func TestLockedBundleLoadsAndRejectsMismatch(t *testing.T) {
	f := newFixture(t)
	bytes, e := os.ReadFile(filepath.Join(*bundle, "bundle.json"))
	if e != nil {
		t.Fatal(e)
	}
	var evidence struct {
		Schema    int               `json:"schema"`
		OS        string            `json:"os"`
		Go        string            `json:"go_version"`
		Artifacts map[string]string `json:"artifact_sha256"`
	}
	if json.Unmarshal(bytes, &evidence) != nil || evidence.Schema != 1 || evidence.OS != "linux" || evidence.Go != "go1.27.1" || len(evidence.Artifacts) != 2 {
		t.Fatal("native bundle evidence incomplete")
	}
	for name, digest := range evidence.Artifacts {
		data, e := os.ReadFile(filepath.Join(*bundle, name))
		if e != nil {
			t.Fatal(e)
		}
		sum := sha256.Sum256(data)
		if hex.EncodeToString(sum[:]) != digest {
			t.Fatal("native bundle artifact changed")
		}
	}
	p := f.launch(map[string]string{}, filepath.Join(*bundle, "modules"), 10, true)
	if !strings.Contains(p.log.String(), "Go runtime modules loaded") {
		t.Fatal("native runtime did not report loaded WAR module")
	}
	p.stop(t)
	bad := filepath.Join(*bundle, "mismatched-modules")
	if entries, e := os.ReadDir(bad); e != nil || len(entries) != 1 {
		t.Fatal("deliberately mismatched plugin missing")
	}
	refused := f.launch(map[string]string{}, bad, 10, false)
	if refused.err == nil || !strings.Contains(refused.log.String(), "plugin") {
		t.Fatal("native runtime did not reject incompatible plugin")
	}
}

// TestDisabledNativeStartup proves absent/false flags ignore malformed subsettings.
func TestDisabledNativeStartup(t *testing.T) {
	f := newFixture(t)
	t.Setenv("WAR_HANDOFF_ENABLED", "true")
	for _, flag := range []string{"", "false"} {
		env := map[string]string{"WAR_HANDOFF_ALLOCATOR_ADDRESS": "malformed-private-fixture", "WAR_HANDOFF_CLAIMS_ENABLED": "true", "WAR_HANDOFF_CLAIMS_ADDRESS": "127.0.0.1:7443", "WAR_HANDOFF_ORPHANS_ENABLED": "true", "WAR_HANDOFF_ORPHANS_INTERVAL": "bad"}
		if flag != "" {
			env["WAR_HANDOFF_ENABLED"] = flag
		}
		f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
		token, _ := f.account("disabled-fixture-account")
		code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", token, "{}")
		if code == 200 {
			t.Fatal("disabled native module registered public RPC")
		}
		conn, e := net.DialTimeout("tcp", "127.0.0.1:7443", 100*time.Millisecond)
		if e == nil {
			_ = conn.Close()
			t.Fatal("disabled native module bound private listener")
		}
		time.Sleep(100 * time.Millisecond)
		if allocated, requests := f.counts(); allocated != 0 || requests != 0 {
			t.Fatal("disabled native module contacted external fixture")
		}
		f.process.stop(t)
	}
}

// TestEnabledNativeStartupRefusesInvalidDependencies exercises the plugin boundary.
func TestEnabledNativeStartupRefusesInvalidDependencies(t *testing.T) {
	f := newFixture(t)
	privateMarker := filepath.Join(f.dir, "sensitive-fixture-material")
	if e := os.WriteFile(privateMarker, []byte("sensitive-fixture-key-bytes"), 0600); e != nil {
		t.Fatal(e)
	}
	_, _, otherPEM := newCA(t)
	untrustedPath := filepath.Join(f.dir, "untrusted-ca.pem")
	if err := os.WriteFile(untrustedPath, otherPEM, 0600); err != nil {
		t.Fatal(err)
	}
	for _, broken := range []map[string]string{
		{"WAR_HANDOFF_LEASE_TTL": "bad"},
		{"WAR_HANDOFF_ALLOCATOR_KEY_FILE": privateMarker},
		{"WAR_HANDOFF_ALLOCATOR_CA_FILE": untrustedPath},
		{"WAR_HANDOFF_ALLOCATOR_ADDRESS": "localhost:1"},
		{"WAR_HANDOFF_CLAIMS_ENABLED": "true", "WAR_HANDOFF_CLAIMS_CERT_FILE": privateMarker},
	} {
		env := maps.Clone(f.env)
		maps.Copy(env, broken)
		p := f.launch(env, filepath.Join(*bundle, "modules"), 10, false)
		if p.err == nil {
			t.Fatal("invalid enabled native startup succeeded")
		}
		if strings.Contains(p.log.String(), "sensitive-fixture-") {
			t.Fatal("native initialization disclosed private material")
		}
		conn, e := net.DialTimeout("tcp", "127.0.0.1:7443", 100*time.Millisecond)
		if e == nil {
			_ = conn.Close()
			t.Fatal("failed startup retained private listener")
		}
		if allocated, requests := f.counts(); allocated != 0 || requests != 0 {
			t.Fatal("failed startup launched allocation or cleanup")
		}
	}
}

// TestNativeSessionAuthenticatesHandoff refuses player-supplied authority.
func TestNativeSessionAuthenticatesHandoff(t *testing.T) {
	f := newFixture(t)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	token, uid := f.account("authenticated-fixture-a")
	for _, request := range []struct{ token, path, payload string }{
		{"", "/v2/rpc/war_handoff?unwrap", "{}"},
		{"", "/v2/rpc/war_handoff?unwrap&http_key=native-fixture-http-key", "{}"},
		{token, "/v2/rpc/war_handoff?unwrap", `{"reservation":"another"}`},
		{token, "/v2/rpc/war_handoff?unwrap", `{"user_id":"another"}`},
	} {
		code, _ := f.request("POST", request.path, request.token, request.payload)
		if code == 200 {
			t.Fatal("native RPC accepted anonymous or client authority")
		}
	}
	if allocations, _ := f.counts(); allocations != 0 {
		t.Fatal("refused native request allocated capacity")
	}
	first := f.handoff(token)
	f.verifyHandoff("zone-1", first)
	before, version, _, _ := f.row(leaseKey(uid))
	secondToken, secondUID := f.account("authenticated-fixture-b")
	if uid == secondUID {
		t.Fatal("separate fixture accounts authenticated as the same player")
	}
	second := f.handoff(secondToken)
	f.verifyHandoff("zone-2", second)
	if first.ServerName == second.ServerName || first.Token == second.Token {
		t.Fatal("separate native accounts shared a reservation")
	}
	again := f.handoff(token)
	f.verifyHandoff("zone-1", again)
	after, afterVersion, _, _ := f.row(leaseKey(uid))
	if again.ServerName != first.ServerName || again.Port != first.Port || before != after || version != afterVersion {
		t.Fatal("another account replaced first reservation")
	}
	if allocated, _ := f.counts(); allocated != 2 {
		t.Fatal("native same-process replay redispatched allocation")
	}
}

// TestNativePrivateStorageAndCAS checks zero-owner privacy and concurrent requests.
func TestNativePrivateStorageAndCAS(t *testing.T) {
	f := newFixture(t)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	token, uid := f.account("concurrent-native-fixture")
	var workers sync.WaitGroup
	for range 8 {
		workers.Go(func() {
			code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", token, "{}")
			if code == 401 {
				t.Error("valid session lost authentication")
			}
		})
	}
	workers.Wait()
	f.handoff(token)
	if allocations, _ := f.counts(); allocations != 1 {
		t.Fatalf("native CAS permitted %d allocation effects", allocations)
	}
	key := leaseKey(uid)
	before, version, read, write := f.row(key)
	if version == "" || read != 0 || write != 0 {
		t.Fatal("native response preceded private durable storage")
	}
	code, data := f.request("POST", "/v2/storage", token, fmt.Sprintf(`{"object_ids":[{"collection":"%s","key":"%s"}]}`, collection, key))
	var objects struct {
		Objects []json.RawMessage `json:"objects"`
	}
	if code != 200 || json.Unmarshal(data, &objects) != nil || len(objects.Objects) != 0 {
		t.Fatal("native public read disclosed system-owned lease")
	}
	code, _ = f.request("PUT", "/v2/storage", token, fmt.Sprintf(`{"objects":[{"collection":"%s","key":"%s","value":"{}"}]}`, collection, key))
	if code != 200 {
		t.Fatal("fixture same-key player write unexpectedly refused")
	}
	after, afterVersion, _, _ := f.row(key)
	if after != before || afterVersion != version {
		t.Fatal("public player write modified native system-owned lease")
	}
}

// TestNativeRestartRetainsReplayAndAmbiguity reuses the actual PostgreSQL database.
func TestNativeRestartRetainsReplayAndAmbiguity(t *testing.T) {
	f := newFixture(t)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	token, replayUID := f.account("restart-native-fixture")
	first := f.handoff(token)
	f.verifyHandoff("zone-1", first)
	replayBefore, replayVersion, _, _ := f.row(leaseKey(replayUID))
	var lease struct {
		Expires int64 `json:"expires_at_nanos"`
	}
	if json.Unmarshal([]byte(replayBefore), &lease) != nil || lease.Expires == 0 {
		t.Fatal("native replay has no durable expiry")
	}
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	again := f.handoff(token)
	f.verifyHandoff("zone-1", again)
	replayAfter, replayAfterVersion, _, _ := f.row(leaseKey(replayUID))
	if again.ServerName != first.ServerName || again.Port != first.Port || again.ExpiresAt.After(time.Unix(0, lease.Expires)) || replayBefore != replayAfter || replayVersion != replayAfterVersion {
		t.Fatal("native restart lost acknowledged handoff")
	}
	if allocated, _ := f.counts(); allocated != 1 {
		t.Fatal("native replay redispatched allocation")
	}
	ambiguousToken, uid := f.account("ambiguous-native-fixture")
	f.mu.Lock()
	f.ambiguous = true
	f.mu.Unlock()
	code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", ambiguousToken, "{}")
	if code == 200 {
		t.Fatal("ambiguous native dispatch acknowledged")
	}
	f.mu.Lock()
	delete(f.servers, "zone-2")
	f.mu.Unlock()
	key := leaseKey(uid)
	before, version, _, _ := f.row(key)
	if !strings.Contains(before, `"dispatched": true`) {
		t.Fatal("native dispatch was not durable")
	}
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	for range 2 {
		code, _ = f.request("POST", "/v2/rpc/war_handoff?unwrap", ambiguousToken, "{}")
		if code == 200 {
			t.Fatal("unresolved native dispatch was replaced")
		}
	}
	after, afterVersion, _, _ := f.row(key)
	if allocated, _ := f.counts(); allocated != 2 || before != after || version != afterVersion {
		t.Fatal("native restart changed ambiguous ownership")
	}
}

// TestNativePrivateClaimPersistsExactWorkload verifies the private listener and DB.
func TestNativePrivateClaimPersistsExactWorkload(t *testing.T) {
	f := newFixture(t)
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
	env["WAR_HANDOFF_LEASE_TTL"] = "8s"
	f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	token, uid := f.account("private-native-fixture")
	roots := x509.NewCertPool()
	roots.AppendCertsFromPEM(f.claimsPEM)
	peer, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/zone/world-at-ruin/zone-1-uid", false)
	wrong, _, _ := newCertificate(t, f.claimsCA, f.claimsKey, "spiffe://fixture.example/zone/world-at-ruin/wrong-uid", false)
	otherCA, otherKey, _ := newCA(t)
	untrusted, _, _ := newCertificate(t, otherCA, otherKey, "spiffe://fixture.example/zone/world-at-ruin/zone-1-uid", false)
	handoff := f.handoff(token)
	gs := f.resource("zone-1")
	key := leaseKey(uid)
	binding := agones.ClaimBinding{Namespace: "world-at-ruin", AllocationID: gs.Name, GameServerUID: string(gs.UID), LeaseObjectID: key, AttemptDigest: gs.Labels[agones.AttemptLabel]}
	before, version, _, _ := f.row(key)
	for _, certificate := range []tls.Certificate{wrong, untrusted} {
		client, e := claimrpc.NewClient("https://localhost:7443/v1/claim", &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{certificate}})
		if e != nil {
			t.Fatal(e)
		}
		e = client.Claim(context.Background(), binding, handoff.Token, 1)
		client.Close()
		if e == nil {
			t.Fatal("native private claim accepted wrong workload")
		}
	}
	anonymous := &http.Client{Transport: &http.Transport{TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots}}, Timeout: time.Second}
	if response, e := anonymous.Get("https://localhost:7443/v1/claim"); e == nil {
		_ = response.Body.Close()
		t.Fatal("native private listener accepted anonymous peer")
	}
	anonymous.CloseIdleConnections()
	after, afterVersion, _, _ := f.row(key)
	if before != after || version != afterVersion {
		t.Fatal("refused private peer modified durable ownership")
	}
	client, e := claimrpc.NewClient("https://localhost:7443/v1/claim", &tls.Config{MinVersion: tls.VersionTLS12, RootCAs: roots, Certificates: []tls.Certificate{peer}})
	if e != nil {
		t.Fatal(e)
	}
	defer client.Close()
	stale := binding
	stale.AttemptDigest = strings.Repeat("a", 52)
	if e = client.Claim(context.Background(), stale, handoff.Token, 1); e == nil {
		t.Fatal("native private claim accepted stale attempt")
	}
	staleValue, staleVersion, _, _ := f.row(key)
	if staleValue != before || staleVersion != version {
		t.Fatal("refused stale claim modified native ownership")
	}
	f.mu.Lock()
	f.servers[gs.Name].UID = "replacement-uid"
	f.mu.Unlock()
	if e = client.Claim(context.Background(), binding, handoff.Token, 1); e == nil {
		t.Fatal("native private claim accepted replacement resource")
	}
	replacedValue, replacedVersion, _, _ := f.row(key)
	if replacedValue != before || replacedVersion != version {
		t.Fatal("refused replacement claim modified native ownership")
	}
	f.mu.Lock()
	f.servers[gs.Name].UID = gs.UID
	f.mu.Unlock()
	if _, e = client.ClaimWithReceipt(context.Background(), binding, handoff.Token, 1); e != nil {
		t.Fatal("exact native private claim refused")
	}
	claimed, newVersion, _, _ := f.row(key)
	if newVersion == version || strings.Contains(claimed, `"claimed_at_nanos": null`) {
		t.Fatal("private acknowledgement preceded durable claim")
	}
	code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", token, "{}")
	if code == 200 {
		t.Fatal("native public retry replaced claimed reservation")
	}
	canaryToken, _ := f.account("private-native-canary")
	canary := f.handoff(canaryToken)
	f.verifyHandoff("zone-2", canary)
	f.process.stop(t)
	if f.resource("zone-2") == nil {
		t.Fatal("unclaimed canary expired before native restart")
	}
	f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	waitFor(t, 20*time.Second, "post-restart expiry sweep reclaimed the unclaimed canary", func() bool { return f.resource("zone-2") == nil })
	retained, retainedVersion, _, _ := f.row(key)
	if retained != claimed || retainedVersion != newVersion || f.resource(gs.Name) == nil {
		t.Fatal("native restart/expiry reclaimed a claimed lease")
	}
}

// TestNativePeriodicExpiryRetriesExactCleanup runs the real supervised worker.
func TestNativePeriodicExpiryRetriesExactCleanup(t *testing.T) {
	f := newFixture(t)
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_LEASE_TTL"] = "4s"
	f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	token, uid := f.account("expiry-native-fixture")
	f.handoff(token)
	deleteResponse := make(chan struct{})
	resumeDelete := sync.OnceFunc(func() { close(deleteResponse) })
	t.Cleanup(resumeDelete)
	f.mu.Lock()
	f.retryDelete = true
	f.deleteResponse = deleteResponse
	f.mu.Unlock()
	waitFor(t, 15*time.Second, "native failed cleanup", func() bool { f.mu.Lock(); defer f.mu.Unlock(); return len(f.deleted) > 0 })
	releasing, _, _, _ := f.row(leaseKey(uid))
	if !strings.Contains(releasing, `"releasing": true`) {
		t.Fatal("native failed cleanup lost its durable releasing transition")
	}
	leaseCount := func() (int, error) {
		var count int
		err := f.db.QueryRow("SELECT count(*) FROM storage WHERE collection=$1 AND key=$2 AND user_id=$3::uuid", collection, leaseKey(uid), zeroOwner).Scan(&count)
		return count, err
	}
	waitFor(t, 10*time.Second, "native expiry resource deletion", func() bool { return f.resource("zone-1") == nil })
	if count, err := leaseCount(); err != nil {
		t.Fatal("native lease retirement observation failed")
	} else if count != 1 {
		t.Fatal("native lease retired before deletion acknowledgement")
	}
	complete, err := nativeRetirementComplete(true, leaseCount)
	if err != nil {
		t.Fatal("native lease retirement observation failed")
	}
	if complete {
		t.Fatal("native cleanup completed with durable ownership still present")
	}
	resumeDelete()
	waitFor(t, 10*time.Second, "native expiry retry and exact lease retirement", func() bool {
		complete, err := nativeRetirementComplete(f.resource("zone-1") == nil, leaseCount)
		if err != nil {
			t.Fatal("native lease retirement observation failed")
		}
		return complete
	})
	f.mu.Lock()
	attempts := len(f.deleted)
	f.mu.Unlock()
	if attempts < 2 {
		t.Fatal("native expiry did not retry transient cleanup")
	}
}

// TestNativeHistoricalRowsRemainMutationIneligible exercises retained JSONB rows.
func TestNativeHistoricalRowsRemainMutationIneligible(t *testing.T) {
	f := newFixture(t)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	token, uid := f.account("historical-native-fixture")
	f.process.stop(t)
	data, e := os.ReadFile("nakamalease/testdata/golden_lease_v4.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixtures []json.RawMessage
	if json.Unmarshal(data, &fixtures) != nil || len(fixtures) != 7 {
		t.Fatal("retained native fixture family incomplete")
	}
	key := leaseKey(uid)
	f.seed(key, fixtures[2])
	before, version, _, _ := f.row(key)
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", token, "{}")
	if code == 200 {
		t.Fatal("reader-only native lease admitted mutation")
	}
	after, afterVersion, _, _ := f.row(key)
	if before != after || version != afterVersion {
		t.Fatal("native worker mutated historical reader-only lease")
	}
	if allocated, requests := f.counts(); allocated != 0 || requests != 0 {
		t.Fatal("historical native lease redispatched allocation")
	}
}

// TestNativeOrphanSupervisionPreservesEvidence checks pagination, grace and logging.
func TestNativeOrphanSupervisionPreservesEvidence(t *testing.T) {
	f := newFixture(t)
	data, e := os.ReadFile("nakamalease/testdata/golden_lease_v4.json")
	if e != nil {
		t.Fatal(e)
	}
	var fixtures []json.RawMessage
	if json.Unmarshal(data, &fixtures) != nil {
		t.Fatal("invalid retained fixtures")
	}
	for i := range 105 {
		value := fixtures[i%len(fixtures)]
		if i < 100 {
			var padding map[string]json.RawMessage
			if json.Unmarshal(fixtures[0], &padding) != nil {
				t.Fatal("invalid padding fixture")
			}
			padding["attempt_id"], _ = json.Marshal(fmt.Sprintf("padding-attempt-%d", i))
			value, _ = json.Marshal(padding)
		}
		f.seed(fmt.Sprintf("%064x", i+1), value)
	}
	protected := f.makeServer("gameserver-17", "attempt-7")
	orphan := f.makeServer("true-orphan", "orphan-attempt")
	f.mu.Lock()
	f.servers[protected.Name] = protected
	f.servers[orphan.Name] = orphan
	f.apiFault = "partial"
	f.mu.Unlock()
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
	env["WAR_HANDOFF_ORPHANS_GRACE"] = "30s"
	env["WAR_HANDOFF_ORPHANS_INTERVAL"] = "1s"
	env["WAR_HANDOFF_ORPHANS_TIMEOUT"] = "3s"
	p := f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	firstProcess := p
	waitFor(t, 8*time.Second, "native incomplete observation", func() bool { return strings.Contains(p.log.String(), "outcome=incomplete") })
	if f.resource(orphan.Name) == nil {
		t.Fatal("incomplete native evidence deleted orphan")
	}
	f.mu.Lock()
	f.apiFault = ""
	f.mu.Unlock()
	waitFor(t, 10*time.Second, "native full private-owner scan", func() bool { return strings.Contains(p.log.String(), "protected=1") })
	// Restart discards the grace accumulated by the previous native process.
	time.Sleep(2 * time.Second)
	p = f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
	started := time.Now()
	waitFor(t, 40*time.Second, "native orphan grace deletion", func() bool { return f.resource(orphan.Name) == nil })
	if time.Since(started) < 29*time.Second || f.resource(protected.Name) == nil {
		t.Fatal("native orphan cleanup bypassed grace or historical protection")
	}
	log := firstProcess.log.String() + "\n" + p.log.String()
	f.mu.Lock()
	pages := f.pages
	f.mu.Unlock()
	if pages == 0 {
		t.Fatal("native orphan worker did not complete resource pagination")
	}
	if strings.Contains(log, "provider-private-details") {
		t.Fatal("native WAR observations exposed provider errors")
	}
	for _, line := range strings.Split(log, "\n") {
		if strings.Contains(line, "zone orphan sweep") && (strings.Contains(line, "gameserver-17") || strings.Contains(line, "true-orphan") || strings.Contains(line, "attempt-7")) {
			t.Fatal("native WAR count log exposed identities")
		}
	}
}

// TestNativeSIGTERMStopsAdmissionAndCancelsWork observes native drain and deadline paths.
func TestNativeSIGTERMStopsAdmissionAndCancelsWork(t *testing.T) {
	f := newFixture(t)
	env := maps.Clone(f.env)
	env["WAR_HANDOFF_CLAIMS_ENABLED"] = "true"
	for index, grace := range []int{10, 1} {
		p := f.launch(env, filepath.Join(*bundle, "modules"), grace, true)
		token, uid := f.account(fmt.Sprintf("shutdown-native-fixture-%d", index))
		newcomer, _ := f.account(fmt.Sprintf("shutdown-newcomer-%d", index))
		for {
			select {
			case <-f.connClosed:
				continue
			default:
			}
			break
		}
		f.mu.Lock()
		f.hold = make(chan struct{})
		f.entered = make(chan struct{}, 1)
		f.cancelled = make(chan struct{}, 1)
		entered, cancelled := f.entered, f.cancelled
		f.mu.Unlock()
		returned := make(chan struct{})
		go func() {
			defer close(returned)
			request, _ := http.NewRequest("POST", "http://127.0.0.1:7350/v2/rpc/war_handoff?unwrap", strings.NewReader("{}"))
			request.Header.Set("Authorization", "Bearer "+token)
			request.Header.Set("Content-Type", "application/json")
			response, e := (&http.Client{Timeout: 12 * time.Second}).Do(request)
			if e == nil {
				_ = response.Body.Close()
				if response.StatusCode == 200 {
					t.Error("cancelled native handoff acknowledged")
				}
			}
		}()
		select {
		case <-entered:
		case <-time.After(5 * time.Second):
			t.Fatal("held native allocator was never called")
		}
		before, version, _, _ := f.row(leaseKey(uid))
		lock, e := f.db.Begin()
		if e != nil {
			t.Fatal(e)
		}
		t.Cleanup(func() { _ = lock.Rollback() })
		lockCtx, cancelLock := context.WithTimeout(context.Background(), 3*time.Second)
		_, e = lock.ExecContext(lockCtx, "LOCK TABLE storage IN ACCESS EXCLUSIVE MODE")
		cancelLock()
		if e != nil {
			t.Fatal("hold native storage table")
		}
		started := time.Now()
		if e = p.cmd.Process.Signal(syscall.SIGTERM); e != nil {
			t.Fatal(e)
		}
		select {
		case <-cancelled:
		case <-time.After(3 * time.Second):
			t.Fatal("native shutdown did not cancel allocator")
		}
		waitFor(t, 2*time.Second, "detached native storage read", func() bool {
			var count int
			ctx, cancel := context.WithTimeout(context.Background(), time.Second)
			defer cancel()
			e := f.admin.QueryRowContext(ctx, "SELECT count(*) FROM pg_stat_activity WHERE datname=$1 AND wait_event_type='Lock' AND query LIKE '%storage%'", f.dbName).Scan(&count)
			return e == nil && count > 0
		})
		if grace == 10 {
			code, _ := f.request("POST", "/v2/rpc/war_handoff?unwrap", newcomer, "{}")
			if code == 200 {
				t.Fatal("native grace period admitted a new handoff")
			}
			conn, e := net.DialTimeout("tcp", "127.0.0.1:7443", 100*time.Millisecond)
			if e == nil {
				_ = conn.Close()
				t.Fatal("native grace retained private admission")
			}
			select {
			case <-returned:
				t.Fatal("native handler finished before held storage returned")
			default:
			}
			select {
			case <-p.done:
				t.Fatal("native shutdown claimed drain before storage returned")
			default:
			}
			select {
			case <-f.connClosed:
				t.Fatal("native allocator transport retired beneath admitted work")
			default:
			}
			if e = lock.Rollback(); e != nil {
				t.Fatal(e)
			}
			select {
			case <-returned:
			case <-time.After(8 * time.Second):
				t.Fatal("native shutdown did not drain admitted handler")
			}
			select {
			case <-f.connClosed:
			case <-time.After(8 * time.Second):
				t.Fatal("native drain did not retire allocator transport")
			}
		} else {
			// Nakama's own grace may end while the detached read is still blocked.
			// Process exit does not certify an external allocator fence or completion.
			select {
			case <-p.done:
			case <-time.After(8 * time.Second):
				t.Fatal("native deadline did not bound process shutdown")
			}
			if time.Since(started) > 7*time.Second {
				t.Fatal("native deadline overran its bounded shutdown")
			}
			if e = lock.Rollback(); e != nil {
				t.Fatal(e)
			}
			select {
			case <-returned:
			case <-time.After(3 * time.Second):
				t.Fatal("native deadline did not end the HTTP request")
			}
		}
		select {
		case <-p.done:
		case <-time.After(12 * time.Second):
			t.Fatal("native shutdown did not finish")
		}
		if p.err != nil {
			t.Fatal("native SIGTERM returned unsuccessful process status")
		}
		after, afterVersion, _, _ := f.row(leaseKey(uid))
		if before != after || version != afterVersion || !strings.Contains(after, `"dispatched": true`) {
			t.Fatal("native shutdown lost unresolved dispatch ownership")
		}
		if allocations, _ := f.counts(); allocations != index+1 {
			t.Fatal("native shutdown allocated a replacement attempt")
		}
	}
}
