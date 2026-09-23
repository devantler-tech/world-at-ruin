package nakamaruntime

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/rsa"
	"crypto/sha256"
	"database/sql"
	"encoding/base64"
	"encoding/json"
	"errors"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/admissionref"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/nakamalease"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
	"github.com/heroiclabs/nakama-common/api"
	"github.com/heroiclabs/nakama-common/runtime"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
	apierrors "k8s.io/apimachinery/pkg/api/errors"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime/schema"
)

const moduleUser = "d95d6008-7542-4a3b-9519-0e2c9b66c50a"

type registration struct {
	runtime.Initializer
	rpc                 func(context.Context, runtime.Logger, *sql.DB, runtime.NakamaModule, string) (string, error)
	shutdown            func(context.Context, runtime.Logger, *sql.DB, runtime.NakamaModule)
	rpcErr, shutdownErr error
}

func (r *registration) RegisterRpc(id string, fn func(context.Context, runtime.Logger, *sql.DB, runtime.NakamaModule, string) (string, error)) error {
	if id != "war_handoff" {
		return errors.New("unexpected RPC")
	}
	r.rpc = fn
	return r.rpcErr
}
func (r *registration) RegisterShutdown(fn func(context.Context, runtime.Logger, *sql.DB, runtime.NakamaModule)) error {
	r.shutdown = fn
	return r.shutdownErr
}

type moduleStorage struct {
	runtime.NakamaModule
	*nakamastoragetest.Fake
}

func (*moduleStorage) AccountGetId(_ context.Context, id string) (*api.Account, error) {
	return &api.Account{User: &api.User{Id: id}}, nil
}

// Explicit methods disambiguate NakamaModule and the narrow hermetic storage.
func (s *moduleStorage) StorageRead(ctx context.Context, reads []*runtime.StorageRead) ([]*api.StorageObject, error) {
	return s.Fake.StorageRead(ctx, reads)
}
func (s *moduleStorage) StorageWrite(ctx context.Context, writes []*runtime.StorageWrite) ([]*api.StorageObjectAck, error) {
	return s.Fake.StorageWrite(ctx, writes)
}
func (s *moduleStorage) StorageDelete(ctx context.Context, deletes []*runtime.StorageDelete) error {
	return s.Fake.StorageDelete(ctx, deletes)
}
func (s *moduleStorage) StorageList(ctx context.Context, callerID, userID, collection string, limit int, cursor string) ([]*api.StorageObject, string, error) {
	return s.Fake.StorageList(ctx, callerID, userID, collection, limit, cursor)
}

type allocatorFunction struct {
	allocationpb.AllocationServiceClient
	call func(*allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error)
}

func (a allocatorFunction) Allocate(_ context.Context, request *allocationpb.AllocationRequest, _ ...grpc.CallOption) (*allocationpb.AllocationResponse, error) {
	return a.call(request)
}

func signedContext() context.Context {
	ctx := context.WithValue(context.Background(), runtime.RUNTIME_CTX_USER_ID, moduleUser)
	return context.WithValue(ctx, runtime.RUNTIME_CTX_USER_SESSION_EXP, time.Now().Add(time.Minute).Unix())
}
func environmentContext(env map[string]string) context.Context {
	return context.WithValue(context.Background(), runtime.RUNTIME_CTX_ENV, env)
}

