package nakamaruntime

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"math/big"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	allocationpb "agones.dev/agones/pkg/allocation/go"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
)

type tlsAllocationServer struct {
	allocationpb.UnimplementedAllocationServiceServer
}

func (*tlsAllocationServer) Allocate(context.Context, *allocationpb.AllocationRequest) (*allocationpb.AllocationResponse, error) {
	return &allocationpb.AllocationResponse{GameServerName: "verified-mtls"}, nil
}

func writeMaterial(t *testing.T, dir, name string, data []byte) string {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, data, 0600); err != nil {
		t.Fatal(err)
	}
	return path
}

func certificateFixture(t *testing.T, dir string) (config, tls.Certificate, *x509.CertPool) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	pool := x509.NewCertPool()
	pool.AppendCertsFromPEM(caPEM)
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), DNSNames: []string{"localhost"}, NotBefore: ca.NotBefore, NotAfter: ca.NotAfter, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageClientAuth, x509.ExtKeyUsageServerAuth}}
	der, err := x509.CreateCertificate(rand.Reader, leaf, ca, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der})
	keyDER, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	cfg := config{allocatorAddress: "localhost:443", allocatorCA: writeMaterial(t, dir, "ca.pem", caPEM), allocatorCert: writeMaterial(t, dir, "client.pem", certPEM), allocatorKey: writeMaterial(t, dir, "client-key.pem", keyPEM)}
	return cfg, certificate, pool
}

func TestAllocatorConnectionUsesVerifiedMutualTLS(t *testing.T) {
	cfg, certificate, pool := certificateFixture(t, t.TempDir())
	listener, err := (&net.ListenConfig{}).Listen(context.Background(), "tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	_, port, err := net.SplitHostPort(listener.Addr().String())
	if err != nil {
		t.Fatal(err)
	}
	cfg.allocatorAddress = net.JoinHostPort("localhost", port)
	server := grpc.NewServer(grpc.Creds(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{certificate}, ClientCAs: pool, ClientAuth: tls.RequireAndVerifyClientCert})))
	allocationpb.RegisterAllocationServiceServer(server, &tlsAllocationServer{})
	go func() { _ = server.Serve(listener) }()
	t.Cleanup(server.Stop)
	t.Cleanup(func() { _ = listener.Close() })
	client, closeClient, err := connectAllocator(cfg)
	if err != nil {
		t.Fatal(err)
	}
	defer closeClient()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	got, err := client.Allocate(ctx, &allocationpb.AllocationRequest{})
	if err != nil || got.GetGameServerName() != "verified-mtls" {
		t.Fatalf("mutually authenticated gRPC request failed: %v", err)
	}
	// Credentials the peer rejects must fail startup, before the RPC can accept
	// a request whose first dispatch would then be quarantined as ambiguous.
	other, _, _ := certificateFixture(t, t.TempDir())
	untrustedServer := cfg
	untrustedServer.allocatorCA = other.allocatorCA
	untrustedClient := cfg
	untrustedClient.allocatorCert, untrustedClient.allocatorKey = other.allocatorCert, other.allocatorKey
	for name, broken := range map[string]config{"untrusted server": untrustedServer, "untrusted client": untrustedClient} {
		if _, closeBroken, err := connectAllocator(broken); err == nil {
			closeBroken()
			t.Fatalf("%s: startup accepted an unverifiable allocator connection", name)
		}
	}
}

func TestTransportRefusesInvalidOrUnboundedMaterial(t *testing.T) {
	dir := t.TempDir()
	cfg, _, _ := certificateFixture(t, dir)
	for _, data := range [][]byte{[]byte("private-material"), []byte(strings.Repeat("x", 1024*1024+1))} {
		bad := writeMaterial(t, dir, "private-material-path", data)
		for _, field := range []string{"ca", "cert", "key"} {
			broken := cfg
			switch field {
			case "ca":
				broken.allocatorCA = bad
			case "cert":
				broken.allocatorCert = bad
			case "key":
				broken.allocatorKey = bad
			}
			_, closeClient, err := connectAllocator(broken)
			if err == nil {
				closeClient()
				t.Fatal("accepted invalid TLS material")
			}
			if strings.Contains(err.Error(), "private-material") {
				t.Fatal("TLS failure exposed material or path")
			}
		}
		if _, err := readPrivateKey(bad); err == nil || strings.Contains(err.Error(), "private-material") {
			t.Fatal("unwrap key failure was not sanitized")
		}
	}
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	for _, kind := range []string{"pkcs1", "pkcs8"} {
		block := &pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(key)}
		if kind == "pkcs8" {
			block.Type = "PRIVATE KEY"
			block.Bytes, err = x509.MarshalPKCS8PrivateKey(key)
			if err != nil {
				t.Fatal(err)
			}
		}
		path := writeMaterial(t, dir, kind, pem.EncodeToMemory(block))
		got, err := readPrivateKey(path)
		if err != nil || got.N.Cmp(key.N) != 0 {
			t.Fatalf("retained unwrap key not read: %v", err)
		}
	}
}
