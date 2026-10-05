package fencereference

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"errors"
	"fmt"
	"go/parser"
	"go/token"
	"io/fs"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"github.com/devantler-tech/world-at-ruin/server/internal/cryptotest"
	"google.golang.org/grpc"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/credentials"
	"google.golang.org/grpc/status"
)

type certificates struct {
	server      tls.Certificate
	otherServer tls.Certificate
	client      tls.Certificate
	otherClient tls.Certificate
	roots       *x509.CertPool
}

func certificateFixture(t *testing.T) certificates {
	t.Helper()
	caKey := cryptotest.NewKey(t)
	now := time.Now()
	caTemplate := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "reference fixture CA"},
		NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER := cryptotest.Issue(t, caTemplate, caTemplate, &caKey.PublicKey, caKey)
	ca := cryptotest.Parse(t, caDER)
	roots := x509.NewCertPool()
	roots.AddCert(ca)
	issue := func(serial int64, name string, usage x509.ExtKeyUsage) tls.Certificate {
		key := cryptotest.NewKey(t)
		template := &x509.Certificate{SerialNumber: big.NewInt(serial), Subject: pkix.Name{CommonName: name},
			DNSNames: []string{name}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour),
			KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{usage}}
		der := cryptotest.Issue(t, template, ca, &key.PublicKey, caKey)
		return tls.Certificate{Certificate: [][]byte{der, caDER}, PrivateKey: key, Leaf: cryptotest.Parse(t, der)}
	}
	return certificates{server: issue(2, "allocator.test", x509.ExtKeyUsageServerAuth),
		otherServer: issue(5, "allocator.test", x509.ExtKeyUsageServerAuth),
		client:      issue(3, "coordinator.test", x509.ExtKeyUsageClientAuth),
		otherClient: issue(4, "coordinator.test", x509.ExtKeyUsageClientAuth), roots: roots}
}

type observedCredentials struct {
	credentials.TransportCredentials
	clientResults chan error
	serverResults chan error
}

func (c observedCredentials) ClientHandshake(ctx context.Context, authority string, conn net.Conn) (net.Conn, credentials.AuthInfo, error) {
	secured, info, err := c.TransportCredentials.ClientHandshake(ctx, authority, conn)
	c.clientResults <- err
	return secured, info, err
}

func (c observedCredentials) ServerHandshake(conn net.Conn) (net.Conn, credentials.AuthInfo, error) {
	secured, info, err := c.TransportCredentials.ServerHandshake(conn)
	c.serverResults <- err
	return secured, info, err
}

func (c observedCredentials) Clone() credentials.TransportCredentials {
	c.TransportCredentials = c.TransportCredentials.Clone()
	return c
}

type delayedAllocator struct {
	allocationpb.UnimplementedAllocationServiceServer
	reference    *Reference
	ticket       Ticket
	entered      chan struct{}
	resume       chan struct{}
	committed    chan error
	once         sync.Once
	lostResponse bool
}

// The generated RPC handler keeps the request alive independently of transport
// cancellation. Its ONLY mutation is Reference.Commit, after the controlled hold.
func (s *delayedAllocator) Allocate(_ context.Context, request *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
	if request.GetNamespace() != "reference-fixture" {
		return nil, status.Error(codes.InvalidArgument, "invalid fixture request")
	}
	s.once.Do(func() { close(s.entered) })
	<-s.resume
	err := s.reference.Commit(s.ticket, "actor-a", "resource-1")
	s.committed <- err
	if err != nil {
		return nil, status.Error(codes.FailedPrecondition, "reference generation closed")
	}
	if s.lostResponse {
		return nil, status.Error(codes.Unavailable, "fixture response lost")
	}
	return &allocationpb.AllocationResponse{GameServerName: "resource-1"}, nil
}

type rpcFixture struct {
	reference       *Reference
	ticket          Ticket
	server          *delayedAllocator
	client          allocationpb.AllocationServiceClient
	release         func()
	clientHandshake chan error
	serverHandshake chan error
}

