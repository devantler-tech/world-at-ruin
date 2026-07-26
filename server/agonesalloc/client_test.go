package agonesalloc

import (
	"context"
	"net"
	"strings"
	"sync"
	"testing"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	"google.golang.org/protobuf/proto"
)

const (
	testNamespace     = "world-at-ruin"
	testFleet         = "zone"
	testTLSPortName   = "tls"
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
)

type allocationServer struct {
	allocationpb.UnimplementedAllocationServiceServer

	mu       sync.Mutex
	requests []*allocationpb.AllocationRequest
	response *allocationpb.AllocationResponse
	err      error
}

type unusedAllocationClient struct{}

func (unusedAllocationClient) Allocate(
	context.Context,
	*allocationpb.AllocationRequest,
	...grpc.CallOption,
) (*allocationpb.AllocationResponse, error) {
	panic("unused allocation client was called")
}

func (s *allocationServer) Allocate(
	_ context.Context,
	request *allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.requests = append(
		s.requests,
		proto.Clone(request).(*allocationpb.AllocationRequest),
	)
	return s.response, s.err
}

func (s *allocationServer) observedRequests() []*allocationpb.AllocationRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	requests := make([]*allocationpb.AllocationRequest, len(s.requests))
	for i, request := range s.requests {
		requests[i] = proto.Clone(request).(*allocationpb.AllocationRequest)
	}
	return requests
}

func clientAgainst(
	t *testing.T,
	server *allocationServer,
	cfg Config,
) *Client {
	t.Helper()

	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	allocationpb.RegisterAllocationServiceServer(grpcServer, server)
	go func() {
		_ = grpcServer.Serve(listener)
	}()
	t.Cleanup(grpcServer.Stop)
	t.Cleanup(func() {
		_ = listener.Close()
	})

	conn, err := grpc.NewClient(
		"passthrough:///agones-allocation-test",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
	)
	if err != nil {
		t.Fatalf("create Agones allocation test client: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
	})

	client, err := NewClient(allocationpb.NewAllocationServiceClient(conn), cfg)
	if err != nil {
		t.Fatalf("NewClient returned an error: %v", err)
	}
	return client
}

func validConfig() Config {
	return Config{
		Namespace:   testNamespace,
		Fleet:       testFleet,
		TLSPortName: testTLSPortName,
	}
}

func validRequest() Request {
	return Request{
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
	}
}

func TestNewClientRequiresAllocationAPI(t *testing.T) {
	client, err := NewClient(nil, validConfig())
	if err == nil {
		t.Fatalf("NewClient(nil) = %+v, nil error; want refusal", client)
	}
	if client != nil {
		t.Fatalf("NewClient(nil) client = %+v, want nil", client)
	}
}

func TestNewClientRejectsInvalidConfigurationBeforeRPC(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*Config)
	}{
		{
			name: "empty namespace",
			mutate: func(cfg *Config) {
				cfg.Namespace = ""
			},
		},
		{
			name: "namespace is not a DNS label",
			mutate: func(cfg *Config) {
				cfg.Namespace = "World-At-Ruin"
			},
		},
		{
			name: "fleet is not a DNS subdomain",
			mutate: func(cfg *Config) {
				cfg.Fleet = "zone/fleet"
			},
		},
		{
			name: "fleet cannot fit its selector label",
			mutate: func(cfg *Config) {
				cfg.Fleet = strings.Repeat("f", 32) + "." + strings.Repeat("g", 31)
			},
		},
		{
			name: "TLS port name is not a DNS label",
			mutate: func(cfg *Config) {
				cfg.TLSPortName = "zone.tls"
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := validConfig()
			test.mutate(&cfg)

			client, err := NewClient(unusedAllocationClient{}, cfg)
			if err == nil {
				t.Fatalf("NewClient(%+v) = %+v, nil error; want refusal", cfg, client)
			}
			if client != nil {
				t.Fatalf("NewClient(%+v) client = %+v, want nil", cfg, client)
			}
		})
	}
}

