package agonesresources

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"crypto/x509"
	"encoding/base32"
	"encoding/base64"
	"errors"
	"fmt"
	"net"
	"strings"
	"sync"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/agonesalloc"
	"github.com/devantler-tech/world-at-ruin/server/gameserverapi"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/handoffalloc"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials/insecure"
	"google.golang.org/grpc/status"
	"google.golang.org/grpc/test/bufconn"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/schema"
	"k8s.io/apimachinery/pkg/types"
	clienttesting "k8s.io/client-go/testing"
)

const (
	testNamespace     = "world-at-ruin"
	testFleet         = "zone"
	testTLSPortName   = "tls"
	testTLSPort       = uint16(8443)
	testZoneDomain    = "zones.example"
	testNodeName      = "node-a"
	testUserID        = "user-1"
	testReservationID = "handoff-42"
	testAttemptID     = "attempt-7"
	testObserver      = sim.EntityID(42)
)

var (
	testExpiry = time.Date(2026, time.September, 5, 12, 0, 0, 0, time.UTC).Add(time.Minute)

	gameServerResource = schema.GroupVersionResource{
		Group:    "agones.dev",
		Version:  "v1",
		Resource: "gameservers",
	}
	gameServerKind = schema.GroupVersionKind{
		Group:   "agones.dev",
		Version: "v1",
		Kind:    "GameServer",
	}

	testKeyOnce sync.Once
	testKey     *rsa.PrivateKey
	testKeyErr  error
)

func testPrivateKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	testKeyOnce.Do(func() {
		testKey, testKeyErr = rsa.GenerateKey(rand.Reader, 3072)
	})
	if testKeyErr != nil {
		t.Fatalf("generate RSA test key: %v", testKeyErr)
	}
	return testKey
}

func fingerprintOf(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	der, err := x509.MarshalPKIXPublicKey(&key.PublicKey)
	if err != nil {
		t.Fatalf("marshal test public key: %v", err)
	}
	digest := sha256.Sum256(der)
	return strings.ToLower(
		base32.StdEncoding.WithPadding(base32.NoPadding).EncodeToString(digest[:]),
	)
}

// secretFor is the admission secret the fixture seals for one GameServer name,
// distinct per object so a test can prove which envelope was opened.
func secretFor(name string) []byte {
	digest := sha256.Sum256([]byte("admission:" + name))
	return digest[:]
}

func sealedEnvelope(
	t *testing.T,
	key *rsa.PrivateKey,
	name string,
	uid types.UID,
	fingerprint string,
	secret []byte,
) string {
	t.Helper()
	label := []byte(strings.Join([]string{
		"world-at-ruin/zone-admission/v1",
		testNamespace,
		name,
		string(uid),
		fingerprint,
	}, "\x00"))
	ciphertext, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.PublicKey, secret, label)
	if err != nil {
		t.Fatalf("seal test envelope: %v", err)
	}
	return "v1." + base64.RawURLEncoding.EncodeToString(ciphertext)
}

type allocationHandler func(
	*allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error)

type allocationServer struct {
	allocationpb.UnimplementedAllocationServiceServer

	mu     sync.Mutex
	handle allocationHandler
	calls  []*allocationpb.AllocationRequest
}

func (s *allocationServer) Allocate(
	_ context.Context,
	request *allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, request)
	return s.handle(request)
}

func (s *allocationServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.calls)
}

func (s *allocationServer) setHandler(handle allocationHandler) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.handle = handle
}

type fixture struct {
	t           *testing.T
	clientset   *agonesfake.Clientset
	allocations *allocationServer
	adapter     *Adapter
	keyring     *admissionref.Keyring
	key         *rsa.PrivateKey
	fingerprint string
}

func newFixture(t *testing.T, mutate func(*Config)) *fixture {
	t.Helper()
	key := testPrivateKey(t)
	f := &fixture{
		t:           t,
		clientset:   agonesfake.NewSimpleClientset(),
		allocations: &allocationServer{},
		key:         key,
		fingerprint: fingerprintOf(t, key),
	}
	f.allocations.handle = f.commitAllocation

	listener := bufconn.Listen(1024 * 1024)
	grpcServer := grpc.NewServer()
	allocationpb.RegisterAllocationServiceServer(grpcServer, f.allocations)
	go func() {
		_ = grpcServer.Serve(listener)
	}()
	t.Cleanup(grpcServer.Stop)
	t.Cleanup(func() {
		_ = listener.Close()
	})
	conn, err := grpc.NewClient(
		"passthrough:///agones-resources-test",
		grpc.WithTransportCredentials(insecure.NewCredentials()),
		grpc.WithContextDialer(func(ctx context.Context, _ string) (net.Conn, error) {
			return listener.DialContext(ctx)
		}),
	)
	if err != nil {
		t.Fatalf("create allocation test client: %v", err)
	}
	t.Cleanup(func() {
		_ = conn.Close()
	})

	allocator, err := agonesalloc.NewClient(
		allocationpb.NewAllocationServiceClient(conn),
		agonesalloc.Config{
			Namespace:              testNamespace,
			Fleet:                  testFleet,
			TLSPortName:            testTLSPortName,
			WrappingKeyFingerprint: f.fingerprint,
		},
	)
	if err != nil {
		t.Fatalf("agonesalloc.NewClient: %v", err)
	}
	resources, err := gameserverapi.NewClient(
		f.clientset.AgonesV1().GameServers(testNamespace),
		gameserverapi.Config{
			Namespace:   testNamespace,
			Fleet:       testFleet,
			TLSPortName: testTLSPortName,
		},
	)
	if err != nil {
		t.Fatalf("gameserverapi.NewClient: %v", err)
	}
	f.keyring, err = admissionref.NewKeyring(key)
	if err != nil {
		t.Fatalf("admissionref.NewKeyring: %v", err)
	}
	cfg := f.config()
	if mutate != nil {
		mutate(&cfg)
	}
	f.adapter, err = NewAdapter(allocator, resources, f.keyring, cfg)
	if err != nil {
		t.Fatalf("NewAdapter: %v", err)
	}
	return f
}

