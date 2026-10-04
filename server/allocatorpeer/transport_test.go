package allocatorpeer

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net"
	"net/http"
	"net/http/httptest"
	"net/netip"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/allocatordiscovery"
	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
	corev1 "k8s.io/api/core/v1"
	discoveryv1 "k8s.io/api/discovery/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	"k8s.io/client-go/rest"
)

type nativeAllocator struct {
	allocationpb.UnimplementedAllocationServiceServer
	calls  atomic.Int32
	handle func(context.Context, *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error)
}

type observedServerTLS struct {
	credentials.TransportCredentials
	errors      chan error
	connections chan net.Conn
}

// ServerHandshake records the native authentication result and authenticated socket.
func (s observedServerTLS) ServerHandshake(raw net.Conn) (net.Conn, credentials.AuthInfo, error) {
	connection, info, err := s.TransportCredentials.ServerHandshake(raw)
	if err == nil {
		select {
		case s.connections <- raw:
		default:
		}
	}
	select {
	case s.errors <- err:
	default:
	}
	return connection, info, err
}

// Allocate counts actual generated RPC handler entries before applying the test effect.
func (s *nativeAllocator) Allocate(ctx context.Context, req *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
	s.calls.Add(1)
	return s.handle(ctx, req)
}

// responseFor returns valid sealed metadata bound to the received allocation request.
func responseFor(req *allocationpb.AllocationRequest) *allocationpb.AllocationResponse {
	fingerprint := strings.Repeat("a", 52)
	return &allocationpb.AllocationResponse{GameServerName: "zone-17", Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{{Name: "tls", Port: 8443}},
		Metadata: &allocationpb.AllocationResponse_GameServerMetadata{Labels: map[string]string{agones.FleetLabel: "zone", agones.AdmissionReadyLabel: agones.AdmissionReadyValue(fingerprint)},
			Annotations: map[string]string{agones.AdmissionKeyAnnotation: fingerprint, agones.AdmissionEnvelopeAnnotation: "v1." + base64.RawURLEncoding.EncodeToString(bytes.Repeat([]byte{7}, 384)), agones.ClaimLocatorAnnotation: req.GetMetadata().GetAnnotations()[agones.ClaimLocatorAnnotation]}}}
}

type nativeFixture struct {
	config           Config
	storage          *nakamastoragetest.Fake
	sources          Sources
	allocator        *nativeAllocator
	mu               sync.Mutex
	pod              corev1.Pod
	slice            discoveryv1.EndpointSlice
	extra            []discoveryv1.EndpointSlice
	handshakeStarted chan struct{}
	resumeHandshake  chan struct{}
	authentication   chan error
	connections      chan net.Conn
	reads            int
}

// privateListener uses a real private non-loopback interface so the address guard is
// exercised without test exceptions. No address or topology is reported.
func privateListener(t *testing.T) net.Listener {
	t.Helper()
	interfaces, err := net.Interfaces()
	if err != nil {
		t.Fatal("cannot enumerate native test interfaces")
	}
	for _, iface := range interfaces {
		if iface.Flags&net.FlagUp == 0 || iface.Flags&net.FlagLoopback != 0 {
			continue
		}
		addresses, err := iface.Addrs()
		if err != nil {
			continue
		}
		for _, address := range addresses {
			prefix, err := netip.ParsePrefix(address.String())
			if err != nil {
				continue
			}
			ip := prefix.Addr()
			if !ip.Is4() || !ip.IsGlobalUnicast() || !ip.IsPrivate() {
				continue
			}
			var listenConfig net.ListenConfig
			listener, err := listenConfig.Listen(t.Context(), "tcp", net.JoinHostPort(ip.String(), "0"))
			if err == nil {
				return listener
			}
		}
	}
	t.Fatal("native allocator proof requires a usable private non-loopback IPv4 interface")
	return nil
}