func TestModuleHandoffPersistsReplaysAndReclaimsNoShow(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	fingerprint, err := admissionref.Fingerprint(&key.PublicKey)
	if err != nil {
		t.Fatal(err)
	}
	secret := bytes.Repeat([]byte{0xab}, 32)
	label := []byte(strings.Join([]string{"world-at-ruin/zone-admission/v1", "world-at-ruin", "zone-one", "uid-one", fingerprint}, "\x00"))
	sealed, err := rsa.EncryptOAEP(sha256.New(), rand.Reader, &key.PublicKey, secret, label)
	if err != nil {
		t.Fatal(err)
	}
	gs := &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{Namespace: "world-at-ruin", Name: "zone-one", UID: "uid-one", ResourceVersion: "1", Labels: map[string]string{agones.FleetLabel: "cave", agones.AdmissionReadyLabel: agones.AdmissionReadyValue(fingerprint)}, Annotations: map[string]string{agones.AdmissionKeyAnnotation: fingerprint, agones.AdmissionEnvelopeAnnotation: "v1." + base64.RawURLEncoding.EncodeToString(sealed)}},
		Status:     agonesv1.GameServerStatus{State: agonesv1.GameServerStateReady, NodeName: "node-a", Ports: []agonesv1.GameServerStatusPort{{Name: "tls", Port: 8443}}},
	}
	kube := agonesfake.NewSimpleClientset(gs)
	resource := schema.GroupVersionResource{Group: "agones.dev", Version: "v1", Resource: "gameservers"}
	var calls atomic.Int32
	allocator := allocatorFunction{call: func(req *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
		calls.Add(1)
		allocated := gs.DeepCopy()
		for k, v := range req.GetMetadata().GetLabels() {
			allocated.Labels[k] = v
		}
		for k, v := range req.GetMetadata().GetAnnotations() {
			allocated.Annotations[k] = v
		}
		allocated.Status.State = agonesv1.GameServerStateAllocated
		if err := kube.Tracker().Update(resource, allocated, gs.Namespace); err != nil {
			return nil, err
		}
		return &allocationpb.AllocationResponse{GameServerName: gs.Name, NodeName: "node-a", Ports: []*allocationpb.AllocationResponse_GameServerStatusPort{{Name: "tls", Port: 8443}}, Metadata: &allocationpb.AllocationResponse_GameServerMetadata{Labels: allocated.Labels, Annotations: allocated.Annotations}}, nil
	}}
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	r := &registration{}
	var closed atomic.Int32
	env := validEnvironment()
	env["WAR_HANDOFF_LEASE_TTL"] = "2s"
	initCtx, cancelInit := context.WithCancel(environmentContext(env))
	err = initialize(initCtx, storage, r, func(config) (dependencies, error) {
		return dependencies{allocator: allocator, resources: kube.AgonesV1().GameServers(gs.Namespace), keys: []*rsa.PrivateKey{key}, close: func() { closed.Add(1) }}, nil
	})
	if err != nil {
		t.Fatal(err)
	}
	if r.rpc == nil || r.shutdown == nil {
		t.Fatal("module did not register RPC and shutdown")
	}
	t.Cleanup(func() { r.shutdown(context.Background(), nil, nil, storage) })
	// Initialization's request lifetime is not the running module's lifetime.
	cancelInit()
	payload, err := r.rpc(signedContext(), nil, nil, storage, `{"reservation_id":"trip-one"}`)
	if err != nil {
		t.Fatalf("handoff: %#v; allocator calls=%d; stored=%v", err, calls.Load(), storageValues(storage.Fake))
	}
	var got handoff.Handoff
	if err := json.Unmarshal([]byte(payload), &got); err != nil {
		t.Fatal(err)
	}
	if got.ServerName != "node-a.zones.example" || got.Port != 8443 || got.Token == "" || !got.ExpiresAt.After(time.Now()) {
		t.Fatal("RPC returned no usable endpoint and token")
	}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal([]byte(payload), &fields); err != nil || len(fields) != 4 {
		t.Fatal("RPC leaked internal allocation material")
	}
	store, err := nakamalease.NewStore(storage)
	if err != nil {
		t.Fatal(err)
	}
	record, err := store.Load(context.Background(), moduleUser, "trip-one")
	if err != nil || record.Lease.Staging || record.Lease.AllocationID != "zone-one" || record.Lease.Observer != 1 {
		t.Fatalf("RPC returned before exact allocation was durable: %v", err)
	}
	verifier, err := zonesock.NewHMACVerifier(secret, "zone-one")
	if err != nil {
		t.Fatal(err)
	}
	observer, err := verifier.Verify(got.Token)
	if err != nil || observer != 1 || sim.NewDemoWorld().Get(observer) == nil {
		t.Fatalf("token cannot bind an existing zone observer: %v", err)
	}
	if _, err := r.rpc(signedContext(), nil, nil, storage, `{"reservation_id":"trip-one"}`); err != nil || calls.Load() != 1 {
		t.Fatalf("transport retry redispatched allocation: %v", err)
	}
	for _, value := range append([]string{payload}, storageValues(storage.Fake)...) {
		for _, encoded := range []string{string(secret), base64.StdEncoding.EncodeToString(secret), base64.RawURLEncoding.EncodeToString(secret)} {
			if strings.Contains(value, encoded) {
				t.Fatal("admission secret escaped into RPC or storage")
			}
		}
	}
	// A removed or unsupervised expiry loop leaves the lease and GameServer here.
	deadline := time.Now().Add(6 * time.Second)
	for len(storage.Objects()) != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if len(storage.Objects()) != 0 {
		t.Fatal("background expiry did not reclaim no-show")
	}
	if _, err := kube.Tracker().Get(resource, gs.Namespace, gs.Name); !apierrors.IsNotFound(err) {
		t.Fatal("no-show GameServer remains")
	}
	r.shutdown(context.Background(), nil, nil, storage)
	r.shutdown(context.Background(), nil, nil, storage)
	if closed.Load() != 1 {
		t.Fatal("shutdown did not close its transport exactly once")
	}
	if result, err := r.rpc(signedContext(), nil, nil, storage, `{"reservation_id":"after-stop"}`); err == nil || result != "" || calls.Load() != 1 {
		t.Fatal("stopped module accepted a handoff")
	}
}