func (f *fixture) config() Config {
	return Config{
		Namespace:              testNamespace,
		WrappingKeyFingerprint: f.fingerprint,
		ZoneDomain:             testZoneDomain,
		Observer: func(handoff.AllocationRequest) (sim.EntityID, error) {
			return testObserver, nil
		},
		ObservationTimeout:  150 * time.Millisecond,
		ObservationInterval: 2 * time.Millisecond,
	}
}

func request() handoff.AllocationRequest {
	return handoff.AllocationRequest{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
	}
}

func attemptDigest(t *testing.T, attemptID string) string {
	t.Helper()
	digest, err := agones.CorrelationLabel(attemptID)
	if err != nil {
		t.Fatalf("attempt digest: %v", err)
	}
	return digest
}

// readyGameServer is one envelope-ready pool member exactly as the zone
// publishes it before calling Ready.
func (f *fixture) readyGameServer(name string, uid types.UID) *agonesv1.GameServer {
	return &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: testNamespace,
			Name:      name,
			UID:       uid,
			Labels: map[string]string{
				agones.FleetLabel:          testFleet,
				agones.AdmissionReadyLabel: "v1-" + f.fingerprint,
			},
			Annotations: map[string]string{
				agones.AdmissionEnvelopeAnnotation: sealedEnvelope(
					f.t, f.key, name, uid, f.fingerprint, secretFor(name),
				),
				agones.AdmissionKeyAnnotation: f.fingerprint,
			},
		},
		Status: agonesv1.GameServerStatus{
			State:    agonesv1.GameServerStateReady,
			NodeName: testNodeName,
			Ports: []agonesv1.GameServerStatusPort{
				{Name: testTLSPortName, Port: int32(testTLSPort)},
			},
		},
	}
}

func (f *fixture) allocatedGameServer(
	name string,
	uid types.UID,
	attemptID string,
) *agonesv1.GameServer {
	gameServer := f.readyGameServer(name, uid)
	gameServer.Status.State = agonesv1.GameServerStateAllocated
	gameServer.Labels[agones.AttemptLabel] = attemptDigest(f.t, attemptID)
	gameServer.Labels["world-at-ruin.dev/handoff-reservation"] = attemptDigest(f.t, testReservationID)
	return gameServer
}

// seed places objects through the tracker so the fixture's own writes never
// appear in the recorded client actions the tests assert on.
func (f *fixture) seed(gameServers ...*agonesv1.GameServer) {
	f.t.Helper()
	for _, gameServer := range gameServers {
		if err := f.clientset.Tracker().Add(gameServer.DeepCopy()); err != nil {
			f.t.Fatalf("seed GameServer %s: %v", gameServer.Name, err)
		}
	}
}

func (f *fixture) replace(gameServer *agonesv1.GameServer) {
	f.t.Helper()
	tracker := f.clientset.Tracker()
	if err := tracker.Delete(gameServerResource, testNamespace, gameServer.Name); err != nil &&
		!apierrors.IsNotFound(err) {
		f.t.Fatalf("replace GameServer %s: delete: %v", gameServer.Name, err)
	}
	if err := tracker.Add(gameServer.DeepCopy()); err != nil {
		f.t.Fatalf("replace GameServer %s: add: %v", gameServer.Name, err)
	}
}

func (f *fixture) stored(name string) *agonesv1.GameServer {
	f.t.Helper()
	object, err := f.clientset.Tracker().Get(gameServerResource, testNamespace, name)
	if err != nil {
		f.t.Fatalf("read stored GameServer %s: %v", name, err)
	}
	gameServer, ok := object.(*agonesv1.GameServer)
	if !ok {
		f.t.Fatalf("stored object is %T, want GameServer", object)
	}
	return gameServer
}