// fixture composes real generation decoding, typed HTTPS discovery and native mutual TLS.
func fixture(t *testing.T, scenario string) *nativeFixture {
	t.Helper()
	f := &nativeFixture{config: baseConfig(t), storage: nakamastoragetest.New()}
	store, err := nakamageneration.NewStore(f.storage)
	if err != nil {
		t.Fatal(err)
	}
	f.config.Record, err = store.CreateOpen(t.Context(), "generation-1", []string{"uid-a"})
	if err != nil {
		t.Fatal(err)
	}
	f.config.ActorUID = "uid-a"
	f.config.Timeout = time.Second
	ca, caKey := certificate(t, nil, nil, "allocator-root", true, false, false)
	client, clientKey := certificate(t, ca, caKey, "coordinator", false, true, false)
	serverCA, serverCAKey := ca, caKey
	if scenario == "untrusted issuer" {
		serverCA, serverCAKey = certificate(t, nil, nil, "other-root", true, false, false)
	}
	name := "allocator-a.test"
	if scenario == "wrong hostname" {
		name = "other.test"
	}
	serverCert, serverKey := certificate(t, serverCA, serverCAKey, name, false, false, scenario == "expired")
	pin := sha256.Sum256(serverCert.RawSubjectPublicKeyInfo)
	if scenario == "sibling key" {
		sibling, _ := certificate(t, ca, caKey, name, false, false, false)
		pin = sha256.Sum256(sibling.RawSubjectPublicKeyInfo)
	}
	if scenario == "wrong client" {
		otherCA, key := certificate(t, nil, nil, "client-root", true, false, false)
		client, clientKey = certificate(t, otherCA, key, "coordinator", false, true, false)
	}
	clientDER, err := x509.MarshalPKCS8PrivateKey(clientKey)
	if err != nil {
		t.Fatal(err)
	}
	f.config.Credentials = Credentials{RootDER: [][]byte{bytes.Clone(ca.Raw)}, CertificateDER: [][]byte{bytes.Clone(client.Raw)}, PrivateKeyDER: clientDER}
	f.config.Peers = map[string]PeerIdentity{"uid-a": {ServerName: "allocator-a.test", SPKI: pin}}
	clientRoots := x509.NewCertPool()
	clientRoots.AddCert(ca)
	tlsConfig := &tls.Config{Certificates: []tls.Certificate{{Certificate: [][]byte{serverCert.Raw}, PrivateKey: serverKey}}, ClientCAs: clientRoots, ClientAuth: tls.RequireAndVerifyClientCert, MinVersion: tls.VersionTLS13}
	if scenario == "paused handshake" {
		f.handshakeStarted = make(chan struct{})
		f.resumeHandshake = make(chan struct{})
		var once sync.Once
		tlsConfig.VerifyConnection = func(tls.ConnectionState) error {
			once.Do(func() { close(f.handshakeStarted) })
			select {
			case <-f.resumeHandshake:
			case <-t.Context().Done():
				return t.Context().Err()
			}
			return nil
		}
	}
	if scenario == "TLS 1.2" {
		tlsConfig.MinVersion = tls.VersionTLS12
		tlsConfig.MaxVersion = tls.VersionTLS12
	}
	listener := privateListener(t)
	address, err := netip.ParseAddrPort(listener.Addr().String())
	if err != nil {
		t.Fatal("invalid native listener address")
	}
	f.allocator = &nativeAllocator{handle: func(_ context.Context, request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		return responseFor(request), nil
	}}
	f.authentication = make(chan error, 16)
	f.connections = make(chan net.Conn, 16)
	server := grpc.NewServer(grpc.Creds(observedServerTLS{TransportCredentials: credentials.NewTLS(tlsConfig), errors: f.authentication, connections: f.connections}))
	allocationpb.RegisterAllocationServiceServer(server, f.allocator)
	serveResult := make(chan error, 1)
	go func() { serveResult <- server.Serve(listener) }()
	t.Cleanup(func() {
		server.Stop()
		if err := <-serveResult; err != nil && !errors.Is(err, grpc.ErrServerStopped) {
			t.Error("native allocator server failed")
		}
	})
	f.pod = corev1.Pod{ObjectMeta: metav1.ObjectMeta{Namespace: "allocators", Name: "allocator-a", UID: types.UID("uid-a"), ResourceVersion: "pod-1", Labels: map[string]string{"app": "allocator"}}, Status: corev1.PodStatus{Phase: corev1.PodRunning, PodIP: address.Addr().String(), Conditions: []corev1.PodCondition{{Type: corev1.PodReady, Status: corev1.ConditionTrue}}}}
	ready, serving, terminating, controller := true, true, false, true
	portName, port, protocol := "grpc", int32(address.Port()), corev1.ProtocolTCP
	f.slice = discoveryv1.EndpointSlice{ObjectMeta: metav1.ObjectMeta{Namespace: "allocators", Name: "allocator-slice", UID: types.UID("slice-a"), ResourceVersion: "slice-1", Labels: map[string]string{discoveryv1.LabelServiceName: "allocator"}, OwnerReferences: []metav1.OwnerReference{{APIVersion: "v1", Kind: "Service", Name: "allocator", UID: types.UID("service-a"), Controller: &controller}}}, AddressType: discoveryv1.AddressTypeIPv4,
		Ports: []discoveryv1.EndpointPort{{Name: &portName, Port: &port, Protocol: &protocol}}, Endpoints: []discoveryv1.Endpoint{{Addresses: []string{address.Addr().String()}, Conditions: discoveryv1.EndpointConditions{Ready: &ready, Serving: &serving, Terminating: &terminating}, TargetRef: &corev1.ObjectReference{APIVersion: "v1", Kind: "Pod", Namespace: "allocators", Name: "allocator-a", UID: types.UID("uid-a")}}}}
	api := httptest.NewTLSServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		f.mu.Lock()
		defer f.mu.Unlock()
		f.reads++
		if r.Method != http.MethodGet {
			t.Error("discovery attempted mutation")
			w.WriteHeader(http.StatusMethodNotAllowed)
			return
		}
		var result any
		switch r.URL.Path {
		case "/api/v1/namespaces/allocators/pods":
			if r.URL.Query().Get("labelSelector") != "app=allocator" {
				t.Error("wrong Pod selector")
			}
			result = &corev1.PodList{TypeMeta: metav1.TypeMeta{APIVersion: "v1", Kind: "PodList"}, ListMeta: metav1.ListMeta{ResourceVersion: "pods-1"}, Items: []corev1.Pod{*f.pod.DeepCopy()}}
		case "/apis/discovery.k8s.io/v1/namespaces/allocators/endpointslices":
			if r.URL.Query().Get("labelSelector") != "kubernetes.io/service-name=allocator" {
				t.Error("wrong Service selector")
			}
			items := []discoveryv1.EndpointSlice{*f.slice.DeepCopy()}
			for _, extra := range f.extra {
				items = append(items, *extra.DeepCopy())
			}
			result = &discoveryv1.EndpointSliceList{TypeMeta: metav1.TypeMeta{APIVersion: "discovery.k8s.io/v1", Kind: "EndpointSliceList"}, ListMeta: metav1.ListMeta{ResourceVersion: "slices-1"}, Items: items}
		default:
			t.Error("unexpected discovery resource")
			w.WriteHeader(http.StatusNotFound)
			return
		}
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(result); err != nil {
			t.Error(err)
		}
	}))
	t.Cleanup(api.Close)
	reader, err := allocatordiscovery.New(&rest.Config{Host: api.URL, Timeout: time.Second, TLSClientConfig: rest.TLSClientConfig{CAData: pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: api.Certificate().Raw})}}, allocatordiscovery.Config{Namespace: "allocators", PodSelector: "app=allocator", ServiceName: "allocator", ServiceUID: "service-a", PortName: "grpc", MaxPages: 2})
	if err != nil {
		t.Fatal(err)
	}
	f.sources = Sources{Generations: store, Discovery: reader}
	return f
}

