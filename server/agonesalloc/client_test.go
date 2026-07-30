package agonesalloc

import (
	"bytes"
	"context"
	"encoding/base64"
	"net"
	"strings"
	"sync"
	"testing"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/agones"
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
	testAttemptDigest = "tacnzegdot6y5a6jxfnhkyi7tpwg4ddozxf62uyz2zereccbouqq"
)

var (
	testWrappingKeyFingerprint       = strings.Repeat("a", 52)
	testPreviousKeyFingerprint       = "b" + strings.Repeat("a", 51)
	testLeaseObjectID                = strings.Repeat("0", 64)
	testPreviousLeaseObjectID        = strings.Repeat("1", 64)
	testExpectedClaimLocator         = "v1." + testLeaseObjectID + "." + testAttemptDigest
	testPreviousExpectedClaimLocator = "v1." + testPreviousLeaseObjectID + "." + testAttemptDigest
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
	cloned, ok := proto.Clone(request).(*allocationpb.AllocationRequest)
	if !ok {
		panic("cloned allocation request has an unexpected type")
	}
	s.requests = append(s.requests, cloned)
	return s.response, s.err
}

func (s *allocationServer) observedRequests() []*allocationpb.AllocationRequest {
	s.mu.Lock()
	defer s.mu.Unlock()
	requests := make([]*allocationpb.AllocationRequest, len(s.requests))
	for i, request := range s.requests {
		cloned, ok := proto.Clone(request).(*allocationpb.AllocationRequest)
		if !ok {
			panic("cloned allocation request has an unexpected type")
		}
		requests[i] = cloned
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
		Namespace:              testNamespace,
		Fleet:                  testFleet,
		TLSPortName:            testTLSPortName,
		WrappingKeyFingerprint: testWrappingKeyFingerprint,
	}
}

func validRequest() Request {
	return Request{
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		LeaseObjectID: testLeaseObjectID,
	}
}

func testAdmissionEnvelope() string {
	return "v1." + base64.RawURLEncoding.EncodeToString(
		bytes.Repeat([]byte{0x42}, 384),
	)
}

func validAllocationResponse() *allocationpb.AllocationResponse {
	return allocationResponseFor(
		testWrappingKeyFingerprint,
		testExpectedClaimLocator,
	)
}

