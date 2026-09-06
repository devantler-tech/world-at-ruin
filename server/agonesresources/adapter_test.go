package agonesresources

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
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

// testPrivateKey generates one shared wrapping key for hermetic envelope tests.
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

// fingerprintOf derives the canonical wrapping-key fingerprint the fixture's
// allocation selector and sealed GameServer metadata carry.
func fingerprintOf(t *testing.T, key *rsa.PrivateKey) string {
	t.Helper()
	fingerprint, err := admissionref.Fingerprint(&key.PublicKey)
	if err != nil {
		t.Fatalf("fingerprint test key: %v", err)
	}
	return fingerprint
}

// secretFor is the admission secret the fixture seals for one GameServer name,
// distinct per object so a test can prove which envelope was opened.
func secretFor(name string) []byte {
	digest := sha256.Sum256([]byte("admission:" + name))
	return digest[:]
}

// sealedEnvelope encrypts a fixture secret with the exact namespace, name, UID
// and fingerprint binding expected by the production admission keyring.
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

// Allocate records each real gRPC dispatch and invokes the configured fixture
// handler under a mutex so concurrent requests remain observable in order.
func (s *allocationServer) Allocate(
	_ context.Context,
	request *allocationpb.AllocationRequest,
) (*allocationpb.AllocationResponse, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls = append(s.calls, request)
	return s.handle(request)
}

// count returns the recorded dispatch count under the server's mutex.
func (s *allocationServer) count() int {
	s.mu.Lock()
	defer s.mu.Unlock()
	return len(s.calls)
}

// setHandler replaces the allocation behavior without racing an active request.
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

// newFixture composes the real allocation gRPC client, fake GameServer API and
// keyring, with optional adapter configuration changes and test-owned cleanup.
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

// config binds the fixture's namespace, wrapping key, zone domain and observer
// with short observation windows that keep timeout tests bounded.
func (f *fixture) config() Config {
	return Config{
		ZoneDomain: testZoneDomain,
		Observer: func(handoff.AllocationRequest) (sim.EntityID, error) {
			return testObserver, nil
		},
		ObservationTimeout:  150 * time.Millisecond,
		ObservationInterval: 2 * time.Millisecond,
	}
}

// request supplies the stable user, reservation and attempt used by fixtures.
func request() handoff.AllocationRequest {
	return handoff.AllocationRequest{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
	}
}

// attemptDigest derives the production correlation label for fixture metadata.
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
				agones.AdmissionReadyLabel: agones.AdmissionReadyValue(f.fingerprint),
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

// allocatedGameServer turns an envelope-ready fixture into an Allocated object
// carrying the supplied attempt and the fixture's reservation correlation.
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

// replace swaps a tracker object without recording fixture writes as adapter
// API calls, allowing tests to model recreation or changed metadata.
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

// stored reads a required GameServer directly from the fixture tracker and
// fails the test if it is absent or has an unexpected resource type.
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

// exists reports whether the fixture tracker can still read the named object.
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

// selectReady chooses a Ready fixture matching every requested selector,
// returning an independent copy or the allocator's exhausted-pool status.
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

// applyPatch copies allocation-request labels and annotations to the selected
// fixture and transitions its state to Allocated.
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

// responseFor builds an allocation response from an observed GameServer with
// detached ports, labels and annotations for response-tampering tests.
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

// actions counts adapter API calls of one verb, excluding direct tracker setup.
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

// expectedReference derives the durable reference from the fixture's stored
// object so adapter results can be compared with the admission boundary.
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

// assertAllocation verifies the returned object, DNS endpoint, observer,
// opened secret, expiry and failure-retention flag against the fixture.
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

// assertCode checks sentinel identity and gRPC classification both directly
// and after an additional error wrapper.
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

// TestProvisionDispatchesOnceAndOpensTheSealedEnvelope verifies one allocation
// RPC, exact correlation metadata and usable secret material without cleanup.
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