// newClient requires fixture construction to pass the production constructor.
func (f *nativeFixture) newClient(t *testing.T) *Client {
	t.Helper()
	client, err := NewClient(f.sources, f.config)
	if err != nil {
		t.Fatal(err)
	}
	return client
}

// allocationRequest supplies bounded opaque correlation values without player data.
func allocationRequest() agonesalloc.Request {
	return agonesalloc.Request{ReservationID: "reservation-1", AttemptID: "attempt-1", LeaseObjectID: strings.Repeat("0", 64)}
}

// TestNativeCompositionAndOwnedInputs observes allocation after mutating caller-owned inputs.
func TestNativeCompositionAndOwnedInputs(t *testing.T) {
	t.Setenv("HTTPS_PROXY", "http://127.0.0.1:1")
	t.Setenv("ALL_PROXY", "http://127.0.0.1:1")
	f := fixture(t, "")
	client := f.newClient(t)
	// Constructor ownership is tested through the actual handshake and record join.
	f.config.Record.MemberPodUIDs[0] = "mutated"
	delete(f.config.Peers, "uid-a")
	for _, der := range append(f.config.Credentials.RootDER, f.config.Credentials.CertificateDER...) {
		clear(der)
	}
	clear(f.config.Credentials.PrivateKeyDER)
	result, err := client.Reserve(t.Context(), allocationRequest())
	if err != nil || result.GameServer.Name != "zone-17" || result.Binding.ActorUID != "uid-a" || result.Binding.SourceVersion != "v1" || f.allocator.calls.Load() != 1 {
		t.Fatalf("native composition failed: %v calls=%d", err, f.allocator.calls.Load())
	}
	if f.storage.ReadCalls < 5 || len(f.storage.WriteCalls) != 1 {
		t.Fatalf("missing fresh reads or transport mutation: reads=%d writes=%d", f.storage.ReadCalls, len(f.storage.WriteCalls))
	}
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.reads != 4 {
		t.Fatalf("expected two complete native discovery passes, got %d reads", f.reads)
	}
}