func (f *fixture) exists(name string) bool {
	_, err := f.clientset.Tracker().Get(gameServerResource, testNamespace, name)
	return err == nil
}

// commitAllocation is the allocator's honest behaviour: it selects one Ready
// pool member matching the request's selector, applies the metadata patch,
// moves it to Allocated and answers with that object's material.
func (f *fixture) commitAllocation(
	request *allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error) {
	gameServer, err := f.selectReady(request)
	if err != nil {
		return nil, err
	}
	f.applyPatch(gameServer, request)
	if err := f.clientset.Tracker().Update(gameServerResource, gameServer, testNamespace); err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	return responseFor(gameServer), nil
}

func (f *fixture) selectReady(
	request *allocationpb.AllocationRequest,
) (*agonesv1.GameServer, error) {
	object, err := f.clientset.Tracker().List(gameServerResource, gameServerKind, testNamespace)
	if err != nil {
		return nil, status.Error(codes.Internal, err.Error())
	}
	list, ok := object.(*agonesv1.GameServerList)
	if !ok {
		return nil, status.Error(codes.Internal, "list is not a GameServerList")
	}
	for i := range list.Items {
		candidate := &list.Items[i]
		if candidate.Status.State != agonesv1.GameServerStateReady {
			continue
		}
		matches := true
		for _, selector := range request.GetGameServerSelectors() {
			for key, value := range selector.GetMatchLabels() {
				if candidate.Labels[key] != value {
					matches = false
				}
			}
		}
		if matches {
			return candidate.DeepCopy(), nil
		}
	}
	return nil, status.Error(codes.ResourceExhausted, "no Ready GameServer matches")
}

func (f *fixture) applyPatch(
	gameServer *agonesv1.GameServer,
	request *allocationpb.AllocationRequest,
) {
	for key, value := range request.GetMetadata().GetLabels() {
		gameServer.Labels[key] = value
	}
	for key, value := range request.GetMetadata().GetAnnotations() {
		gameServer.Annotations[key] = value
	}
	gameServer.Status.State = agonesv1.GameServerStateAllocated
}

func responseFor(gameServer *agonesv1.GameServer) *allocationpb.AllocationResponse {
	ports := make([]*allocationpb.AllocationResponse_GameServerStatusPort, 0, len(gameServer.Status.Ports))
	for _, port := range gameServer.Status.Ports {
		ports = append(ports, &allocationpb.AllocationResponse_GameServerStatusPort{
			Name: port.Name,
			Port: port.Port,
		})
	}
	labels := make(map[string]string, len(gameServer.Labels))
	for key, value := range gameServer.Labels {
		labels[key] = value
	}
	annotations := make(map[string]string, len(gameServer.Annotations))
	for key, value := range gameServer.Annotations {
		annotations[key] = value
	}
	return &allocationpb.AllocationResponse{
		GameServerName: gameServer.Name,
		Ports:          ports,
		NodeName:       gameServer.Status.NodeName,
		Metadata: &allocationpb.AllocationResponse_GameServerMetadata{
			Labels:      labels,
			Annotations: annotations,
		},
	}
}

func (f *fixture) actions(verb string) int {
	count := 0
	for _, action := range f.clientset.Actions() {
		if action.GetVerb() == verb {
			count++
		}
	}
	return count
}

// deletedUIDs returns the UID precondition of every recorded delete, failing
// when any delete was issued without one.
func (f *fixture) deletedUIDs() []types.UID {
	f.t.Helper()
	var uids []types.UID
	for _, action := range f.clientset.Actions() {
		deleteAction, ok := action.(clienttesting.DeleteAction)
		if !ok {
			continue
		}
		options := deleteAction.GetDeleteOptions()
		if options.Preconditions == nil || options.Preconditions.UID == nil {
			f.t.Fatalf("delete of %s carried no UID precondition", deleteAction.GetName())
		}
		uids = append(uids, *options.Preconditions.UID)
	}
	return uids
}

func (f *fixture) expectedReference(name string) string {
	f.t.Helper()
	gameServer := f.stored(name)
	reference, err := admissionref.Reference(admissionref.Material{
		Namespace:              testNamespace,
		GameServerName:         name,
		GameServerUID:          string(gameServer.UID),
		WrappingKeyFingerprint: f.fingerprint,
		AdmissionEnvelope:      gameServer.Annotations[agones.AdmissionEnvelopeAnnotation],
		TLSPort:                testTLSPort,
	})
	if err != nil {
		f.t.Fatalf("expected reference: %v", err)
	}
	return reference
}

func assertAllocation(
	t *testing.T,
	got handoff.Allocation,
	name string,
	expiresAt time.Time,
) {
	t.Helper()
	if got.ID != name ||
		got.ServerName != testNodeName+"."+testZoneDomain ||
		got.Port != testTLSPort ||
		got.Observer != testObserver ||
		!bytes.Equal(got.AdmissionSecret, secretFor(name)) ||
		!got.LeaseExpiresAt.Equal(expiresAt) ||
		got.RetainOnFailure {
		t.Fatalf("allocation = %+v, want %s on %s.%s:%d bound to observer %d",
			got, name, testNodeName, testZoneDomain, testTLSPort, testObserver)
	}
}

