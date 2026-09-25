package zonesock

import (
	"context"
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/sim"
)

// TestShutdownClosesHijackedSockets reproduces the zone command's assumption
// that HTTP server Close drains WebSockets, then requires the hub to own it.
func TestShutdownClosesHijackedSockets(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	served := make(chan struct{}, 1)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hub.Handler().ServeHTTP(w, r)
		served <- struct{}{}
	}))
	defer server.Close()
	client, err := dial(t, server, secret, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, client)
	<-served
	world := sim.NewDemoWorld()
	hub.Tick(world)
	readMessage(t, client)
	server.Close()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Shutdown(ctx, world); err != nil {
		t.Fatal(err)
	}
	if hub.Connected() != 0 {
		t.Error("shutdown retained an attached observer")
	}
	if world.Get(1).InterestRadius != 0 {
		t.Error("shutdown retained observer interest")
	}
	_, _, err = client.Read(ctx)
	if err == nil || errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("upgraded socket survived shutdown: %v", err)
	}
}

// TestShutdownDeadlineNeverReportsAnUndrainedClaim demonstrates that even a
// backend ignoring cancellation cannot be mistaken for completed shutdown.
func TestShutdownDeadlineNeverReportsAnUndrainedClaim(t *testing.T) {
	entered, release := make(chan struct{}), make(chan struct{})
	verifier, err := NewHMACVerifier(testSecret(1), "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	hub, err := NewClaimedHub(Config{Verifier: verifier}, claimFunc(func(context.Context, string, sim.EntityID) error {
		close(entered)
		<-release
		return nil
	}), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil)
	token, err := MintToken(testSecret(1), "allocation-a", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	validHandshake(request)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { defer close(done); hub.Handler().ServeHTTP(response, request) }()
	<-entered
	world := sim.NewDemoWorld()
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Millisecond)
	err = hub.Shutdown(ctx, world)
	cancel()
	close(release)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Errorf("unsettled claim reported shutdown success: %v", err)
	}
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Shutdown(ctx, world); err != nil {
		t.Fatal(err)
	}
	<-done
	if response.Code == http.StatusSwitchingProtocols || hub.Connected() != 0 {
		t.Fatal("late claim restored admission")
	}
}

// TestShutdownRejectsPendingAndFutureAdmission makes a late pending attachment
// cross the shutdown boundary and verifies it cannot restore observer ownership.
func TestShutdownRejectsPendingAndFutureAdmission(t *testing.T) {
	hub, secret := newTestHub(t, Config{})
	served := make(chan struct{}, 2)
	server := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { hub.Handler().ServeHTTP(w, r); served <- struct{}{} }))
	defer server.Close()
	client, err := dial(t, server, secret, 1)
	if err != nil {
		t.Fatal(err)
	}
	defer closeConnection(t, client)
	<-served
	world := sim.NewDemoWorld()
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Shutdown(ctx, world); err != nil {
		t.Fatal(err)
	}
	hub.Tick(world)
	if hub.Connected() != 0 {
		t.Error("pending attachment reopened a terminated hub")
	}
	if err := hub.Shutdown(ctx, world); err != nil {
		t.Fatal(err)
	}
	next, err := dial(t, server, secret, 1)
	if next != nil {
		closeConnection(t, next)
	}
	if err == nil {
		t.Fatal("terminated hub admitted a new socket")
	}
}

// TestShutdownCancelsClaimAndRejectsLateSuccess retains ambiguous durable
// ownership while proving that no late private response can authorize a socket.
func TestShutdownCancelsClaimAndRejectsLateSuccess(t *testing.T) {
	entered, exited := make(chan struct{}), make(chan struct{})
	verifier, err := NewHMACVerifier(testSecret(1), "allocation-a")
	if err != nil {
		t.Fatal(err)
	}
	hub, err := NewClaimedHub(Config{Verifier: verifier}, claimFunc(func(ctx context.Context, _ string, _ sim.EntityID) error {
		close(entered)
		<-ctx.Done()
		close(exited)
		return nil
	}), time.Second)
	if err != nil {
		t.Fatal(err)
	}
	request := httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil)
	token, err := MintToken(testSecret(1), "allocation-a", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	request.Header.Set("Authorization", "Bearer "+token)
	validHandshake(request)
	response := httptest.NewRecorder()
	done := make(chan struct{})
	go func() { defer close(done); hub.Handler().ServeHTTP(response, request) }()
	<-entered
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Shutdown(ctx, sim.NewDemoWorld()); err != nil {
		t.Fatal(err)
	}
	select {
	case <-exited:
	default:
		t.Error("shutdown returned before canceling and draining the claim")
	}
	<-done
	if response.Code == http.StatusSwitchingProtocols || hub.Connected() != 0 {
		t.Fatal("late claim opened a socket")
	}
}

// TestCanceledShutdownStillFencesAdmission prevents a canceled process context
// from skipping the permanent shutdown transition and leaving new work enabled.
func TestCanceledShutdownStillFencesAdmission(t *testing.T) {
	hub, _ := newTestHub(t, Config{})
	world := sim.NewDemoWorld()
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	if err := hub.Shutdown(ctx, world); !errors.Is(err, context.Canceled) {
		t.Fatalf("canceled drain result: %v", err)
	}
	response := httptest.NewRecorder()
	hub.Handler().ServeHTTP(response, httptest.NewRequest(http.MethodGet, "https://zone.invalid/zone", nil))
	if response.Code != http.StatusServiceUnavailable {
		t.Fatal("canceled shutdown left admission open")
	}
	ctx, cancel = context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	if err := hub.Shutdown(ctx, world); err != nil {
		t.Fatal(err)
	}
}
