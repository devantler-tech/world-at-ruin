// Package agonestest provides an in-process fake Agones sidecar for tests,
// in the spirit of net/http/httptest: real gRPC on a loopback port, driven
// by the real SDK client, with counters a test can assert against. Nothing
// in it runs in production.
package agonestest

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"sync"

	sdkproto "agones.dev/agones/pkg/sdk"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	"google.golang.org/protobuf/proto"
)

const sdkMetadataPrefix = "agones.dev/sdk-"

// Sidecar is a fake Agones SDK server. It records how the lifecycle drove
// it; tests read the counters through the mutex-guarded accessors.
type Sidecar struct {
	sdkproto.UnimplementedSDKServer

	mu            sync.Mutex
	ready         int
	health        int
	shutdown      int
	readyErr      error
	killStreamAt  int
	killed        bool
	gameServer    *sdkproto.GameServer
	watchers      map[int]chan *sdkproto.GameServer
	nextWatcher   int
	holdWatches   bool
	watchCalls    int
	annotationErr error
	labelErr      error
	watchEnd      chan struct{}

	// Port the fake listens on (loopback only).
	Port int
	srv  *grpc.Server
}

// Start launches the fake on an ephemeral loopback port. Stop it with Stop
// (test cleanup); a caller then points the real SDK at it via the
// AGONES_SDK_GRPC_HOST/PORT environment variables.
func Start(readyErr error) (*Sidecar, error) {
	lis, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	tcpAddr, ok := lis.Addr().(*net.TCPAddr)
	if !ok {
		_ = lis.Close()
		return nil, fmt.Errorf("agonestest: loopback listener has unexpected address type %T", lis.Addr())
	}
	f := &Sidecar{
		readyErr: readyErr,
		Port:     tcpAddr.Port,
		srv:      grpc.NewServer(),
		watchers: make(map[int]chan *sdkproto.GameServer),
		watchEnd: make(chan struct{}),
	}
	sdkproto.RegisterSDKServer(f.srv, f)
	go func() { _ = f.srv.Serve(lis) }()
	return f, nil
}

// Stop tears the fake down and closes its listener.
func (f *Sidecar) Stop() { f.srv.Stop() }

// PortString is Port as the string AGONES_SDK_GRPC_PORT expects.
func (f *Sidecar) PortString() string { return strconv.Itoa(f.Port) }

// Ready records the call and returns the configured error, if any.
func (f *Sidecar) Ready(_ context.Context, _ *sdkproto.Empty) (*sdkproto.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.ready++
	if f.readyErr != nil {
		return nil, f.readyErr
	}
	return &sdkproto.Empty{}, nil
}

// SetGameServer supplies the identity and lifecycle state returned by the real
// SDK's GameServer and WatchGameServer calls.
func (f *Sidecar) SetGameServer(namespace, name, uid, state string) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gameServer = &sdkproto.GameServer{
		ObjectMeta: &sdkproto.GameServer_ObjectMeta{
			Namespace:   namespace,
			Name:        name,
			Uid:         uid,
			Annotations: make(map[string]string),
			Labels:      make(map[string]string),
		},
		Status: &sdkproto.GameServer_Status{State: state},
	}
	f.broadcastLocked()
}

// PublishGameServer delivers a complete independent API snapshot to SDK watches.
func (f *Sidecar) PublishGameServer(gs *sdkproto.GameServer) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gameServer = proto.CloneOf(gs)
	f.broadcastLocked()
}

// EndWatchStreams terminates watches without interrupting the health stream.
func (f *Sidecar) EndWatchStreams() {
	f.mu.Lock()
	defer f.mu.Unlock()
	close(f.watchEnd)
	f.watchEnd = make(chan struct{})
}

// HoldWatchEvents prevents WatchGameServer from yielding snapshots until
// ReleaseWatchEvents. It lets tests prove callers really wait for the
// observed metadata barrier rather than trusting SetAnnotation/SetLabel.
func (f *Sidecar) HoldWatchEvents() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.holdWatches = true
}

// ReleaseWatchEvents publishes the current GameServer to every active watcher.
func (f *Sidecar) ReleaseWatchEvents() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.holdWatches = false
	f.broadcastLocked()
}

// GetGameServer returns the configured GameServer snapshot.
func (f *Sidecar) GetGameServer(_ context.Context, _ *sdkproto.Empty) (*sdkproto.GameServer, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gameServer == nil {
		return nil, status.Error(codes.NotFound, "agonestest: GameServer is not configured")
	}
	return proto.CloneOf(f.gameServer), nil
}