func assertCode(t *testing.T, err error, want error, code codes.Code) {
	t.Helper()
	if !errors.Is(err, want) {
		t.Fatalf("error = %v, want %v", err, want)
	}
	if status.Code(err) != code {
		t.Fatalf("status code = %s, want %s", status.Code(err), code)
	}
	wrapped := fmt.Errorf("outer: %w", err)
	if status.Code(wrapped) != code {
		t.Fatalf("wrapped status code = %s, want %s", status.Code(wrapped), code)
	}
}

func TestProvisionDispatchesOnceAndOpensTheSealedEnvelope(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("Provision returned an error: %v", err)
	}
	assertAllocation(t, got.Allocation, "zone-1", testExpiry)
	if want := f.expectedReference("zone-1"); got.SecretRef != want {
		t.Fatalf("SecretRef = %q, want %q", got.SecretRef, want)
	}
	if !strings.HasPrefix(got.SecretRef, "v1.k"+f.fingerprint+".u") {
		t.Fatalf("SecretRef %q does not pin the wrapping key", got.SecretRef)
	}
	if f.allocations.count() != 1 {
		t.Fatalf("allocation RPCs = %d, want exactly one", f.allocations.count())
	}
	dispatched := f.allocations.calls[0]
	wantLocator := "v1." + nakamalease.ReservationKey(testUserID, testReservationID) +
		"." + attemptDigest(t, testAttemptID)
	if dispatched.GetMetadata().GetAnnotations()[agones.ClaimLocatorAnnotation] != wantLocator {
		t.Fatalf("dispatch carried claim locator %q, want %q",
			dispatched.GetMetadata().GetAnnotations()[agones.ClaimLocatorAnnotation], wantLocator)
	}
	if dispatched.GetMetadata().GetLabels()[agones.AttemptLabel] != attemptDigest(t, testAttemptID) {
		t.Fatal("dispatch did not carry the attempt digest label")
	}
	if f.actions("delete") != 0 {
		t.Fatalf("a successful provision deleted %d objects", f.actions("delete"))
	}
	if stored := f.stored("zone-1"); stored.Status.State != agonesv1.GameServerStateAllocated {
		t.Fatalf("stored state = %s, want Allocated", stored.Status.State)
	}
}

func TestProvisionAdoptsTheAttemptsGameServerWithoutRedispatch(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"), f.readyGameServer("zone-2", "uid-2"))

	first, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("first Provision returned an error: %v", err)
	}
	second, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("replayed Provision returned an error: %v", err)
	}
	reconciled, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("Reconcile returned an error: %v", err)
	}
	for _, got := range []handoffalloc.Provisioned{second, reconciled} {
		assertAllocation(t, got.Allocation, first.Allocation.ID, testExpiry)
		if got.SecretRef != first.SecretRef {
			t.Fatalf("replay SecretRef = %q, want %q", got.SecretRef, first.SecretRef)
		}
	}
	if f.allocations.count() != 1 {
		t.Fatalf("allocation RPCs = %d, want the single original dispatch", f.allocations.count())
	}
	if f.stored("zone-2").Status.State != agonesv1.GameServerStateReady {
		t.Fatal("the replay consumed a second pool member")
	}
}

func TestDuplicateMatchesAreReleasedByTheirOwnUIDAndFailClosed(t *testing.T) {
	for _, operation := range []string{"Provision", "Reconcile"} {
		t.Run(operation, func(t *testing.T) {
			f := newFixture(t, nil)
			f.seed(
				f.allocatedGameServer("zone-1", "uid-1", testAttemptID),
				f.allocatedGameServer("zone-2", "uid-2", testAttemptID),
				f.readyGameServer("zone-3", "uid-3"),
			)
			var got handoffalloc.Provisioned
			var err error
			if operation == "Provision" {
				got, err = f.adapter.Provision(context.Background(), request(), testExpiry)
			} else {
				got, err = f.adapter.Reconcile(context.Background(), request(), testExpiry)
			}
			assertCode(t, err, ErrDuplicateAttempt, codes.Aborted)
			if !isZeroProvisioned(got) {
				t.Fatalf("duplicate outcome returned material: %+v", got)
			}
			uids := f.deletedUIDs()
			if len(uids) != 2 || uids[0] == uids[1] {
				t.Fatalf("deleted UIDs = %v, want each duplicate exactly once", uids)
			}
			if f.exists("zone-1") || f.exists("zone-2") || !f.exists("zone-3") {
				t.Fatal("duplicate release touched the wrong objects")
			}
			if f.allocations.count() != 0 {
				t.Fatalf("duplicates caused %d allocation RPCs, want none", f.allocations.count())
			}
		})
	}
}