// TestNativeCertificateRefusals requires native TLS verdicts beside a successful control.
func TestNativeCertificateRefusals(t *testing.T) {
	control := fixture(t, "")
	if _, err := control.newClient(t).Reserve(t.Context(), allocationRequest()); err != nil || control.allocator.calls.Load() != 1 {
		t.Fatalf("native positive control failed: %v", err)
	}
	for _, scenario := range []string{"expired", "wrong hostname", "untrusted issuer", "sibling key", "wrong client", "TLS 1.2"} {
		t.Run(scenario, func(t *testing.T) {
			f := fixture(t, scenario)
			f.config.Timeout = 200 * time.Millisecond
			_, err := f.newClient(t).Reserve(t.Context(), allocationRequest())
			if !errors.Is(err, ErrConnection) || errors.Is(err, ErrUncertain) || f.allocator.calls.Load() != 0 {
				t.Fatalf("unauthenticated RPC: %v calls=%d", err, f.allocator.calls.Load())
			}
			select {
			case handshakeErr := <-f.authentication:
				if handshakeErr == nil {
					t.Fatal("negative TLS control authenticated")
				}
				message := handshakeErr.Error()
				if !strings.Contains(message, "certificate") && !strings.Contains(message, "unsupported versions") && !strings.Contains(message, "protocol version") {
					t.Fatal("negative control failed outside certificate/TLS verification")
				}
			case <-time.After(time.Second):
				t.Fatal("negative control produced no native TLS verdict")
			}
		})
	}
}

// TestNativeConnectionLossAfterEffectDoesNotReplay drops TCP while the allocator remains available.
func TestNativeConnectionLossAfterEffectDoesNotReplay(t *testing.T) {
	control := fixture(t, "")
	if _, err := control.newClient(t).Reserve(t.Context(), allocationRequest()); err != nil || control.allocator.calls.Load() != 1 {
		t.Fatalf("native positive control failed: %v", err)
	}
	f := fixture(t, "")
	effects := atomic.Int32{}
	closed := make(chan error, 16)
	f.allocator.handle = func(_ context.Context, req *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		effects.Add(1)
		select {
		case connection := <-f.connections:
			// Keep the listener and handler available: a replay can reconnect and
			// repeat the effect, so stopping the service cannot hide one.
			closed <- connection.Close()
		default:
			closed <- errors.New("missing authenticated socket")
		}
		return responseFor(req), nil
	}
	result, err := f.newClient(t).Reserve(t.Context(), allocationRequest())
	if !errors.Is(err, ErrUncertain) || result != (Result{}) || effects.Load() != 1 || f.allocator.calls.Load() != 1 {
		t.Fatalf("native response loss repeated or hid an allocation: err=%v effects=%d calls=%d", err, effects.Load(), f.allocator.calls.Load())
	}
	select {
	case closeErr := <-closed:
		if closeErr != nil {
			t.Fatal("native socket was not closed after the effect")
		}
	default:
		t.Fatal("no native connection-loss observation")
	}
}

