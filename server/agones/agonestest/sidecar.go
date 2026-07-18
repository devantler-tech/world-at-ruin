// Package agonestest provides an in-process fake Agones sidecar for tests,
// in the spirit of net/http/httptest: real gRPC on a loopback port, driven
// by the real SDK client, with counters a test can assert against. Nothing
// in it runs in production.
package agonestest

import (
	"context"
	"net"
	"strconv"
	"sync"

	sdkproto "agones.dev/agones/pkg/sdk"
	"google.golang.org/grpc"
)

// Sidecar is a fake Agones SDK server. It records how the lifecycle drove
// it; tests read the counters through the mutex-guarded accessors.
type Sidecar struct {
	sdkproto.UnimplementedSDKServer

	mu       sync.Mutex
	ready    int
	health   int
	shutdown int
	readyErr error

	// Port the fake listens on (loopback only).
	Port int
	srv  *grpc.Server
}

// Start launches the fake on an ephemeral loopback port. Stop it with Stop
// (test cleanup); a caller then points the real SDK at it via the
// AGONES_SDK_GRPC_HOST/PORT environment variables.
func Start(readyErr error) (*Sidecar, error) {
	lis, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		return nil, err
	}
	f := &Sidecar{
		readyErr: readyErr,
		Port:     lis.Addr().(*net.TCPAddr).Port,
		srv:      grpc.NewServer(),
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

// Shutdown records the call.
func (f *Sidecar) Shutdown(_ context.Context, _ *sdkproto.Empty) (*sdkproto.Empty, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.shutdown++
	return &sdkproto.Empty{}, nil
}

// Health counts every beat the client streams until the stream ends.
func (f *Sidecar) Health(stream sdkproto.SDK_HealthServer) error {
	for {
		if _, err := stream.Recv(); err != nil {
			return stream.SendAndClose(&sdkproto.Empty{})
		}
		f.mu.Lock()
		f.health++
		f.mu.Unlock()
	}
}

// ReadyCalls returns how many Ready RPCs arrived.
func (f *Sidecar) ReadyCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.ready }

// HealthBeats returns how many health pings arrived.
func (f *Sidecar) HealthBeats() int { f.mu.Lock(); defer f.mu.Unlock(); return f.health }

// ShutdownCalls returns how many Shutdown RPCs arrived.
func (f *Sidecar) ShutdownCalls() int { f.mu.Lock(); defer f.mu.Unlock(); return f.shutdown }