func TestReserveRejectsInvalidCorrelationBeforeRPC(t *testing.T) {
	tests := []struct {
		name    string
		request Request
	}{
		{
			name: "empty reservation",
			request: Request{
				AttemptID: testAttemptID,
			},
		},
		{
			name: "header-unsafe reservation",
			request: Request{
				ReservationID: testReservationID + "\r\nX-Injected: yes",
				AttemptID:     testAttemptID,
			},
		},
		{
			name: "oversized reservation",
			request: Request{
				ReservationID: strings.Repeat("r", 129),
				AttemptID:     testAttemptID,
			},
		},
		{
			name: "empty attempt",
			request: Request{
				ReservationID: testReservationID,
			},
		},
		{
			name: "separator-unsafe attempt",
			request: Request{
				ReservationID: testReservationID,
				AttemptID:     "attempt/7",
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &allocationServer{
				response: &allocationpb.AllocationResponse{
					GameServerName: "zone-17",
					Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
						{Name: testTLSPortName, Port: 8443},
					},
				},
			}
			client := clientAgainst(t, server, validConfig())

			got, err := client.Reserve(context.Background(), test.request)
			if err == nil {
				t.Fatalf("Reserve(%+v) = %+v, nil error; want refusal", test.request, got)
			}
			if got != (GameServer{}) {
				t.Fatalf("Reserve(%+v) GameServer = %+v, want zero value", test.request, got)
			}
			if requests := server.observedRequests(); len(requests) != 0 {
				t.Fatalf("allocation requests = %v, want none", requests)
			}
		})
	}
}

func TestReserveUsesReadyFleetThroughRealAgonesAPI(t *testing.T) {
	server := &allocationServer{
		response: &allocationpb.AllocationResponse{
			GameServerName: "zone-17",
			Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
				{Name: testTLSPortName, Port: 8443},
			},
			Address:  "10.0.0.17",
			NodeName: "worker-3",
			Source:   "local",
			Metadata: &allocationpb.AllocationResponse_GameServerMetadata{
				Labels: map[string]string{"agones.dev/fleet": testFleet},
			},
		},
	}
	client := clientAgainst(t, server, validConfig())

	got, err := client.Reserve(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("Reserve returned an error: %v", err)
	}
	if got != (GameServer{Name: "zone-17", Port: 8443}) {
		t.Fatalf("reserved GameServer = %+v, want zone-17 on TLS port 8443", got)
	}

	requests := server.observedRequests()
	if len(requests) != 1 {
		t.Fatalf("allocation requests = %d, want 1", len(requests))
	}
	wantRequest := &allocationpb.AllocationRequest{
		Namespace:  testNamespace,
		Scheduling: allocationpb.AllocationRequest_Packed,
		Metadata: &allocationpb.MetaPatch{
			Labels: map[string]string{
				reservationLabel: "4nkzsaqcjve54ayj3qmalp3t2qg52lrquqkkgv3r4quo2ksm3tfq",
				attemptLabel:     "tacnzegdot6y5a6jxfnhkyi7tpwg4ddozxf62uyz2zereccbouqq",
			},
		},
		GameServerSelectors: []*allocationpb.GameServerSelector{
			{
				MatchLabels: map[string]string{
					fleetLabel: testFleet,
				},
				GameServerState: allocationpb.GameServerSelector_READY,
			},
		},
	}
	if !proto.Equal(requests[0], wantRequest) {
		t.Fatalf("allocation request = %v, want %v", requests[0], wantRequest)
	}
}