func TestProvisionReportsAnUnobservableDispatchAsAmbiguous(t *testing.T) {
	f := newFixture(t, nil)
	f.allocations.setHandler(f.ghostAllocation)

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	assertCode(t, err, ErrAmbiguousDispatch, codes.Unavailable)
	if !isZeroProvisioned(got) {
		t.Fatalf("ambiguous outcome returned material: %+v", got)
	}
	if f.allocations.count() != 1 {
		t.Fatalf("allocation RPCs = %d, want exactly one", f.allocations.count())
	}
	if f.actions("list") < 3 {
		t.Fatalf("observed %d lists, want a bounded retry rather than one read", f.actions("list"))
	}
	if f.actions("delete") != 0 {
		t.Fatal("an ambiguous dispatch released something")
	}

	got, err = f.adapter.Reconcile(context.Background(), request(), testExpiry)
	assertCode(t, err, ErrAmbiguousDispatch, codes.Unavailable)
	if !isZeroProvisioned(got) {
		t.Fatalf("reconciled ambiguous outcome returned material: %+v", got)
	}
	if f.allocations.count() != 1 {
		t.Fatalf("allocation RPCs = %d, want the quarantined dispatch never reissued", f.allocations.count())
	}
}

func TestProvisionReportsCallerCancellationAsCancellation(t *testing.T) {
	f := newFixture(t, func(cfg *Config) {
		cfg.ObservationTimeout = 2 * time.Second
	})
	f.allocations.setHandler(f.ghostAllocation)
	ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
	defer cancel()

	_, err := f.adapter.Provision(ctx, request(), testExpiry)
	if !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("Provision error = %v, want the caller's deadline", err)
	}
	if errors.Is(err, ErrAmbiguousDispatch) {
		t.Fatal("caller cancellation was reported as the adapter's own bound")
	}
}

func TestProvisionRecoversALateCommitThroughReconcile(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	f.allocations.setHandler(func(request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		if _, err := f.commitAllocation(request); err != nil {
			return nil, err
		}
		return nil, status.Error(codes.Unavailable, "connection lost after commit")
	})

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if status.Code(err) != codes.Unavailable || !isZeroProvisioned(got) {
		t.Fatalf("Provision = %+v, %v; want the transport failure", got, err)
	}
	if f.actions("delete") != 0 {
		t.Fatal("a failed dispatch released the committed object")
	}

	recovered, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("Reconcile returned an error: %v", err)
	}
	assertAllocation(t, recovered.Allocation, "zone-1", testExpiry)
	if recovered.SecretRef != f.expectedReference("zone-1") {
		t.Fatalf("recovered SecretRef = %q, want %q", recovered.SecretRef, f.expectedReference("zone-1"))
	}
	if f.allocations.count() != 1 {
		t.Fatalf("allocation RPCs = %d, want the single dispatch", f.allocations.count())
	}
}

func TestProvisionRefusesAnObjectThatDisagreesWithTheResponse(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	f.allocations.setHandler(func(request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		response, err := f.commitAllocation(request)
		if err != nil {
			return nil, err
		}
		response.Metadata.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
			f.t, f.key, "zone-1", "uid-1", f.fingerprint, secretFor("someone-else"),
		)
		return response, nil
	})

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	assertCode(t, err, ErrInvalidResource, codes.FailedPrecondition)
	if !isZeroProvisioned(got) {
		t.Fatalf("mismatched outcome returned material: %+v", got)
	}
	if f.actions("delete") != 0 || !f.exists("zone-1") {
		t.Fatal("a mismatched response deleted the committed object")
	}
}

func TestAllocationFailureNeverObservesOrReleases(t *testing.T) {
	f := newFixture(t, nil)
	f.allocations.setHandler(func(*allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		return nil, status.Error(codes.ResourceExhausted, "pool empty")
	})

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if status.Code(err) != codes.ResourceExhausted || !isZeroProvisioned(got) {
		t.Fatalf("Provision = %+v, %v; want the allocator's refusal", got, err)
	}
	if f.actions("list") != 1 || f.actions("delete") != 0 {
		t.Fatalf("a refused dispatch performed %d lists and %d deletes", f.actions("list"), f.actions("delete"))
	}
}

func TestReconcileNeverDispatches(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))

	got, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
	assertCode(t, err, ErrAmbiguousDispatch, codes.Unavailable)
	if !isZeroProvisioned(got) {
		t.Fatalf("Reconcile returned material without a match: %+v", got)
	}
	if f.allocations.count() != 0 || f.actions("delete") != 0 {
		t.Fatalf("Reconcile dispatched %d times and deleted %d objects", f.allocations.count(), f.actions("delete"))
	}
	if f.stored("zone-1").Status.State != agonesv1.GameServerStateReady {
		t.Fatal("Reconcile consumed a pool member")
	}
}