func startRPC(t *testing.T, mutateClient func(*tls.Config, certificates, *Reference), lostResponse bool) rpcFixture {
	t.Helper()
	certs := certificateFixture(t)
	cfg := referenceConfig()
	cfg.ActorSPKI["actor-a"] = sha256.Sum256(certs.server.Leaf.RawSubjectPublicKeyInfo)
	cfg.ActorSPKI["actor-b"] = sha256.Sum256(certs.otherServer.Leaf.RawSubjectPublicKeyInfo)
	r, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	// Every successful RPC also proves caller mutations cannot replace the
	// authority's copied server identity after construction.
	cfg.ActorSPKI["actor-a"] = sha256.Sum256([]byte("caller replacement"))
	ticket := admit(t, r, "actor-a", "attempt-1")
	service := &delayedAllocator{reference: r, ticket: ticket, entered: make(chan struct{}), resume: make(chan struct{}),
		committed: make(chan error, 1), lostResponse: lostResponse}
	var release sync.Once
	releaseRequest := func() { release.Do(func() { close(service.resume) }) }
	t.Cleanup(releaseRequest)
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = listener.Close() })
	coordinatorKey := sha256.Sum256(certs.client.Leaf.RawSubjectPublicKeyInfo)
	serverTLS := &tls.Config{MinVersion: tls.VersionTLS13, Certificates: []tls.Certificate{certs.server},
		ClientAuth: tls.RequireAndVerifyClientCert, ClientCAs: certs.roots,
		VerifyConnection: func(state tls.ConnectionState) error {
			if len(state.VerifiedChains) == 0 || len(state.PeerCertificates) == 0 ||
				sha256.Sum256(state.PeerCertificates[0].RawSubjectPublicKeyInfo) != coordinatorKey {
				return ErrIdentity
			}
			return nil
		}}
	clientHandshake, serverHandshake := make(chan error, 16), make(chan error, 16)
	server := grpc.NewServer(grpc.Creds(observedCredentials{TransportCredentials: credentials.NewTLS(serverTLS), serverResults: serverHandshake}))
	allocationpb.RegisterAllocationServiceServer(server, service)
	t.Cleanup(server.Stop)
	go func() { _ = server.Serve(listener) }()
	base := &tls.Config{MinVersion: tls.VersionTLS13, RootCAs: certs.roots, ServerName: "allocator.test", Certificates: []tls.Certificate{certs.client}}
	clientTLS, err := r.TLSConfig("actor-a", base)
	if err != nil {
		t.Fatal(err)
	}
	if mutateClient != nil {
		mutateClient(clientTLS, certs, r)
	}
	target := "passthrough:///" + listener.Addr().String()
	conn, err := grpc.NewClient(target, grpc.WithTransportCredentials(observedCredentials{TransportCredentials: credentials.NewTLS(clientTLS), clientResults: clientHandshake}))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = conn.Close() })
	return rpcFixture{reference: r, ticket: ticket, server: service, client: allocationpb.NewAllocationServiceClient(conn), release: releaseRequest,
		clientHandshake: clientHandshake, serverHandshake: serverHandshake}
}

func awaitEntered(t *testing.T, s *delayedAllocator) {
	t.Helper()
	select {
	case <-s.entered:
	case <-time.After(3 * time.Second):
		t.Fatal("authenticated generated RPC did not reach commit hold")
	}
}

func awaitCommit(t *testing.T, s *delayedAllocator) error {
	t.Helper()
	select {
	case err := <-s.committed:
		return err
	case <-time.After(3 * time.Second):
		t.Fatal("held RPC did not attempt the commit boundary")
		return nil
	}
}

func ledgerBytes(t *testing.T, r *Reference) []byte {
	t.Helper()
	encoded, err := json.Marshal(r.Snapshot())
	if err != nil {
		t.Fatal(err)
	}
	return encoded
}

func launchHeldAllocation(t *testing.T, f rpcFixture, ctx context.Context) <-chan error {
	t.Helper()
	finished := make(chan error, 1)
	go func() {
		_, err := f.client.Allocate(ctx, &allocationpb.AllocationRequest{Namespace: "reference-fixture"})
		finished <- err
	}()
	awaitEntered(t, f.server)
	return finished
}

func TestAuthenticatedRPCOutstandingAcrossFenceCannotCommit(t *testing.T) {
	t.Parallel()
	for _, closed := range []bool{false, true} {
		t.Run(strconv.FormatBool(closed), func(t *testing.T) {
			t.Parallel()
			f := startRPC(t, nil, false)
			ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			defer cancel()
			finished := launchHeldAllocation(t, f, ctx)
			before := ledgerBytes(t, f.reference)
			var receipt Receipt
			if closed {
				receipt = fence(t, f.reference)
				if err := f.reference.Accept(receipt, f.reference.Binding()); err != nil {
					t.Fatal(err)
				}
			}
			f.release()
			commitErr := awaitCommit(t, f.server)
			rpcErr := <-finished
			if closed {
				if !errors.Is(commitErr, ErrClosed) || status.Code(rpcErr) != codes.FailedPrecondition {
					t.Fatalf("late commit=%v RPC=%v", commitErr, rpcErr)
				}
				if !bytes.Equal(before, ledgerBytes(t, f.reference)) {
					t.Fatal("accepted fence allowed a late ledger mutation")
				}
				result, err := f.reference.Resolve(f.ticket, receipt)
				if err != nil || !result.Unallocated {
					t.Fatalf("fenced resolution=%+v %v", result, err)
				}
			} else if commitErr != nil || rpcErr != nil || bytes.Equal(before, ledgerBytes(t, f.reference)) {
				t.Fatalf("unfenced positive control did not commit: %v, %v", commitErr, rpcErr)
			}
		})
	}
}

