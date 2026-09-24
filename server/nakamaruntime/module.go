package nakamaruntime

import (
	allocationpb "agones.dev/agones/pkg/allocation/go"
	"context"
	"crypto/rsa"
	"database/sql"
	"encoding/json"
	"errors"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/agonesresources"
	"github.com/devantler-tech/world-at-ruin/server/gameserverapi"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/handoffalloc"
	"github.com/devantler-tech/world-at-ruin/server/nakamaauth"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"io"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

type dependencies struct {
	allocator allocationpb.AllocationServiceClient
	resources gameserverapi.ResourceAPI
	keys      []*rsa.PrivateKey
	close     func()
}
type connector func(config) (dependencies, error)

// Initialize registers the opt-in handoff RPC and its shutdown-owned expiry
// reconciler. Deployment values come only from Nakama's runtime.env context.
func Initialize(ctx context.Context, nk runtime.NakamaModule, initializer runtime.Initializer) error {
	return initialize(ctx, nk, initializer, connectRuntime)
}

func initialize(ctx context.Context, nk runtime.NakamaModule, initializer runtime.Initializer, connect connector) error {
	env, _ := ctx.Value(runtime.RUNTIME_CTX_ENV).(map[string]string)
	cfg, err := readConfig(env)
	if err != nil || !cfg.enabled {
		return err
	}
	if nk == nil || initializer == nil {
		return errors.New("nakama handoff: runtime dependencies required")
	}
	deps, err := connect(cfg)
	if err != nil {
		return errors.New("nakama handoff: connect dependencies")
	}
	var closeOnce sync.Once
	closeDependencies := func() {
		closeOnce.Do(func() {
			if deps.close != nil {
				deps.close()
			}
		})
	}
	service, coordinator, err := compose(cfg, nk, deps)
	if err != nil {
		closeDependencies()
		return errors.New("nakama handoff: compose dependencies")
	}
	// InitModule's context covers initialization, not the module lifetime. The
	// registered shutdown hook exclusively owns this detached lifecycle.
	life, cancel := context.WithCancel(context.WithoutCancel(ctx))
	done := make(chan struct{})
	handlers := &handlerGate{}
	if err := initializer.RegisterRpc("war_handoff", rpcHandler(life, handlers, service, cfg.rpcTimeout)); err != nil {
		cancel()
		closeDependencies()
		return errors.New("nakama handoff: register RPC")
	}
	if err := initializer.RegisterShutdown(func(shutdownCtx context.Context, _ runtime.Logger, _ *sql.DB, _ runtime.NakamaModule) {
		drain(shutdownCtx, cancel, handlers, done)
		closeDependencies()
	}); err != nil {
		cancel()
		closeDependencies()
		return errors.New("nakama handoff: register shutdown")
	}
	go func() {
		defer close(done)
		_ = coordinator.RunExpiryReconciler(life) // Returns only on lifecycle cancellation.
	}()
	return nil
}

func compose(cfg config, nk runtime.NakamaModule, deps dependencies) (*handoff.Service, *handoffalloc.Coordinator, error) {
	keyring, err := admissionref.NewKeyring(deps.keys...)
	if err != nil {
		return nil, nil, err
	}
	fingerprint, err := admissionref.Fingerprint(&deps.keys[0].PublicKey)
	if err != nil {
		return nil, nil, err
	}
	allocator, err := agonesalloc.NewClient(deps.allocator, agonesalloc.Config{Namespace: cfg.namespace, Fleet: cfg.fleet, TLSPortName: cfg.tlsPort, WrappingKeyFingerprint: fingerprint})
	if err != nil {
		return nil, nil, err
	}
	resources, err := gameserverapi.NewClient(deps.resources, gameserverapi.Config{Namespace: cfg.namespace, Fleet: cfg.fleet, TLSPortName: cfg.tlsPort})
	if err != nil {
		return nil, nil, err
	}
	adapter, err := agonesresources.NewAdapter(allocator, resources, keyring, agonesresources.Config{
		ZoneDomain: cfg.zoneDomain,
		// The current zone allocates one whole GameServer per player and boots
		// NewDemoWorld, whose first entity exists before the hub accepts tokens.
		// Never derive an arbitrary entity ID from the user or reservation.
		Observer: func(handoff.AllocationRequest) (sim.EntityID, error) { return 1, nil },
	})
	if err != nil {
		return nil, nil, err
	}
	leases, err := nakamalease.NewStore(nk)
	if err != nil {
		return nil, nil, err
	}
	coordinator, err := handoffalloc.NewCoordinator(adapter, leases, handoffalloc.Config{LeaseTTL: cfg.leaseTTL})
	if err != nil {
		return nil, nil, err
	}
	service, err := handoff.NewService(nakamaauth.NewRuntimeVerifier(nk), coordinator, handoff.Config{ZoneDomain: cfg.zoneDomain})
	return service, coordinator, err
}

// handlerGate admits RPC handlers until shutdown closes it, then reports when
// every admitted handler has returned. Coordinator paths finish fence-and-
// cleanup under a detached bounded context after caller cancellation, so the
// shutdown hook must not close dependencies while a handler is still running.
type handlerGate struct {
	mu     sync.Mutex
	closed bool
	active sync.WaitGroup
}

func (g *handlerGate) enter() bool {
	g.mu.Lock()
	defer g.mu.Unlock()
	if g.closed {
		return false
	}
	g.active.Add(1)
	return true
}

func (g *handlerGate) leave() { g.active.Done() }

// close refuses new handlers and returns a channel closed once every admitted
// handler has left.
func (g *handlerGate) close() <-chan struct{} {
	g.mu.Lock()
	g.closed = true
	g.mu.Unlock()
	idle := make(chan struct{})
	go func() {
		g.active.Wait()
		close(idle)
	}()
	return idle
}

// drain stops the module lifecycle, then waits within shutdownCtx for the
// expiry reconciler and every in-flight handler before dependencies close.
func drain(shutdownCtx context.Context, cancel context.CancelFunc, handlers *handlerGate, reconciler <-chan struct{}) {
	idle := handlers.close()
	cancel()
	for _, finished := range []<-chan struct{}{reconciler, idle} {
		select {
		case <-finished:
		case <-shutdownCtx.Done():
			return
		}
	}
}

func rpcHandler(life context.Context, handlers *handlerGate, service *handoff.Service, timeout time.Duration) func(context.Context, runtime.Logger, *sql.DB, runtime.NakamaModule, string) (string, error) {
	return func(ctx context.Context, _ runtime.Logger, _ *sql.DB, _ runtime.NakamaModule, payload string) (string, error) {
		if life.Err() != nil || !handlers.enter() {
			return "", rpcError(status.Error(codes.Unavailable, "module stopped"))
		}
		defer handlers.leave()
		if err := emptyRequest(payload); err != nil {
			return "", rpcError(status.Error(codes.InvalidArgument, "invalid request"))
		}
		deadline := time.Now().Add(timeout)
		if expiry, ok := ctx.Value(runtime.RUNTIME_CTX_USER_SESSION_EXP).(int64); ok && time.Unix(expiry, 0).Before(deadline) {
			if expiry <= time.Now().Unix() {
				return "", rpcError(status.Error(codes.Unauthenticated, "session expired"))
			}
			deadline = time.Unix(expiry, 0)
		}
		callCtx, cancel := context.WithDeadline(ctx, deadline)
		defer cancel()
		stop := context.AfterFunc(life, cancel)
		defer stop()
		result, err := service.CreateHandoff(callCtx, handoff.Request{ReservationID: playerReservation})
		if err := callCtx.Err(); err != nil {
			return "", rpcError(err)
		}
		if err != nil {
			return "", rpcError(err)
		}
		encoded, err := json.Marshal(result)
		if err != nil {
			return "", rpcError(status.Error(codes.Internal, "encode response"))
		}
		return string(encoded), nil
	}
}

// playerReservation is the server-owned reservation key for every RPC. Leases
// are keyed by (user, reservation), so a single key per player bounds each
// account to one live attempt: retries replay or adopt it, a claimed zone
// refuses a second one, and only an expired attempt is replaced. A
// client-chosen key would let one account reserve every Ready GameServer.
const playerReservation = "zone"

// Accept exactly an empty JSON object. Any member is refused, so the payload
// cannot choose a reservation, user, session, observer, endpoint or key.
func emptyRequest(payload string) error {
	invalid := errors.New("nakama handoff: invalid request")
	if len(payload) > 4096 || !utf8.ValidString(payload) {
		return invalid
	}
	decoder := json.NewDecoder(strings.NewReader(payload))
	start, err := decoder.Token()
	if err != nil || start != json.Delim('{') {
		return invalid
	}
	end, err := decoder.Token()
	if err != nil || end != json.Delim('}') {
		return invalid
	}
	if _, err := decoder.Token(); !errors.Is(err, io.EOF) {
		return invalid
	}
	return nil
}

func rpcError(err error) error {
	code := status.Code(err)
	if errors.Is(err, context.Canceled) {
		code = codes.Canceled
	}
	if errors.Is(err, context.DeadlineExceeded) {
		code = codes.DeadlineExceeded
	}
	return runtime.NewError("zone handoff unavailable", int(code))
}