func TestReserveUsesKubernetesSafeCorrelationLabels(t *testing.T) {
	server := &allocationServer{
		response: &allocationpb.AllocationResponse{
			GameServerName: "zone-17",
			Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
				{Name: testTLSPortName, Port: 8443},
			},
		},
	}
	client := clientAgainst(t, server, validConfig())

	request := validRequest()
	request.ReservationID = "reservation-12"
	if _, err := client.Reserve(context.Background(), request); err != nil {
		t.Fatalf("Reserve returned an error: %v", err)
	}

	requests := server.observedRequests()
	if len(requests) != 1 {
		t.Fatalf("allocation requests = %d, want 1", len(requests))
	}
	for name, value := range requests[0].GetMetadata().GetLabels() {
		if !validKubernetesLabelValue(value) {
			t.Errorf("allocation label %q value %q is not Kubernetes-safe", name, value)
		}
	}
}

func TestReserveRefusesMalformedAllocationResponse(t *testing.T) {
	tests := []struct {
		name     string
		response *allocationpb.AllocationResponse
	}{
		{
			name: "missing GameServer name",
			response: &allocationpb.AllocationResponse{
				Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
					{Name: testTLSPortName, Port: 8443},
				},
			},
		},
		{
			name: "missing named TLS port",
			response: &allocationpb.AllocationResponse{
				GameServerName: "zone-17",
				Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
					{Name: "metrics", Port: 9090},
				},
			},
		},
		{
			name: "zero TLS port",
			response: &allocationpb.AllocationResponse{
				GameServerName: "zone-17",
				Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
					{Name: testTLSPortName, Port: 0},
				},
			},
		},
		{
			name: "overflowing TLS port",
			response: &allocationpb.AllocationResponse{
				GameServerName: "zone-17",
				Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
					{Name: testTLSPortName, Port: 65536},
				},
			},
		},
		{
			name: "duplicate TLS ports",
			response: &allocationpb.AllocationResponse{
				GameServerName: "zone-17",
				Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
					{Name: testTLSPortName, Port: 8443},
					{Name: testTLSPortName, Port: 9443},
				},
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			server := &allocationServer{response: test.response}
			client := clientAgainst(t, server, validConfig())

			got, err := client.Reserve(context.Background(), validRequest())
			if err == nil {
				t.Fatalf("Reserve response %+v = %+v, nil error; want refusal", test.response, got)
			}
			if got != (GameServer{}) {
				t.Fatalf("Reserve response %+v GameServer = %+v, want zero value", test.response, got)
			}
		})
	}
}

func validKubernetesLabelValue(value string) bool {
	if value == "" || len(value) > 63 ||
		!isASCIIAlphanumeric(value[0]) ||
		!isASCIIAlphanumeric(value[len(value)-1]) {
		return false
	}
	for _, char := range value {
		if (char < 'a' || char > 'z') &&
			(char < 'A' || char > 'Z') &&
			(char < '0' || char > '9') &&
			char != '-' &&
			char != '_' &&
			char != '.' {
			return false
		}
	}
	return true
}

func isASCIIAlphanumeric(char byte) bool {
	return (char >= 'a' && char <= 'z') ||
		(char >= 'A' && char <= 'Z') ||
		(char >= '0' && char <= '9')
}

func TestReservePreservesStatusWithoutUpstreamText(t *testing.T) {
	server := &allocationServer{
		err: status.Error(
			codes.Unavailable,
			"allocator leaked "+testReservationID+" and "+testAttemptID,
		),
	}
	client := clientAgainst(t, server, validConfig())

	got, err := client.Reserve(context.Background(), validRequest())
	if status.Code(err) != codes.Unavailable {
		t.Fatalf("Reserve status = %s, want Unavailable", status.Code(err))
	}
	if got != (GameServer{}) {
		t.Fatalf("failed Reserve GameServer = %+v, want zero value", got)
	}
	for _, leaked := range []string{
		"allocator leaked",
		testReservationID,
		testAttemptID,
	} {
		if strings.Contains(err.Error(), leaked) {
			t.Fatalf("Reserve error leaked %q: %q", leaked, err)
		}
	}
}