func TestCanceledRPCIsNotLossOfCommitAuthority(t *testing.T) {
	t.Parallel()
	testInterruptedRPC(t, false)
}

func TestDeadlineExpiredRPCIsNotLossOfCommitAuthority(t *testing.T) {
	t.Parallel()
	testInterruptedRPC(t, true)
}

func testInterruptedRPC(t *testing.T, deadline bool) {
	t.Helper()
	for _, closed := range []bool{false, true} {
		t.Run(strconv.FormatBool(closed), func(t *testing.T) {
			t.Parallel()
			f := startRPC(t, nil, false)
			ctx, cancel := context.WithCancel(context.Background())
			wantCode := codes.Canceled
			if deadline {
				cancel()
				ctx, cancel = context.WithTimeout(context.Background(), time.Second)
				wantCode = codes.DeadlineExceeded
			}
			defer cancel()
			finished := launchHeldAllocation(t, f, ctx)
			if !deadline {
				cancel()
			}
			select {
			case err := <-finished:
				if status.Code(err) != wantCode {
					t.Fatalf("RPC=%v", err)
				}
			case <-time.After(3 * time.Second):
				t.Fatal("canceled RPC did not return")
			}
			if _, err := f.reference.Resolve(f.ticket, Receipt{}); !errors.Is(err, ErrProof) {
				t.Fatalf("cancellation became proof: %v", err)
			}
			if _, err := f.reference.Admit("actor-a", "attempt-1"); !errors.Is(err, ErrConflict) {
				t.Fatalf("uncertain request redispatched: %v", err)
			}
			if closed {
				_ = fence(t, f.reference)
			}
			f.release()
			err := awaitCommit(t, f.server)
			if closed {
				if !errors.Is(err, ErrClosed) || len(f.reference.Snapshot()) != 0 {
					t.Fatalf("fenced canceled RPC mutated: %v", err)
				}
			} else if err != nil || len(f.reference.Snapshot()) != 1 {
				t.Fatalf("canceled transport falsely stopped server commit: %v", err)
			}
		})
	}
}

func TestLostRPCResponseRetainsTheCommittedAllocation(t *testing.T) {
	t.Parallel()
	f := startRPC(t, nil, true)
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	finished := launchHeldAllocation(t, f, ctx)
	f.release()
	if err := awaitCommit(t, f.server); err != nil {
		t.Fatal(err)
	}
	if err := <-finished; status.Code(err) != codes.Unavailable {
		t.Fatalf("lost response=%v", err)
	}
	result, err := f.reference.Resolve(f.ticket, fence(t, f.reference))
	if err != nil || result.Unallocated || result.Allocation.ResourceUID != "resource-1" {
		t.Fatalf("lost response discarded commit: %+v %v", result, err)
	}
}