func storageValues(storage *nakamastoragetest.Fake) []string {
	var values []string
	for _, object := range storage.Objects() {
		values = append(values, object.Value)
	}
	return values
}

func TestModuleDisabledAndInvalidStartupHaveNoSideEffects(t *testing.T) {
	for _, env := range []map[string]string{nil, {"WAR_HANDOFF_ENABLED": "false"}, {"WAR_HANDOFF_ENABLED": "true"}} {
		r := &registration{}
		called := false
		err := initialize(environmentContext(env), &moduleStorage{Fake: nakamastoragetest.New()}, r, func(config) (dependencies, error) {
			called = true
			return dependencies{}, errors.New("must not connect")
		})
		if (err != nil) != (env["WAR_HANDOFF_ENABLED"] == "true") || called || r.rpc != nil || r.shutdown != nil {
			t.Fatal("disabled or invalid initialization acquired runtime resources")
		}
	}
}

func TestRPCRejectsPayloadAuthorityAndPreservesFailureCodes(t *testing.T) {
	for _, payload := range []string{"", "null", "[]", `{}`, `{"reservation_id":null}`, `{"reservation_id":""}`, `{"reservation_id":"r","user_id":"victim"}`, `{"reservation_id":"r","session":"secret"}`, `{"reservation_id":"r","reservation_id":"r"}`, `{"Reservation_id":"r"}`, `{"reservation_id":"r"}{}`, `{"reservation_id":"bad/id"}`, strings.Repeat("x", 4097)} {
		if _, err := reservationID(payload); err == nil {
			t.Fatalf("accepted invalid RPC payload %.80q", payload)
		}
	}
	if id, err := reservationID(`{"reservation_id":"retry_1"}`); err != nil || id != "retry_1" {
		t.Fatal("refused valid stable reservation")
	}
	for _, code := range []codes.Code{codes.Canceled, codes.DeadlineExceeded, codes.InvalidArgument, codes.Unauthenticated, codes.PermissionDenied, codes.NotFound, codes.AlreadyExists, codes.ResourceExhausted, codes.FailedPrecondition, codes.Aborted, codes.Unimplemented, codes.Internal, codes.Unavailable, codes.DataLoss, codes.Unknown} {
		err := rpcError(status.Error(code, "private-key-or-token"))
		var runtimeErr *runtime.Error
		if !errors.As(err, &runtimeErr) || runtimeErr.Code != int(code) || strings.Contains(err.Error(), "private-key-or-token") {
			t.Fatalf("lost or leaked RPC error class %v", code)
		}
	}
}