func TestAdoptionRefusesTamperedMaterial(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*fixture, *agonesv1.GameServer)
	}{
		{
			name: "ready label rotated",
			mutate: func(_ *fixture, gs *agonesv1.GameServer) {
				gs.Labels[agones.AdmissionReadyLabel] = "v1-" + strings.Repeat("b", 52)
			},
		},
		{
			name: "key fingerprint changed",
			mutate: func(_ *fixture, gs *agonesv1.GameServer) {
				gs.Annotations[agones.AdmissionKeyAnnotation] = strings.Repeat("b", 52)
			},
		},
		{
			name: "envelope missing",
			mutate: func(_ *fixture, gs *agonesv1.GameServer) {
				delete(gs.Annotations, agones.AdmissionEnvelopeAnnotation)
			},
		},
		{
			name: "envelope sealed for another identity",
			mutate: func(f *fixture, gs *agonesv1.GameServer) {
				gs.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
					f.t, f.key, gs.Name, "uid-moved", f.fingerprint, secretFor(gs.Name),
				)
			},
		},
		{
			name: "node name missing",
			mutate: func(_ *fixture, gs *agonesv1.GameServer) {
				gs.Status.NodeName = ""
			},
		},
		{
			name: "TLS port missing",
			mutate: func(_ *fixture, gs *agonesv1.GameServer) {
				gs.Status.Ports = nil
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, nil)
			tampered := f.allocatedGameServer("zone-1", "uid-1", testAttemptID)
			test.mutate(f, tampered)
			f.seed(tampered)

			got, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
			assertCode(t, err, ErrInvalidResource, codes.FailedPrecondition)
			if !isZeroProvisioned(got) {
				t.Fatalf("tampered object yielded material: %+v", got)
			}
			if f.actions("delete") != 0 {
				t.Fatal("a tampered object was deleted rather than refused")
			}
		})
	}
}

func provisionedLease(t *testing.T, f *fixture) (nakamalease.Lease, handoffalloc.Provisioned) {
	t.Helper()
	provisioned, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("Provision returned an error: %v", err)
	}
	f.clientset.ClearActions()
	return nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		AllocationID:  provisioned.Allocation.ID,
		Observer:      provisioned.Allocation.Observer,
		SecretRef:     provisioned.SecretRef,
		ExpiresAt:     testExpiry,
	}, provisioned
}

func TestResolveReturnsTheExactDurableResource(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	lease, provisioned := provisionedLease(t, f)
	lease.Observer = sim.EntityID(84)

	got, err := f.adapter.Resolve(context.Background(), lease)
	if err != nil {
		t.Fatalf("Resolve returned an error: %v", err)
	}
	if got.ID != provisioned.Allocation.ID ||
		got.ServerName != provisioned.Allocation.ServerName ||
		got.Port != provisioned.Allocation.Port ||
		got.Observer != sim.EntityID(84) ||
		!bytes.Equal(got.AdmissionSecret, secretFor("zone-1")) ||
		!got.LeaseExpiresAt.Equal(testExpiry) {
		t.Fatalf("Resolve = %+v, want the lease's own material", got)
	}
	if f.actions("get") != 1 || f.actions("list") != 0 {
		t.Fatalf("Resolve performed %d gets and %d lists, want one exact get", f.actions("get"), f.actions("list"))
	}
	if f.allocations.count() != 1 {
		t.Fatal("Resolve dispatched an allocation")
	}
}

func TestResolveRefusesAnyChangedComponent(t *testing.T) {
	tests := []struct {
		name   string
		mutate func(*fixture, *nakamalease.Lease)
		want   error
		code   codes.Code
	}{
		{
			name: "recreated under the same name",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				f.replace(f.allocatedGameServer("zone-1", "uid-recreated", testAttemptID))
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "envelope replaced",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				gs := f.stored("zone-1").DeepCopy()
				gs.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
					f.t, f.key, "zone-1", "uid-1", f.fingerprint, secretFor("replaced"),
				)
				f.replace(gs)
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "port changed",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				gs := f.stored("zone-1").DeepCopy()
				gs.Status.Ports[0].Port = 9443
				f.replace(gs)
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "no longer Allocated",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				gs := f.stored("zone-1").DeepCopy()
				gs.Status.State = agonesv1.GameServerStateShutdown
				f.replace(gs)
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "attempt label moved",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				gs := f.stored("zone-1").DeepCopy()
				gs.Labels[agones.AttemptLabel] = attemptDigest(f.t, "attempt-8")
				f.replace(gs)
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "deleted",
			mutate: func(f *fixture, _ *nakamalease.Lease) {
				if err := f.clientset.Tracker().Delete(gameServerResource, testNamespace, "zone-1"); err != nil {
					f.t.Fatalf("delete: %v", err)
				}
			},
			want: ErrNotFound,
			code: codes.NotFound,
		},
		{
			name: "lease without a reference",
			mutate: func(_ *fixture, lease *nakamalease.Lease) {
				lease.SecretRef = ""
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
		{
			name: "lease with a foreign reference",
			mutate: func(_ *fixture, lease *nakamalease.Lease) {
				lease.SecretRef = strings.Replace(lease.SecretRef, ".p8443", ".p8444", 1)
			},
			want: ErrInvalidResource,
			code: codes.FailedPrecondition,
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, nil)
			f.seed(f.readyGameServer("zone-1", "uid-1"))
			lease, _ := provisionedLease(t, f)
			test.mutate(f, &lease)

			got, err := f.adapter.Resolve(context.Background(), lease)
			assertCode(t, err, test.want, test.code)
			if !isZeroAllocation(got) {
				t.Fatalf("Resolve returned material on a changed resource: %+v", got)
			}
			if f.actions("delete") != 0 {
				t.Fatal("Resolve repaired by deleting")
			}
		})
	}
}