// TestProvisionAdoptsTheAttemptsGameServerWithoutRedispatch verifies that
// provision replay and reconciliation reuse the first allocation and reference.
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

// TestDuplicateMatchesAreReleasedByTheirOwnUIDAndFailClosed checks both entry
// points delete each duplicate by its own UID without consuming another server.
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

// TestProvisionReportsAnUnobservableDispatchAsAmbiguous checks bounded
// observation retries and ensures later reconciliation neither deletes nor
// reissues an allocation that may still commit.
func TestProvisionReportsAnUnobservableDispatchAsAmbiguous(t *testing.T) {
	f := newFixture(t, nil)
	f.allocations.setHandler(f.ghostAllocation())

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

// TestProvisionReportsCallerCancellationAsCancellation distinguishes the
// caller's deadline from expiry of the adapter's longer observation budget.
func TestProvisionReportsCallerCancellationAsCancellation(t *testing.T) {
	f := newFixture(t, func(cfg *Config) {
		cfg.ObservationTimeout = 2 * time.Second
	})
	f.allocations.setHandler(f.ghostAllocation())
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

// TestProvisionRecoversALateCommitThroughReconcile preserves an allocation
// committed before a lost response and recovers it without redispatch or delete.
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

// TestProvisionRefusesAnObjectThatDisagreesWithTheResponse refuses mismatched
// envelope evidence without exposing material or deleting the committed server.
func TestProvisionRefusesAnObjectThatDisagreesWithTheResponse(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	// Sealed on the test's own goroutine: t.Fatalf may only be called there,
	// and the handler below runs on the gRPC server's.
	foreignEnvelope := sealedEnvelope(
		f.t, f.key, "zone-1", "uid-1", f.fingerprint, secretFor("someone-else"),
	)
	f.allocations.setHandler(func(request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		response, err := f.commitAllocation(request)
		if err != nil {
			return nil, err
		}
		response.Metadata.Annotations[agones.AdmissionEnvelopeAnnotation] = foreignEnvelope
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

// TestAllocationFailureNeverObservesOrReleases checks that allocator refusal
// ends provisioning after its initial discovery, with no cleanup or material.
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

// TestReconcileNeverDispatches leaves a Ready pool member untouched when no
// allocated object matches the attempt, reporting only an ambiguous outcome.
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

// TestAdoptionRefusesTamperedMaterial checks metadata, identity-bound envelope,
// node and port refusals without returning secrets or deleting the object.
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

// provisionedLease builds a durable lease from a successful provision and
// clears recorded API calls so subsequent resolve or release actions stand out.
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

// TestResolveReturnsTheExactDurableResource checks a single exact-name read
// restores the secret while preserving the durable lease's observer and expiry.
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

// TestResolveRefusesAnyChangedComponent verifies that changed resource or lease
// evidence returns no allocation material and never triggers repair by deletion.
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

// TestReleaseDeletesOnlyTheExactPinnedObject checks UID-precondition cleanup,
// harmless repeats, staging discovery and refusal to delete another owner,
// while retaining retryable API failures.
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

// TestObserverBindingFailuresNeverDispatch ensures binding errors and the zero
// entity are rejected before any allocator or GameServer API call.
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

// TestNewAdapterRefusesAnInvalidComposition checks dependency, key and timing
// validation, plus normalization of case and a trailing dot in the zone domain.
func TestNewAdapterRefusesAnInvalidComposition(t *testing.T) {
	f := newFixture(t, nil)
	tests := []struct {
		name   string
		mutate func(*Config)
	}{
		{name: "zone domain empty", mutate: func(cfg *Config) { cfg.ZoneDomain = "" }},
		{name: "zone domain is an address", mutate: func(cfg *Config) { cfg.ZoneDomain = "10.0.0.1" }},
		{name: "zone domain malformed", mutate: func(cfg *Config) { cfg.ZoneDomain = "zones_example" }},
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
	foreign, err := admissionref.NewKeyring(previousPrivateKey(t))
	if err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	if _, err := NewAdapter(f.adapter.allocator, f.adapter.resources, foreign, f.config()); err == nil {
		t.Fatal("NewAdapter accepted a keyring that cannot open the pool the allocator selects")
	}
	cfg := f.config()
	cfg.ZoneDomain = "Zones.Example."
	adapter, err := NewAdapter(f.adapter.allocator, f.adapter.resources, f.keyring, cfg)
	if err != nil || adapter.zoneDomain != testZoneDomain {
		t.Fatalf("case and a trailing dot were not normalized like the handoff service: %+v, %v", adapter, err)
	}
}

// TestFailuresNeverCarrySealedOrOpenedMaterial checks representative resolve
// and reconciliation errors for leaked ciphertext or raw and encoded secrets.
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

// isZeroProvisioned requires an empty durable reference and no allocation data
// so failure-path tests detect accidentally returned connection material.
func isZeroProvisioned(provisioned handoffalloc.Provisioned) bool {
	return provisioned.SecretRef == "" && isZeroAllocation(provisioned.Allocation)
}

// isZeroAllocation checks every connection and lease field for its empty value.
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
// becomes observable through the Kubernetes API. The response is built once on
// the caller's goroutine — sealing calls t.Fatalf, which may only run on the
// test's own goroutine, never the gRPC server's.
func (f *fixture) ghostAllocation() allocationHandler {
	ghost := f.readyGameServer("zone-ghost", "uid-ghost")
	return func(request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		patched := ghost.DeepCopy()
		f.applyPatch(patched, request)
		return responseFor(patched), nil
	}
}

var (
	previousKeyOnce sync.Once
	previousKey     *rsa.PrivateKey
	previousKeyErr  error
)

// previousPrivateKey generates one independent wrapping key for rotation tests.
func previousPrivateKey(t *testing.T) *rsa.PrivateKey {
	t.Helper()
	previousKeyOnce.Do(func() {
		previousKey, previousKeyErr = rsa.GenerateKey(rand.Reader, 3072)
	})
	if previousKeyErr != nil {
		t.Fatalf("generate previous RSA test key: %v", previousKeyErr)
	}
	return previousKey
}

// allocatedUnder is an Allocated attempt object sealed under an arbitrary
// key, as a pool member allocated before a rotation still is.
func (f *fixture) allocatedUnder(
	key *rsa.PrivateKey,
	name string,
	uid types.UID,
) *agonesv1.GameServer {
	fingerprint := fingerprintOf(f.t, key)
	gameServer := f.allocatedGameServer(name, uid, testAttemptID)
	gameServer.Labels[agones.AdmissionReadyLabel] = agones.AdmissionReadyValue(fingerprint)
	gameServer.Annotations[agones.AdmissionKeyAnnotation] = fingerprint
	gameServer.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
		f.t, key, name, uid, fingerprint, secretFor(name),
	)
	return gameServer
}

// TestARetainedPreviousKeyStillResolvesAndReleases checks that a pre-rotation
// object can be adopted, resolved and deleted without any new allocation RPC.
func TestARetainedPreviousKeyStillResolvesAndReleases(t *testing.T) {
	f := newFixture(t, nil)
	previous := previousPrivateKey(t)
	keyring, err := admissionref.NewKeyring(previous, f.key)
	if err != nil {
		t.Fatalf("NewKeyring: %v", err)
	}
	adapter, err := NewAdapter(f.adapter.allocator, f.adapter.resources, keyring, f.config())
	if err != nil {
		t.Fatalf("NewAdapter: %v", err)
	}
	f.seed(f.allocatedUnder(previous, "zone-old", "uid-old"))

	adopted, err := adapter.Reconcile(context.Background(), request(), testExpiry)
	if err != nil {
		t.Fatalf("Reconcile refused an object sealed under the retained key: %v", err)
	}
	assertAllocation(t, adopted.Allocation, "zone-old", testExpiry)
	if !strings.HasPrefix(adopted.SecretRef, "v1.k"+fingerprintOf(t, previous)+".") {
		t.Fatalf("SecretRef %q does not pin the previous key", adopted.SecretRef)
	}
	lease := nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		AllocationID:  "zone-old",
		Observer:      testObserver,
		SecretRef:     adopted.SecretRef,
		ExpiresAt:     testExpiry,
	}
	resolved, err := adapter.Resolve(context.Background(), lease)
	if err != nil {
		t.Fatalf("Resolve refused the retained key: %v", err)
	}
	assertAllocation(t, resolved, "zone-old", testExpiry)
	if err := adapter.Release(context.Background(), lease); err != nil {
		t.Fatalf("Release refused the retained key: %v", err)
	}
	if f.exists("zone-old") {
		t.Fatal("Release left the pre-rotation object in place")
	}
	if f.allocations.count() != 0 {
		t.Fatal("a retained-key object caused a dispatch")
	}
}

// TestAKeyTheKeyringNoLongerHoldsIsRefusedButStillReleasable checks that a retired
// key blocks secret recovery while attempt-only cleanup can still remove its
// object without needing the retired private key.
func TestAKeyTheKeyringNoLongerHoldsIsRefusedButStillReleasable(t *testing.T) {
	f := newFixture(t, nil)
	retired := previousPrivateKey(t)
	f.seed(f.allocatedUnder(retired, "zone-retired", "uid-retired"))

	got, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
	assertCode(t, err, ErrInvalidResource, codes.FailedPrecondition)
	if !isZeroProvisioned(got) {
		t.Fatalf("a retired key yielded material: %+v", got)
	}
	if f.actions("delete") != 0 {
		t.Fatal("a retired key caused a delete during reconciliation")
	}

	err = f.adapter.Release(context.Background(), nakamalease.Lease{
		UserID:        testUserID,
		ReservationID: testReservationID,
		AttemptID:     testAttemptID,
		Staging:       true,
	})
	if err != nil || f.exists("zone-retired") {
		t.Fatalf("attempt-only release left the retired-key object: %v", err)
	}
}

// TestReleaseProvesOwnershipByUIDAlone checks that release proves ownership
// what the lease pinned — UID digest and envelope digest — without demanding
// the state, port, node or key that adoption needs, so an object Agones has
// moved on from, or one sealed under a key the keyring no longer holds, is
// still deleted; while a re-sealed object under the same UID is left alone.
func TestReleaseProvesOwnershipByUIDAlone(t *testing.T) {
	t.Run("port-less object is still deleted", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		gs := f.stored("zone-1").DeepCopy()
		gs.Status.State = agonesv1.GameServerStateShutdown
		gs.Status.Ports = nil
		gs.Status.NodeName = ""
		f.replace(gs)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if uids := f.deletedUIDs(); len(uids) != 1 || uids[0] != "uid-1" {
			t.Fatalf("deleted UIDs = %v, want [uid-1]", uids)
		}
		if f.exists("zone-1") {
			t.Fatal("Release orphaned an owned object because its port was gone")
		}
	})
	t.Run("retired key object is still deleted by its lease", func(t *testing.T) {
		f := newFixture(t, nil)
		retired := previousPrivateKey(t)
		f.seed(f.allocatedUnder(retired, "zone-retired", "uid-retired"))
		reference, err := admissionref.Reference(admissionref.Material{
			Namespace:              testNamespace,
			GameServerName:         "zone-retired",
			GameServerUID:          "uid-retired",
			WrappingKeyFingerprint: fingerprintOf(t, retired),
			AdmissionEnvelope:      f.stored("zone-retired").Annotations[agones.AdmissionEnvelopeAnnotation],
			TLSPort:                testTLSPort,
		})
		if err != nil {
			t.Fatalf("Reference: %v", err)
		}

		err = f.adapter.Release(context.Background(), nakamalease.Lease{
			UserID:        testUserID,
			ReservationID: testReservationID,
			AttemptID:     testAttemptID,
			AllocationID:  "zone-retired",
			Observer:      testObserver,
			SecretRef:     reference,
			ExpiresAt:     testExpiry,
		})
		if err != nil || f.exists("zone-retired") {
			t.Fatalf("Release refused an object whose key was retired: %v", err)
		}
	})
	t.Run("re-sealed object under the same UID is still deleted", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		gs := f.stored("zone-1").DeepCopy()
		gs.Annotations[agones.AdmissionEnvelopeAnnotation] = sealedEnvelope(
			f.t, f.key, "zone-1", "uid-1", f.fingerprint, secretFor("re-sealed"),
		)
		f.replace(gs)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if uids := f.deletedUIDs(); len(uids) != 1 || uids[0] != "uid-1" {
			t.Fatalf("deleted UIDs = %v, want [uid-1]", uids)
		}
		if f.exists("zone-1") {
			t.Fatal("a zone that rewrote its own envelope vetoed its own cleanup")
		}
	})
	t.Run("object with no envelope at all is still deleted", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		gs := f.stored("zone-1").DeepCopy()
		delete(gs.Annotations, agones.AdmissionEnvelopeAnnotation)
		f.replace(gs)

		if err := f.adapter.Release(context.Background(), lease); err != nil {
			t.Fatalf("Release returned an error: %v", err)
		}
		if f.exists("zone-1") {
			t.Fatal("an unreadable envelope was mistaken for someone else's object")
		}
	})
	t.Run("a lease naming an allocation with no reference fails closed", func(t *testing.T) {
		f := newFixture(t, nil)
		f.seed(f.readyGameServer("zone-1", "uid-1"))
		lease, _ := provisionedLease(t, f)
		lease.SecretRef = ""

		if err := f.adapter.Release(context.Background(), lease); !errors.Is(err, ErrInvalidResource) {
			t.Fatalf("Release error = %v, want ErrInvalidResource", err)
		}
		if f.actions("delete") != 0 || !f.exists("zone-1") {
			t.Fatal("Release deleted on an unpinned read")
		}
	})
}

// TestAStaleObjectNeverPoisonsTheAttempt checks that an attempt-labelled
// GameServer Agones has moved on from — the shape a crashed zone leaves behind,
// which keeps its labels until the object is collected — neither blocks
// adopting the attempt's live allocation nor blocks the attempt-only cleanup
// path. Refusing the whole listing over such a leftover would make a live
// attempt permanently unadoptable and its lease immortal.
func TestAStaleObjectNeverPoisonsTheAttempt(t *testing.T) {
	t.Run("adoption ignores it", func(t *testing.T) {
		f := newFixture(t, nil)
		stale := f.allocatedGameServer("zone-stale", "uid-stale", testAttemptID)
		stale.Status.State = agonesv1.GameServerStateShutdown
		stale.Status.Ports = nil
		f.seed(stale, f.allocatedGameServer("zone-live", "uid-live", testAttemptID))

		got, err := f.adapter.Reconcile(context.Background(), request(), testExpiry)
		if err != nil {
			t.Fatalf("Reconcile refused a live attempt over a stale leftover: %v", err)
		}
		assertAllocation(t, got.Allocation, "zone-live", testExpiry)
		if f.actions("delete") != 0 {
			t.Fatal("a stale leftover was mistaken for a duplicate and deleted")
		}
	})
	t.Run("attempt-only release deletes it", func(t *testing.T) {
		f := newFixture(t, nil)
		stale := f.allocatedGameServer("zone-stale", "uid-stale", testAttemptID)
		stale.Status.State = agonesv1.GameServerStateShutdown
		stale.Status.Ports = nil
		f.seed(stale, f.allocatedGameServer("zone-live", "uid-live", testAttemptID))

		err := f.adapter.Release(context.Background(), nakamalease.Lease{
			UserID:        testUserID,
			ReservationID: testReservationID,
			AttemptID:     testAttemptID,
			Staging:       true,
		})
		if err != nil {
			t.Fatalf("attempt-only Release returned an error: %v", err)
		}
		if f.exists("zone-stale") || f.exists("zone-live") {
			t.Fatal("attempt-only Release left an object behind")
		}
	})
}

// TestATransientAPIFailureStaysRetryable checks that a failure which never
// reached a server verdict — the shape client-go returns for a refused
// connection or a TLS error, which carries no APIStatus and so matches none of
// the reason predicates — is reported as retryable rather than as a permanent
// contract refusal a caller must not retry.
func TestATransientAPIFailureStaysRetryable(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
		want codes.Code
	}{
		{name: "transport", err: errors.New("dial tcp 10.0.0.1:443: connect: connection refused"), want: codes.Unavailable},
		{name: "server timeout", err: apierrors.NewServerTimeout(gameServerResource.GroupResource(), "get", 1), want: codes.Unavailable},
		{name: "too many requests", err: apierrors.NewTooManyRequestsError("slow down"), want: codes.Unavailable},
		{name: "forbidden", err: apierrors.NewForbidden(gameServerResource.GroupResource(), "zone-1", errors.New("rbac")), want: codes.FailedPrecondition},
	} {
		t.Run(test.name, func(t *testing.T) {
			f := newFixture(t, nil)
			f.seed(f.readyGameServer("zone-1", "uid-1"))
			lease, _ := provisionedLease(t, f)
			f.clientset.PrependReactor("get", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
				return true, nil, test.err
			})

			_, err := f.adapter.Resolve(context.Background(), lease)
			if status.Code(err) != test.want {
				t.Fatalf("Resolve code = %s, want %s (err %v)", status.Code(err), test.want, err)
			}
		})
	}
}