// TestNativeResponsesStayUncertainWithoutRetry observes errors and effects after caller return.
func TestNativeResponsesStayUncertainWithoutRetry(t *testing.T) {
	for _, scenario := range []string{"lost response", "unallocated", "malformed", "deadline", "cancel", "remote deadline", "remote cancel"} {
		t.Run(scenario, func(t *testing.T) {
			f := fixture(t, "")
			effects := atomic.Int32{}
			entered := make(chan struct{})
			release := make(chan struct{})
			effectDone := make(chan struct{})
			var releaseOnce sync.Once
			releaseLate := func() { releaseOnce.Do(func() { close(release) }) }
			t.Cleanup(releaseLate)
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			f.allocator.handle = func(callCtx context.Context, req *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
				if scenario == "cancel" || scenario == "deadline" {
					close(entered)
					<-release
				}
				effects.Add(1)
				close(effectDone)
				switch scenario {
				case "lost response":
					return nil, status.Error(codes.Unavailable, "private upstream text")
				case "unallocated":
					return nil, status.Error(codes.ResourceExhausted, "there is no available GameServer to allocate")
				case "malformed":
					r := responseFor(req)
					r.Ports = nil
					return r, nil
				case "cancel", "deadline":
					return nil, callCtx.Err()
				case "remote deadline":
					return nil, status.Error(codes.DeadlineExceeded, "private upstream deadline")
				case "remote cancel":
					return nil, status.Error(codes.Canceled, "private upstream cancellation")
				default:
					panic("unknown test scenario")
				}
			}
			if scenario == "deadline" {
				f.config.Timeout = 200 * time.Millisecond
			}
			if strings.HasPrefix(scenario, "remote ") {
				f.config.Timeout = 10 * time.Second
			}
			client := f.newClient(t)
			type outcome struct {
				result Result
				err    error
			}
			finished := make(chan outcome, 1)
			go func() { result, err := client.Reserve(ctx, allocationRequest()); finished <- outcome{result, err} }()
			if scenario == "cancel" || scenario == "deadline" {
				select {
				case <-entered:
				case <-time.After(time.Second):
					releaseLate()
					t.Fatal("allocation never reached server")
				}
				if scenario == "cancel" {
					cancel()
				}
			}
			got := <-finished
			result, err := got.result, got.err
			if scenario == "cancel" || scenario == "deadline" {
				if effects.Load() != 0 {
					t.Fatal("effect happened before caller interruption")
				}
				releaseLate()
				select {
				case <-effectDone:
				case <-time.After(time.Second):
					t.Fatal("late server effect missing")
				}
			}
			if !errors.Is(err, ErrUncertain) || errors.Is(err, agonesalloc.ErrUnallocated) || result != (Result{}) || f.allocator.calls.Load() != 1 || effects.Load() != 1 || strings.Contains(err.Error(), "private upstream") {
				t.Fatalf("unsafe outcome: %v calls=%d effects=%d", err, f.allocator.calls.Load(), effects.Load())
			}
			if (scenario == "deadline" || scenario == "remote deadline") && !errors.Is(err, context.DeadlineExceeded) {
				t.Fatalf("lost deadline: %v", err)
			}
			if (scenario == "cancel" || scenario == "remote cancel") && !errors.Is(err, context.Canceled) {
				t.Fatalf("lost cancellation: %v", err)
			}
			if strings.HasPrefix(scenario, "remote ") && ctx.Err() != nil {
				t.Fatal("remote interruption control canceled the caller context")
			}
		})
	}
}

type afterDiscovery struct {
	next  DiscoveryReader
	after func()
}

