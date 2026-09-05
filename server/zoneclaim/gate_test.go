package zoneclaim

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	sdkproto "agones.dev/agones/pkg/sdk"
	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

type privateClaimFunc func(context.Context, agones.ClaimBinding, string, sim.EntityID) error

func (f privateClaimFunc) Claim(ctx context.Context, binding agones.ClaimBinding, token string, observer sim.EntityID) error {
	return f(ctx, binding, token, observer)
}

func TestObservedClaimGatesRealSocketAndRejectsInFlightBindingChange(t *testing.T) {
	sidecar, err := agonestest.Start(nil)
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(sidecar.Stop)
	t.Setenv("AGONES_SDK_GRPC_HOST", "127.0.0.1")
	t.Setenv("AGONES_SDK_GRPC_PORT", sidecar.PortString())
	sidecar.SetGameServer("games", "zone-17", "uid-17", "Starting")
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	prepared, err := agones.PrepareAdmission(ctx, agones.Config{Logf: t.Logf}, agones.AdmissionConfig{
		WrappingPublicKeyPEM: pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: der}),
	})
	if err != nil {
		t.Fatal(err)
	}
	verifier, err := zonesock.NewHMACVerifier(prepared.Secret(), "zone-17")
	if err != nil {
		t.Fatal(err)
	}
	token, err := zonesock.MintToken(prepared.Secret(), "zone-17", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	var mode atomic.Int32
	entered, release := make(chan struct{}), make(chan struct{})
	backend := privateClaimFunc(func(callCtx context.Context, binding agones.ClaimBinding, received string, observer sim.EntityID) error {
		calls.Add(1)
		if binding.Namespace != "games" || binding.AllocationID != "zone-17" || binding.GameServerUID != "uid-17" ||
			binding.LeaseObjectID != strings.Repeat("0", 64) || received != token || observer != 1 {
			t.Error("private claim did not receive the observed binding and verified token")
		}
		switch mode.Load() {
		case 1:
			return errors.New("private backend refusal")
		case 2:
			close(entered)
			select {
			case <-release:
			case <-callCtx.Done():
				return callCtx.Err()
			}
		}
		return nil
	})
	gate, err := New(prepared, backend)
	if err != nil {
		t.Fatal(err)
	}
	hub, err := zonesock.NewClaimedHub(zonesock.Config{Verifier: verifier}, gate, time.Second)
	if err != nil {
		t.Fatal(err)
	}
	done := make(chan struct{})
	go func() {
		defer close(done)
		world := sim.NewDemoWorld()
		ticker := time.NewTicker(time.Millisecond)
		defer ticker.Stop()
		for {
			select {
			case <-ctx.Done():
				return
			case <-ticker.C:
				hub.Tick(world)
			}
		}
	}()
	t.Cleanup(func() { cancel(); <-done })
	server := httptest.NewTLSServer(hub.Handler())
	t.Cleanup(server.Close)
	dial := func() (*websocket.Conn, *http.Response, error) {
		dialCtx, stop := context.WithTimeout(ctx, 5*time.Second)
		defer stop()
		return websocket.Dial(dialCtx, server.URL, &websocket.DialOptions{
			HTTPClient: server.Client(), HTTPHeader: http.Header{"Authorization": {"Bearer " + token}},
		})
	}
	refused := func() {
		t.Helper()
		conn, response, err := dial()
		if conn != nil {
			_ = conn.CloseNow()
		}
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		if err == nil || response == nil || response.StatusCode != http.StatusUnauthorized {
			t.Fatal("claim refusal created a socket or exposed a non-generic failure")
		}
	}
	refused()
	if calls.Load() != 0 {
		t.Fatal("missing allocated locator reached backend")
	}
	gs, err := sidecar.GetGameServer(ctx, &sdkproto.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	gs.Status.State = "Allocated"
	gs.ObjectMeta.Labels[agones.AttemptLabel] = strings.Repeat("a", 52)
	gs.ObjectMeta.Annotations[agones.ClaimLocatorAnnotation] = "v1." + strings.Repeat("0", 64) + "." + strings.Repeat("a", 52)
	sidecar.PublishGameServer(gs)
	waitFor(t, func() bool { _, err := prepared.ClaimBinding(); return err == nil })
	mode.Store(1)
	refused()
	mode.Store(0)
	conn, response, err := dial()
	if response != nil && response.Body != nil {
		_ = response.Body.Close()
	}
	if err != nil {
		t.Fatal(err)
	}
	readCtx, stopRead := context.WithTimeout(ctx, time.Second)
	_, data, err := conn.Read(readCtx)
	stopRead()
	_ = conn.CloseNow()
	if err != nil {
		t.Fatal(err)
	}
	message, err := wire.Decode(data)
	if err != nil || message.Snapshot.Observer != 1 {
		t.Fatal("accepted durable claim did not receive the actual join snapshot")
	}
	waitFor(t, func() bool { return hub.Connected() == 0 })
	mode.Store(2)
	dialResult := make(chan error, 1)
	go func() {
		connection, resp, dialErr := dial()
		if connection != nil {
			_ = connection.CloseNow()
		}
		if resp != nil && resp.Body != nil {
			_ = resp.Body.Close()
		}
		dialResult <- dialErr
	}()
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("claim was not called")
	}
	gs.Status.State = "Shutdown"
	sidecar.PublishGameServer(gs)
	waitFor(t, func() bool { _, err := prepared.ClaimBinding(); return err != nil })
	close(release)
	if err := <-dialResult; err == nil || hub.Connected() != 0 {
		t.Fatal("late claim success admitted a socket after allocation invalidation")
	}
	if calls.Load() != 3 {
		t.Fatalf("backend calls=%d, want exactly one per observed valid attempt", calls.Load())
	}
}

func TestGateRequiresBothServerBoundaries(t *testing.T) {
	backend := privateClaimFunc(func(context.Context, agones.ClaimBinding, string, sim.EntityID) error { return nil })
	if _, err := New(nil, backend); err == nil {
		t.Fatal("missing binding source accepted")
	}
	if _, err := New(&agones.PreparedAdmission{}, nil); err == nil {
		t.Fatal("missing private claimant accepted")
	}
}

func waitFor(t *testing.T, predicate func() bool) {
	t.Helper()
	deadline := time.Now().Add(5 * time.Second)
	for time.Now().Before(deadline) {
		if predicate() {
			return
		}
		time.Sleep(time.Millisecond)
	}
	t.Fatal("expected observed state did not arrive")
}
