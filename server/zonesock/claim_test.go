package zonesock

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

type claimFunc func(context.Context, string, sim.EntityID) error

func (f claimFunc) Claim(ctx context.Context, token string, observer sim.EntityID) error {
	return f(ctx, token, observer)
}

func TestClaimedHubRequiresClaimBeforeUpgrade(t *testing.T) {
	secret := testSecret(0xa5)
	verifier, err := NewHMACVerifier(secret, "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	var refuse atomic.Bool
	refuse.Store(true)
	claim := claimFunc(func(ctx context.Context, token string, observer sim.EntityID) error {
		calls.Add(1)
		if observer != 1 || !strings.HasPrefix(token, "v3.allocation-a.1.") {
			t.Error("claim did not receive the verified observer and original token")
		}
		if _, ok := ctx.Deadline(); !ok {
			t.Error("claim has no deadline")
		}
		if refuse.Load() {
			return errors.New("private claim detail must not reach player")
		}
		return nil
	})
	hub, err := NewClaimedHub(Config{Verifier: verifier}, claim, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	startSim(t, hub)
	ts := httptest.NewTLSServer(hub.Handler())
	defer ts.Close()
	conn, err := dial(t, ts, secret, 1)
	if conn != nil {
		closeConnection(t, conn)
	}
	if err == nil || calls.Load() != 1 || hub.Connected() != 0 {
		t.Fatalf("refused claim: dial error=%v calls=%d connected=%d", err, calls.Load(), hub.Connected())
	}
	refuse.Store(false)
	conn, err = dial(t, ts, secret, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, conn)
	message := readMessage(t, conn)
	if len(message.Snapshot.Entities) == 0 || calls.Load() != 2 {
		t.Fatal("accepted claim did not receive a real join snapshot")
	}
}

func TestClaimedHubRefusesUnusableClaimConfiguration(t *testing.T) {
	verifier, err := NewHMACVerifier(testSecret(1), "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	claim := claimFunc(func(context.Context, string, sim.EntityID) error { return nil })
	for _, tc := range []struct {
		name    string
		claim   AdmissionClaimer
		timeout time.Duration
	}{
		{"missing claimant", nil, time.Second},
		{"negative timeout", claim, -time.Second},
		{"unbounded timeout", claim, time.Hour},
	} {
		t.Run(tc.name, func(t *testing.T) {
			if _, err := NewClaimedHub(Config{Verifier: verifier}, tc.claim, tc.timeout); err == nil {
				t.Fatal("unusable claim configuration was accepted")
			}
		})
	}
}

func TestClaimedHubRefusesCanceledExpiredAndRejectedClaims(t *testing.T) {
	for _, scenario := range []string{"rejected", "deadline", "canceled", "expired"} {
		t.Run(scenario, func(t *testing.T) {
			secret := testSecret(1)
			verifier, err := NewHMACVerifier(secret, "allocation-a")
			if err != nil {
				t.Fatal(err)
			}
			now := time.Unix(100, 0)
			verifier.now = func() time.Time { return now }
			token, err := MintToken(secret, "allocation-a", 1, now.Add(time.Second))
			if err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithCancel(context.Background())
			defer cancel()
			claim := claimFunc(func(callCtx context.Context, _ string, _ sim.EntityID) error {
				switch scenario {
				case "rejected":
					return errors.New("private token and locator details")
				case "deadline":
					<-callCtx.Done()
				case "canceled":
					cancel()
				case "expired":
					now = now.Add(time.Second)
				}
				return nil // a late success must not authorize an upgrade
			})
			hub, err := NewClaimedHub(Config{Verifier: verifier}, claim, 5*time.Millisecond)
			if err != nil {
				t.Fatal(err)
			}
			request := httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil).WithContext(ctx)
			request.Header.Set("Authorization", "Bearer "+token)
			validHandshake(request)
			response := httptest.NewRecorder()
			hub.Handler().ServeHTTP(response, request)
			if response.Code != http.StatusUnauthorized || response.Body.String() != "admission refused\n" {
				t.Fatalf("response=%d %q, want generic admission refusal", response.Code, response.Body.String())
			}
			if hub.Connected() != 0 {
				t.Fatal("refused peer attached to simulation")
			}
		})
	}
}

func validHandshake(r *http.Request) {
	r.Header.Set("Connection", "Upgrade")
	r.Header.Set("Upgrade", "websocket")
	r.Header.Set("Sec-WebSocket-Version", "13")
	r.Header.Set("Sec-WebSocket-Key", "AAAAAAAAAAAAAAAAAAAAAA==")
}

func TestClaimedHubDoesNotConsumeClaimOnInvalidHandshake(t *testing.T) {
	secret := testSecret(1)
	verifier, err := NewHMACVerifier(secret, "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	token, err := MintToken(secret, "allocation-a", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	hub, err := NewClaimedHub(Config{Verifier: verifier}, claimFunc(func(context.Context, string, sim.EntityID) error {
		calls++
		return errors.New("backend reached")
	}), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	for _, mutate := range []func(*http.Request){
		func(r *http.Request) { r.Method = http.MethodPost },
		func(r *http.Request) { r.Header.Del("Connection") },
		func(r *http.Request) { r.Header.Del("Upgrade") },
		func(r *http.Request) { r.Header.Set("Sec-WebSocket-Version", "12") },
		func(r *http.Request) { r.Header.Set("Sec-WebSocket-Key", "invalid") },
		func(r *http.Request) { r.Header.Add("Sec-WebSocket-Key", "AAAAAAAAAAAAAAAAAAAAAA==") },
		func(r *http.Request) { r.Header.Set("Origin", "https://sibling.invalid") },
		func(r *http.Request) { r.ProtoMajor, r.ProtoMinor = 1, 0 },
	} {
		r := httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil)
		r.Header.Set("Authorization", "Bearer "+token)
		validHandshake(r)
		mutate(r)
		response := httptest.NewRecorder()
		hub.Handler().ServeHTTP(response, r)
		if response.Code < 400 {
			t.Fatal("invalid handshake accepted")
		}
	}
	if calls != 0 {
		t.Fatalf("invalid handshakes consumed %d claims", calls)
	}
}

func TestClaimedHubDoesNotCallBackendForInvalidAdmission(t *testing.T) {
	secret := testSecret(1)
	verifier, err := NewHMACVerifier(secret, "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	token, err := MintToken(secret, "allocation-a", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	calls := 0
	hub, err := NewClaimedHub(Config{Verifier: verifier}, claimFunc(func(context.Context, string, sim.EntityID) error {
		calls++
		return nil
	}), 0)
	if err != nil {
		t.Fatal(err)
	}
	for _, tc := range []struct{ authorization, version string }{
		{"", ""}, {"Bearer forged", ""}, {"Bearer " + token, "999"},
	} {
		request := httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil)
		request.Header.Set("Authorization", tc.authorization)
		request.Header.Set(WireVersionHeader, tc.version)
		hub.Handler().ServeHTTP(httptest.NewRecorder(), request)
	}
	if calls != 0 {
		t.Fatal("invalid local admission reached private claim backend")
	}
}