func TestReleaseDeletesOnlyTheExactPinnedObject(t *testing.T) {
	t.Run("pinned lease deletes with its UID precondition", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if uids := f.deletedUIDs(); len(uids) != 1 || uids[0] != "uid-1" {
			t.Fatalf("deleted UIDs = %v, want [uid-1]", uids)
		}
		if f.exists("zone-1") {
			t.Fatal("Release left the object in place")
		}
		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("repeated Release returned an error: %v", err)
		}
	})
	t.Run("any state is releasable", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		gs := f.stored("zone-1").DeepCopy()
		gs.Status.State = agonesv1.GameServerStateShutdown
		f.replace(gs)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if f.exists("zone-1") {
			t.Fatal("Release refused a Shutdown object it owns")
		}
	})
	t.Run("a newer incarnation under the same name is untouched", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		f.replace(f.allocatedGameServer("zone-1", "uid-recreated", testAttemptID))

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if f.actions("delete") != 0 || !f.exists("zone-1") {
			t.Fatal("Release deleted an object whose UID digest the lease never pinned")
		}
	})
	t.Run("another attempt's object is untouched", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		gs := f.stored("zone-1").DeepCopy()
		gs.Labels[agones.AttemptLabel] = attemptDigest(f.t, "attempt-8")
		f.replace(gs)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if f.actions("delete") != 0 || !f.exists("zone-1") {
			t.Fatal("Release deleted a newer attempt's GameServer")
		}
	})
	t.Run("a staging lease is discovered by attempt alone", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(
			f.allocatedGameServer("zone-1", "uid-1", testAttemptID),
			f.allocatedGameServer("zone-2", "uid-2", testAttemptID),
			f.allocatedGameServer("zone-3", "uid-3", "attempt-8"),
		)

		err := f.adapter.Release(context.Background(), nakamalease.Lease{
			UserID:        testUserID,
			ReservationID: testReservationID,
			AttemptID:     testAttemptID,
			Staging:       true,
		})
		if err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		uids := f.deletedUIDs()
		if len(uids) != 2 || uids[0] == uids[1] {
			t.Fatalf("deleted UIDs = %v, want both attempt matches", uids)
		}
		if f.exists("zone-1") || f.exists("zone-2") || !f.exists("zone-3") {
			t.Fatal("attempt-only release touched the wrong objects")
		}
	})
	t.Run("absence and a lost precondition are success", func(t *testing.T) {
		for _, refusal := range []struct {
			name string
			err  error
		}{
			{name: "not found", err: apierrors.NewNotFound(gameServerResource.GroupResource(), "zone-1")},
			{name: "conflict", err: apierrors.NewConflict(gameServerResource.GroupResource(), "zone-1", errors.New("uid changed"))},
		} {
			t.Run(refusal.name, func(t *testing.T) {
				f := newFixture(t, nil)
				f.seed(f.readyGameServer("zone-1", "uid-1"))
				lease, _ := provisionedLease(t, f)
				f.clientset.PrependReactor("delete", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
					return true, nil, refusal.err
				})

				if err := f.adapter.Release(context.Background(), lease); err != nil {
					t.Fatalf("Release returned %v, want success", err)
				}
			})
		}
	})
	t.Run("another failure is reported", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		f.clientset.PrependReactor("delete", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
			return true, nil, apierrors.NewServiceUnavailable("etcd is down")
		})

		err := f.adapter.Release(context.Background(), lease)
		if err == nil || status.Code(err) != codes.Unavailable {
			t.Fatalf("Release error = %v, want a retryable Unavailable", err)
		}
	})
}

func TestObserverBindingFailuresNeverDispatch(t *testing.T) {
	tests := []struct {
		name     string
		observer func(handoff.AllocationRequest) (sim.EntityID, error)
	}{
		{
			name: "error",
			observer: func(handoff.AllocationRequest) (sim.EntityID, error) {
				return 0, errors.New("no observer")
			},
		},
		{
			name: "zero",
			observer: func(handoff.AllocationRequest) (sim.EntityID, error) {
				return 0, nil
			},
		},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, func(cfg *Config) {
				cfg.Observer = test.observer
			})
			f.seed(f.readyGameServer("zone-1", "uid-1"))

			got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
			if err == nil || !isZeroProvisioned(got) {
				t.Fatalf("Provision = %+v, %v; want refusal", got, err)
			}
			if f.allocations.count() != 0 || len(f.clientset.Actions()) != 0 {
				t.Fatal("an unbound observer reached the allocator or the API")
			}
		})
	}
}