// TestObservationDoesNotLaunderAHardFailure checks that a read which will not
// resolve by waiting is returned as itself instead of being retried for the
// whole budget and reported as an ambiguous dispatch — the outcome that
// quarantines an attempt permanently and would name the wrong cause.
func TestObservationDoesNotLaunderAHardFailure(t *testing.T) {
	f := newFixture(t, nil)
	f.seed(f.readyGameServer("zone-1", "uid-1"))
	f.clientset.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, runtime.Object, error) {
		return true, nil, apierrors.NewForbidden(gameServerResource.GroupResource(), "", errors.New("rbac"))
	})

	got, err := f.adapter.Provision(context.Background(), request(), testExpiry)
	if errors.Is(err, ErrAmbiguousDispatch) {
		t.Fatal("a permanent read failure was laundered into an ambiguous dispatch")
	}
	assertCode(t, err, ErrInvalidResource, codes.FailedPrecondition)
	if !isZeroProvisioned(got) {
		t.Fatalf("a refused read returned material: %+v", got)
	}
	if f.allocations.count() != 0 {
		t.Fatal("a refused pre-dispatch read still dispatched an allocation")
	}
}

// TestNewAdapterRefusesClientsNamingDifferentPools checks the composition
// cross-check: two independently configured clients that disagree about the
// pool would otherwise allocate against one and reconcile against another,
// leaking a GameServer per attempt with no runtime symptom.
func TestNewAdapterRefusesClientsNamingDifferentPools(t *testing.T) {
	f := newFixture(t, nil)
	other, err := gameserverapi.NewClient(
		f.clientset.AgonesV1().GameServers(testNamespace),
		gameserverapi.Config{
			Namespace:   testNamespace,
			Fleet:       "other-zone",
			TLSPortName: testTLSPortName,
		},
	)
	if err != nil {
		t.Fatalf("NewClient: %v", err)
	}
	if adapter, err := NewAdapter(f.adapter.allocator, other, f.keyring, f.config()); err == nil || adapter != nil {
		t.Fatalf("NewAdapter accepted clients naming different Fleets: %+v, %v", adapter, err)
	}
}