func TestWrongAllocatorIdentityNeverReachesCommit(t *testing.T) {
	t.Parallel()
	for _, name := range []string{"wrong key", "wrong hostname", "untrusted CA", "missing coordinator certificate", "wrong coordinator key"} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			f := startRPC(t, func(config *tls.Config, certs certificates, authority *Reference) {
				switch name {
				case "wrong key":
					safe, err := authority.TLSConfig("actor-b", config)
					if err != nil {
						t.Fatal(err)
					}
					config.VerifyConnection = safe.VerifyConnection
				case "wrong hostname":
					config.ServerName = "replacement.test"
				case "untrusted CA":
					config.RootCAs = x509.NewCertPool()
				case "missing coordinator certificate":
					config.Certificates = nil
				case "wrong coordinator key":
					config.Certificates = []tls.Certificate{certs.otherClient}
				}
			}, false)
			ctx, cancel := context.WithTimeout(context.Background(), 250*time.Millisecond)
			defer cancel()
			if _, err := f.client.Allocate(ctx, &allocationpb.AllocationRequest{Namespace: "reference-fixture"}); err == nil {
				t.Fatal("wrong actor authenticated")
			}
			results := f.clientHandshake
			if name == "missing coordinator certificate" || name == "wrong coordinator key" {
				results = f.serverHandshake
			}
			select {
			case err := <-results:
				var hostname x509.HostnameError
				var unknownCA x509.UnknownAuthorityError
				refused := (name == "wrong key" || name == "wrong coordinator key") && errors.Is(err, ErrIdentity) ||
					name == "wrong hostname" && errors.As(err, &hostname) ||
					name == "untrusted CA" && errors.As(err, &unknownCA) ||
					name == "missing coordinator certificate" && err != nil && strings.Contains(err.Error(), "client didn't provide a certificate")
				if !refused {
					t.Fatalf("no observed identity refusal for %s: %v", name, err)
				}
			case <-time.After(time.Second):
				t.Fatal("identity test never observed a TLS handshake")
			}
			select {
			case <-f.server.entered:
				t.Fatal("wrong TLS identity reached allocator mutation")
			default:
			}
			if len(f.reference.Snapshot()) != 0 {
				t.Fatal("wrong TLS identity mutated")
			}
		})
	}
}

func TestReferenceIsNotComposedIntoProduction(t *testing.T) {
	t.Parallel()
	if err := checkProductionComposition(filepath.Join("..", "..")); err != nil {
		t.Fatal(err)
	}
}

func checkProductionComposition(root string) error {
	entrypoints := map[string]bool{
		filepath.Join("cmd", "zone", "main.go"):        false,
		filepath.Join("cmd", "nakama", "main.go"):      false,
		filepath.Join("nakamaruntime", "module.go"):    false,
		filepath.Join("agonesresources", "adapter.go"): false,
	}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if _, expected := entrypoints[relative]; expected {
			entrypoints[relative] = true
		}
		return rejectReferenceImport(path, nil)
	})
	if err != nil {
		return err
	}
	for path, seen := range entrypoints {
		if !seen {
			return fmt.Errorf("production composition guard did not examine %s", path)
		}
	}
	return nil
}

func TestCompositionGuardRequiresTheActualProductionEntrypoints(t *testing.T) {
	t.Parallel()
	paths := []string{"cmd/zone/main.go", "cmd/nakama/main.go", "nakamaruntime/module.go", "agonesresources/adapter.go"}
	for _, missing := range append([]string{""}, paths...) {
		t.Run(missing, func(t *testing.T) {
			t.Parallel()
			root := t.TempDir()
			for _, path := range paths {
				if path == missing {
					continue
				}
				target := filepath.Join(root, filepath.FromSlash(path))
				if err := os.MkdirAll(filepath.Dir(target), 0700); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(target, []byte("package fixture\n"), 0600); err != nil {
					t.Fatal(err)
				}
			}
			err := checkProductionComposition(root)
			if missing == "" && err != nil {
				t.Fatalf("complete production walk refused: %v", err)
			}
			if missing != "" && (err == nil || !strings.Contains(err.Error(), filepath.FromSlash(missing))) {
				t.Fatalf("missing production entrypoint %s was not detected: %v", missing, err)
			}
		})
	}
}

func rejectReferenceImport(path string, text any) error {
	source, err := parser.ParseFile(token.NewFileSet(), path, text, parser.ImportsOnly)
	if err != nil {
		return err
	}
	for _, imported := range source.Imports {
		decoded, err := strconv.Unquote(imported.Path.Value)
		if err != nil {
			return err
		}
		if decoded == "github.com/devantler-tech/world-at-ruin/server/internal/fencereference" {
			return errors.New("reference commit authority imported into production")
		}
	}
	return nil
}

func TestCompositionGuardRecognizesEveryImportSpelling(t *testing.T) {
	t.Parallel()
	path := "github.com/devantler-tech/world-at-ruin/server/internal/fencereference"
	for _, literal := range []string{strconv.Quote(path), "`" + path + "`", "\"\\x67" + path[1:] + "\""} {
		for _, alias := range []string{"", "renamed ", ". ", "_ "} {
			if err := rejectReferenceImport("fixture.go", "package fixture\nimport "+alias+literal); err == nil {
				t.Fatalf("composition guard accepted %s%s", alias, literal)
			}
		}
	}
	if err := rejectReferenceImport("fixture.go", "package fixture\nimport \"fmt\""); err != nil {
		t.Fatalf("unrelated import refused: %v", err)
	}
}