func allocationResponseFor(
	fingerprint string,
	claimLocator string,
) *allocationpb.AllocationResponse {
	return &allocationpb.AllocationResponse{
		GameServerName: "zone-17",
		Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{
			{Name: testTLSPortName, Port: 8443},
		},
		Address:  "10.0.0.17",
		NodeName: "worker-3",
		Source:   "local",
		Metadata: &allocationpb.AllocationResponse_GameServerMetadata{
			Labels: map[string]string{
				fleetLabel:                 testFleet,
				agones.AdmissionReadyLabel: "v1-" + fingerprint,
			},
			Annotations: map[string]string{
				agones.AdmissionEnvelopeAnnotation: testAdmissionEnvelope(),
				agones.AdmissionKeyAnnotation:      fingerprint,
				agones.ClaimLocatorAnnotation:      claimLocator,
			},
		},
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
		{
			name: "missing wrapping-key fingerprint",
			mutate: func(cfg *Config) {
				cfg.WrappingKeyFingerprint = ""
			},
		},
		{
			name: "non-canonical wrapping-key fingerprint",
			mutate: func(cfg *Config) {
				cfg.WrappingKeyFingerprint = strings.ToUpper(testWrappingKeyFingerprint)
			},
		},
		{
			name: "truncated wrapping-key fingerprint",
			mutate: func(cfg *Config) {
				cfg.WrappingKeyFingerprint = testWrappingKeyFingerprint[:51]
			},
		},
		{
			name: "malformed wrapping-key fingerprint",
			mutate: func(cfg *Config) {
				cfg.WrappingKeyFingerprint = strings.Repeat("!", 52)
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
		name   string
		mutate func(*Request)
	}{
		{
			name: "empty reservation",
			mutate: func(request *Request) {
				request.ReservationID = ""
			},
		},
		{
			name: "header-unsafe reservation",
			mutate: func(request *Request) {
				request.ReservationID = testReservationID + "\r\nX-Injected: yes"
			},
		},
		{
			name: "oversized reservation",
			mutate: func(request *Request) {
				request.ReservationID = strings.Repeat("r", 129)
			},
		},
		{
			name: "empty attempt",
			mutate: func(request *Request) {
				request.AttemptID = ""
			},
		},
		{
			name: "separator-unsafe attempt",
			mutate: func(request *Request) {
				request.AttemptID = "attempt/7"
			},
		},
		{
			name: "empty private lease object ID",
			mutate: func(request *Request) {
				request.LeaseObjectID = ""
			},
		},
		{
			name: "non-canonical private lease object ID",
			mutate: func(request *Request) {
				request.LeaseObjectID = strings.Repeat("A", 64)
			},
		},
		{
			name: "truncated private lease object ID",
			mutate: func(request *Request) {
				request.LeaseObjectID = testLeaseObjectID[:63]
			},
		},
		{
			name: "malformed private lease object ID",
			mutate: func(request *Request) {
				request.LeaseObjectID = strings.Repeat("g", 64)
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			request := validRequest()
			test.mutate(&request)
			server := &allocationServer{response: validAllocationResponse()}
			client := clientAgainst(t, server, validConfig())

			got, err := client.Reserve(context.Background(), request)
			if err == nil {
				t.Fatalf("Reserve(%+v) = %+v, nil error; want refusal", request, got)
			}
			if got != (GameServer{}) {
				t.Fatalf("Reserve(%+v) GameServer = %+v, want zero value", request, got)
			}
			if requests := server.observedRequests(); len(requests) != 0 {
				t.Fatalf("allocation requests = %v, want none", requests)
			}
		})
	}
}

func TestReserveUsesReadyFleetThroughRealAgonesAPI(t *testing.T) {
	server := &allocationServer{response: validAllocationResponse()}
	client := clientAgainst(t, server, validConfig())

	got, err := client.Reserve(context.Background(), validRequest())
	if err != nil {
		t.Fatalf("Reserve returned an error: %v", err)
	}
	wantGameServer := GameServer{
		Name:                   "zone-17",
		Port:                   8443,
		WrappingKeyFingerprint: testWrappingKeyFingerprint,
		AdmissionEnvelope:      testAdmissionEnvelope(),
	}
	if got != wantGameServer {
		t.Fatalf("reserved GameServer = %+v, want %+v", got, wantGameServer)
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
				attemptLabel:     testAttemptDigest,
			},
			Annotations: map[string]string{
				agones.ClaimLocatorAnnotation: testExpectedClaimLocator,
			},
		},
		GameServerSelectors: []*allocationpb.GameServerSelector{
			{
				MatchLabels: map[string]string{
					fleetLabel:                 testFleet,
					agones.AdmissionReadyLabel: "v1-" + testWrappingKeyFingerprint,
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
	server := &allocationServer{response: validAllocationResponse()}
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
	for _, raw := range []string{request.ReservationID, request.AttemptID} {
		for name, value := range requests[0].GetMetadata().GetLabels() {
			if strings.Contains(value, raw) {
				t.Errorf("allocation label %q leaked raw correlation value %q", name, raw)
			}
		}
		for name, value := range requests[0].GetMetadata().GetAnnotations() {
			if strings.Contains(value, raw) {
				t.Errorf("allocation annotation %q leaked raw correlation value %q", name, raw)
			}
		}
	}
}

func TestReserveRefusesMalformedAllocationResponse(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*allocationpb.AllocationResponse)
	}{
		{
			name: "missing GameServer name",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GameServerName = ""
			},
		},
		{
			name: "malformed GameServer name",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GameServerName = "zone_17"
			},
		},
		{
			name: "missing named TLS port",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.Ports[0].Name = "metrics"
			},
		},
		{
			name: "zero TLS port",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.Ports[0].Port = 0
			},
		},
		{
			name: "overflowing TLS port",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.Ports[0].Port = 65536
			},
		},
		{
			name: "duplicate TLS ports",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.Ports = append(
					response.Ports,
					&allocationpb.AllocationResponse_GameServerStatusPort{
						Name: testTLSPortName,
						Port: 9443,
					},
				)
			},
		},
		{
			name: "missing allocation metadata",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.Metadata = nil
			},
		},
		{
			name: "selector-mismatched Fleet",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetLabels()[fleetLabel] = "other-zone"
			},
		},
		{
			name: "missing envelope-ready label",
			mutate: func(response *allocationpb.AllocationResponse) {
				delete(response.GetMetadata().GetLabels(), agones.AdmissionReadyLabel)
			},
		},
		{
			name: "selector-mismatched envelope-ready label",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetLabels()[agones.AdmissionReadyLabel] =
					"v1-" + testPreviousKeyFingerprint
			},
		},
		{
			name: "missing wrapping-key fingerprint",
			mutate: func(response *allocationpb.AllocationResponse) {
				delete(response.GetMetadata().GetAnnotations(), agones.AdmissionKeyAnnotation)
			},
		},
		{
			name: "selector-mismatched wrapping-key fingerprint",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionKeyAnnotation] =
					testPreviousKeyFingerprint
			},
		},
		{
			name: "missing sealed envelope",
			mutate: func(response *allocationpb.AllocationResponse) {
				delete(
					response.GetMetadata().GetAnnotations(),
					agones.AdmissionEnvelopeAnnotation,
				)
			},
		},
		{
			name: "unsupported sealed-envelope version",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] =
					"v2." + strings.TrimPrefix(testAdmissionEnvelope(), "v1.")
			},
		},
		{
			name: "malformed sealed-envelope encoding",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] =
					"v1.***"
			},
		},
		{
			name: "truncated sealed envelope",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] =
					"v1." + base64.RawURLEncoding.EncodeToString(
						bytes.Repeat([]byte{0x42}, 383),
					)
			},
		},
		{
			name: "oversized sealed envelope",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] =
					"v1." + base64.RawURLEncoding.EncodeToString(
						bytes.Repeat([]byte{0x42}, 4097),
					)
			},
		},
		{
			name: "duplicate sealed-envelope payload",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.AdmissionEnvelopeAnnotation] +=
					"." + strings.TrimPrefix(testAdmissionEnvelope(), "v1.")
			},
		},
		{
			name: "missing claim locator",
			mutate: func(response *allocationpb.AllocationResponse) {
				delete(response.GetMetadata().GetAnnotations(), agones.ClaimLocatorAnnotation)
			},
		},
		{
			name: "mismatched claim locator",
			mutate: func(response *allocationpb.AllocationResponse) {
				response.GetMetadata().GetAnnotations()[agones.ClaimLocatorAnnotation] =
					testPreviousExpectedClaimLocator
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response, ok := proto.Clone(validAllocationResponse()).(*allocationpb.AllocationResponse)
			if !ok {
				t.Fatal("cloned allocation response has an unexpected type")
			}
			test.mutate(response)
			server := &allocationServer{response: response}
			client := clientAgainst(t, server, validConfig())

			got, err := client.Reserve(context.Background(), validRequest())
			if err == nil {
				t.Fatalf("Reserve response %+v = %+v, nil error; want refusal", response, got)
			}
			if got != (GameServer{}) {
				t.Fatalf("Reserve response %+v GameServer = %+v, want zero value", response, got)
			}
		})
	}
}