func TestNewAdapterRefusesAnInvalidComposition(t *testing.T) {
	f := newFixture(t, nil)
	otherKey, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatalf("generate second key: %v", err)
	}
	tests := []struct {
		name   string
		mutate func(*Config)
	}{
		{name: "namespace", mutate: func(cfg *Config) { cfg.Namespace = "World" }},
		{name: "fingerprint shape", mutate: func(cfg *Config) { cfg.WrappingKeyFingerprint = "short" }},
		{name: "fingerprint not held", mutate: func(cfg *Config) { cfg.WrappingKeyFingerprint = fingerprintOf(t, otherKey) }},
		{name: "zone domain empty", mutate: func(cfg *Config) { cfg.ZoneDomain = "" }},
		{name: "zone domain is an address", mutate: func(cfg *Config) { cfg.ZoneDomain = "10.0.0.1" }},
		{name: "zone domain uppercase", mutate: func(cfg *Config) { cfg.ZoneDomain = "Zones.Example" }},
		{name: "observer", mutate: func(cfg *Config) { cfg.Observer = nil }},
		{name: "timeout too long", mutate: func(cfg *Config) { cfg.ObservationTimeout = 2 * time.Minute }},
		{name: "interval longer than timeout", mutate: func(cfg *Config) {
			cfg.ObservationTimeout = 10 * time.Millisecond
			cfg.ObservationInterval = 20 * time.Millisecond
		}},
	}
	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			cfg := f.config()
			test.mutate(&cfg)
			adapter, err := NewAdapter(f.adapter.allocator, f.adapter.resources, f.keyring, cfg)
			if err == nil || adapter != nil {
				t.Fatalf("NewAdapter(%+v) = %+v, %v; want refusal", cfg, adapter, err)
			}
		})
	}
	if _, err := NewAdapter(nil, f.adapter.resources, f.keyring, f.config()); err == nil {
		t.Fatal("NewAdapter accepted a nil allocation client")
	}
	if _, err := NewAdapter(f.adapter.allocator, nil, f.keyring, f.config()); err == nil {
		t.Fatal("NewAdapter accepted a nil resource client")
	}
	if _, err := NewAdapter(f.adapter.allocator, f.adapter.resources, nil, f.config()); err == nil {
		t.Fatal("NewAdapter accepted a nil keyring")
	}
	cfg := f.config()
	cfg.ZoneDomain = testZoneDomain + "."
	adapter, err := NewAdapter(f.adapter.allocator, f.adapter.resources, f.keyring, cfg)
	if err != nil || adapter.zoneDomain != testZoneDomain {
		t.Fatalf("a trailing dot was not normalized: %+v, %v", adapter, err)
	}
}

func TestFailuresNeverCarrySealedOrOpenedMaterial(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	envelope := f.stored("zone-1").Annotations[agones.AdmissionEnvelopeAnnotation]
	secret := secretFor("zone-1")
	lease, _ := provisionedLease(t, f)
	tampered := f.stored("zone-1").DeepCopy()
	tampered.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
		f.t, f.key, "zone-1", "uid-1", f.fingerprint, secretFor("replaced"),
	)
	f.replace(tampered)

	var failures []error
	_, err := f.adapter.Resolve(context.Background(), lease)
	failures = append(failures, err)
	_, err = f.adapter.Reconcile(context.Background(), handoff.AllocationRequest{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     "attempt-8",
	}, testExpiry)
	failures = append(failures, err)
	for _, err := range failures {
		if err == nil {
			t.Fatal("expected a failure")
		}
		text := err.Error()
		if strings.Contains(text, strings.TrimPrefix(envelope, "v1.")[:16]) ||
			strings.Contains(text, string(secret)) ||
			strings.Contains(text, base64.RawURLEncoding.EncodeToString(secret)) {
			t.Fatalf("error text leaked sealed or opened material: %q", text)
		}
	}
}

func isZeroProvisioned(provisioned handoffalloc.Provisioned) bool {
	return provisioned.SecretRef == "" && isZeroAllocation(provisioned.Allocation)
}

func isZeroAllocation(allocation handoff.Allocation) bool {
	return allocation.ID == "" &&
		allocation.ServerName == "" &&
		allocation.Port == 0 &&
		allocation.Observer == 0 &&
		len(allocation.AdmissionSecret) == 0 &&
		allocation.LeaseExpiresAt.IsZero() &&
		!allocation.RetainOnFailure
}

// ghostAllocation answers like a committed allocation whose object never
// becomes observable through the Kubernetes API.
func (f *fixture) ghostAllocation(
	request *allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error) {
	ghost := f.readyGameServer("zone-ghost", "uid-ghost")
	f.applyPatch(ghost, request)
	return responseFor(ghost), nil
}