// SetAnnotation applies the same metadata prefix as the real Agones sidecar.
func (f *Sidecar) SetAnnotation(_ context.Context, kv *sdkproto.KeyValue) (*sdkproto.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.annotationErr != nil {
		return nil, f.annotationErr
	}
	if f.gameServer == nil {
		return nil, status.Error(codes.NotFound, "agonestest: GameServer is not configured")
	}
	f.gameServer.GetObjectMeta().Annotations[sdkMetadataPrefix+kv.GetKey()] = kv.GetValue()
	f.broadcastLocked()
	return &sdkproto.Empty{}, nil
}

// SetLabel applies the same metadata prefix as the real Agones sidecar.
func (f *Sidecar) SetLabel(_ context.Context, kv *sdkproto.KeyValue) (*sdkproto.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.labelErr != nil {
		return nil, f.labelErr
	}
	if f.gameServer == nil {
		return nil, status.Error(codes.NotFound, "agonestest: GameServer is not configured")
	}
	f.gameServer.GetObjectMeta().Labels[sdkMetadataPrefix+kv.GetKey()] = kv.GetValue()
	f.broadcastLocked()
	return &sdkproto.Empty{}, nil
}

// WatchGameServer streams the current resource and every later metadata
// update, matching the sidecar contract exercised by the production SDK.
func (f *Sidecar) WatchGameServer(_ *sdkproto.Empty, stream sdkproto.SDK_WatchGameServerServer) error {
	f.mu.Lock()
	id := f.nextWatcher
	f.nextWatcher++
	f.watchCalls++
	ch := make(chan *sdkproto.GameServer, 8)
	f.watchers[id] = ch
	watchEnd := f.watchEnd
	if !f.holdWatches && f.gameServer != nil {
		ch <- proto.CloneOf(f.gameServer)
	}
	f.mu.Unlock()
	defer func() {
		f.mu.Lock()
		delete(f.watchers, id)
		f.mu.Unlock()
	}()

	for {
		select {
		case <-watchEnd:
			return nil
		case <-stream.Context().Done():
			return stream.Context().Err()
		case gs := <-ch:
			if err := stream.Send(gs); err != nil {
				return err
			}
		}
	}
}

func (f *Sidecar) broadcastLocked() {
	if f.holdWatches || f.gameServer == nil {
		return
	}
	for _, ch := range f.watchers {
		ch <- proto.CloneOf(f.gameServer)
	}
}

// Shutdown records the call.
func (f *Sidecar) Shutdown(_ context.Context, _ *sdkproto.Empty) (*sdkproto.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shutdown++
	return &sdkproto.Empty{}, nil
}

// KillHealthStreamAt makes the fake terminate the health stream with an
// error once n beats have arrived — the shape of a sidecar restart. It fires
// once; a re-dialled stream counts on undisturbed.
func (f *Sidecar) KillHealthStreamAt(n int) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.killStreamAt = n
}

// Health counts every beat the client streams until the stream ends.
func (f *Sidecar) Health(stream sdkproto.SDK_HealthServer) error {
	for {
		if _, err := stream.Recv(); err != nil {
			return stream.SendAndClose(&sdkproto.Empty{})
		}
		f.mu.Lock()
		f.health++
		kill := !f.killed && f.killStreamAt > 0 && f.health >= f.killStreamAt
		if kill {
			f.killed = true
		}
		f.mu.Unlock()
		if kill {
			return status.Error(codes.Unavailable, "agonestest: health stream killed (simulated sidecar restart)")
		}
	}
}

// ReadyCalls returns how many Ready RPCs arrived.
func (f *Sidecar) ReadyCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.ready }

// HealthBeats returns how many health pings arrived.
func (f *Sidecar) HealthBeats() int { f.mu.Lock(); defer f.mu.Unlock(); return f.health }

// ShutdownCalls returns how many Shutdown RPCs arrived.
func (f *Sidecar) ShutdownCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.shutdown }

// WatchCalls returns how many WatchGameServer streams were opened.
func (f *Sidecar) WatchCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.watchCalls }

// FailSetAnnotation makes metadata publication fail with err.
func (f *Sidecar) FailSetAnnotation(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.annotationErr = err
}

// FailSetLabel makes readiness-label publication fail with err.
func (f *Sidecar) FailSetLabel(err error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.labelErr = err
}

// Annotation returns one fully-qualified GameServer annotation.
func (f *Sidecar) Annotation(key string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gameServer == nil {
		return ""
	}
	return f.gameServer.GetObjectMeta().GetAnnotations()[key]
}

// Label returns one fully-qualified GameServer label.
func (f *Sidecar) Label(key string) string {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.gameServer == nil {
		return ""
	}
	return f.gameServer.GetObjectMeta().GetLabels()[key]
}