func TestReserveRotatesReadySelectionWithoutLosingAllocatedKeyIdentity(t *testing.T) {
	oldConfig := validConfig()
	oldConfig.WrappingKeyFingerprint = testPreviousKeyFingerprint
	oldRequest := validRequest()
	oldRequest.LeaseObjectID = testPreviousLeaseObjectID
	oldServer := &allocationServer{
		response: allocationResponseFor(
			testPreviousKeyFingerprint,
			testPreviousExpectedClaimLocator,
		),
	}
	oldClient := clientAgainst(t, oldServer, oldConfig)

	allocatedBeforeCutover, err := oldClient.Reserve(context.Background(), oldRequest)
	if err != nil {
		t.Fatalf("Reserve before wrapping-key cutover: %v", err)
	}
	if allocatedBeforeCutover.WrappingKeyFingerprint != testPreviousKeyFingerprint {
		t.Fatalf(
			"pre-cutover allocation key = %q, want retained previous identity %q",
			allocatedBeforeCutover.WrappingKeyFingerprint,
			testPreviousKeyFingerprint,
		)
	}

	newServer := &allocationServer{response: validAllocationResponse()}
	newClient := clientAgainst(t, newServer, validConfig())
	if _, err := newClient.Reserve(context.Background(), validRequest()); err != nil {
		t.Fatalf("Reserve after wrapping-key cutover: %v", err)
	}
	newRequests := newServer.observedRequests()
	if len(newRequests) != 1 {
		t.Fatalf("post-cutover allocation requests = %d, want 1", len(newRequests))
	}
	if got := newRequests[0].GetGameServerSelectors()[0].
		GetMatchLabels()[agones.AdmissionReadyLabel]; got != "v1-"+testWrappingKeyFingerprint {
		t.Fatalf(
			"post-cutover admission selector = %q, want current fingerprint",
			got,
		)
	}

	oldResponseServer := &allocationServer{
		response: allocationResponseFor(
			testPreviousKeyFingerprint,
			testExpectedClaimLocator,
		),
	}
	newClientAgainstOldPool := clientAgainst(t, oldResponseServer, validConfig())
	if got, err := newClientAgainstOldPool.Reserve(
		context.Background(),
		validRequest(),
	); err == nil || got != (GameServer{}) {
		t.Fatalf(
			"post-cutover Reserve accepted old-key Ready response: got %+v, err %v",
			got,
			err,
		)
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