// Discover changes storage after a complete discovery result to probe the final source read.
func (s afterDiscovery) Discover(ctx context.Context) (allocatordiscovery.Snapshot, error) {
	snapshot, err := s.next.Discover(ctx)
	s.after()
	return snapshot, err
}

// TestNativeChangesBeforeRPCAndNextOperation refuses stale versions and alternate endpoints.
func TestNativeChangesBeforeRPCAndNextOperation(t *testing.T) {
	for _, scenario := range []string{"generation after discovery", "readiness after connect", "generation next operation", "no alternate endpoint"} {
		t.Run(scenario, func(t *testing.T) {
			f := fixture(t, "")
			switch scenario {
			case "generation after discovery":
				f.sources.Discovery = afterDiscovery{next: f.sources.Discovery, after: func() {
					obj, ok := f.storage.Get(nakamageneration.Collection, "generation-1", "")
					if !ok {
						t.Fatal("missing generation")
					}
					obj.Version = "v2"
					f.storage.Seed(obj)
				}}
			case "readiness after connect":
				count := 0
				f.sources.Discovery = afterDiscovery{next: f.sources.Discovery, after: func() {
					count++
					if count == 1 {
						f.mu.Lock()
						f.pod.Status.Conditions[0].Status = corev1.ConditionFalse
						f.mu.Unlock()
					}
				}}
			case "no alternate endpoint":
				f.mu.Lock()
				f.extra = []discoveryv1.EndpointSlice{*f.slice.DeepCopy()}
				bad := f.slice.DeepCopy()
				p := int32(1)
				bad.Ports[0].Port = &p
				bad.Name = "closed-endpoint"
				bad.UID = types.UID("closed-slice")
				f.slice = *bad
				f.mu.Unlock()
				f.config.Timeout = 200 * time.Millisecond
			case "generation next operation":
			}
			client := f.newClient(t)
			if scenario == "generation next operation" {
				if _, err := client.Reserve(t.Context(), allocationRequest()); err != nil {
					t.Fatal(err)
				}
				obj, ok := f.storage.Get(nakamageneration.Collection, "generation-1", "")
				if !ok {
					t.Fatal("missing generation")
				}
				obj.Version = "v2"
				f.storage.Seed(obj)
			}
			_, err := client.Reserve(t.Context(), allocationRequest())
			want := int32(0)
			if scenario == "generation next operation" {
				want = 1
			}
			if err == nil || errors.Is(err, ErrUncertain) || f.allocator.calls.Load() != want {
				t.Fatalf("stale/fallback dispatch: %v calls=%d", err, f.allocator.calls.Load())
			}
		})
	}
}

// TestNativeObservationChangeDuringPausedHandshake proves readiness cannot preserve a stale join.
func TestNativeObservationChangeDuringPausedHandshake(t *testing.T) {
	for _, change := range []string{"generation", "readiness"} {
		t.Run(change, func(t *testing.T) {
			f := fixture(t, "paused handshake")
			f.config.Timeout = 2 * time.Second
			client := f.newClient(t)
			result := make(chan error, 1)
			go func() { _, err := client.Reserve(t.Context(), allocationRequest()); result <- err }()
			select {
			case <-f.handshakeStarted:
			case <-time.After(time.Second):
				close(f.resumeHandshake)
				t.Fatal("handshake did not reach pause")
			}
			object, ok := f.storage.Get(nakamageneration.Collection, "generation-1", "")
			if !ok {
				close(f.resumeHandshake)
				t.Fatal("missing generation")
			}
			if change == "generation" {
				object.Version = "v2"
				f.storage.Seed(object)
			} else {
				f.mu.Lock()
				f.pod.Status.Conditions[0].Status = corev1.ConditionFalse
				f.mu.Unlock()
			}
			close(f.resumeHandshake)
			err := <-result
			if !errors.Is(err, ErrObservation) || errors.Is(err, ErrUncertain) || f.allocator.calls.Load() != 0 {
				t.Fatalf("handshake admitted stale generation: %v calls=%d", err, f.allocator.calls.Load())
			}
		})
	}
}
