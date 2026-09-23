package nakamaruntime

import (
	allocationpb "agones.dev/agones/pkg/allocation/go"
	agonesclient "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"bytes"
	"crypto/rsa"
	"crypto/tls"
	"crypto/x509"
	"encoding/pem"
	"errors"
	"google.golang.org/grpc"
	"google.golang.org/grpc/credentials"
	"io"
	"k8s.io/client-go/rest"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"time"
)

var errMaterial = errors.New("nakama handoff: invalid key or certificate material")

func connectRuntime(cfg config) (dependencies, error) {
	var deps dependencies
	for _, path := range cfg.unwrapKeys {
		key, err := readPrivateKey(path)
		if err != nil {
			return dependencies{}, err
		}
		deps.keys = append(deps.keys, key)
	}
	kubeConfig, err := rest.InClusterConfig()
	if err != nil {
		return dependencies{}, errors.New("nakama handoff: in-cluster configuration required")
	}
	kubeConfig.Timeout = 10 * time.Second
	client, err := rest.HTTPClientFor(kubeConfig)
	if err != nil {
		return dependencies{}, errors.New("nakama handoff: Kubernetes transport unavailable")
	}
	client.CheckRedirect = func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }
	kube, err := agonesclient.NewForConfigAndClient(kubeConfig, client)
	if err != nil {
		client.CloseIdleConnections()
		return dependencies{}, errors.New("nakama handoff: GameServer client unavailable")
	}
	deps.resources = kube.GameServers(cfg.namespace)
	allocator, closeAllocator, err := connectAllocator(cfg)
	if err != nil {
		client.CloseIdleConnections()
		return dependencies{}, err
	}
	deps.allocator = allocator
	deps.close = func() { closeAllocator(); client.CloseIdleConnections() }
	return deps, nil
}

func connectAllocator(cfg config) (allocationpb.AllocationServiceClient, func(), error) {
	ca, err := readMaterial(cfg.allocatorCA)
	if err != nil {
		return nil, nil, errMaterial
	}
	pool := x509.NewCertPool()
	if !pool.AppendCertsFromPEM(ca) {
		return nil, nil, errMaterial
	}
	certPEM, err := readMaterial(cfg.allocatorCert)
	if err != nil {
		return nil, nil, errMaterial
	}
	keyPEM, err := readMaterial(cfg.allocatorKey)
	if err != nil {
		return nil, nil, errMaterial
	}
	certificate, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		return nil, nil, errMaterial
	}
	leaf, err := x509.ParseCertificate(certificate.Certificate[0])
	if err != nil || time.Now().Before(leaf.NotBefore) || !time.Now().Before(leaf.NotAfter) {
		return nil, nil, errMaterial
	}
	host, _, err := net.SplitHostPort(cfg.allocatorAddress)
	if err != nil {
		return nil, nil, errMaterial
	}
	conn, err := grpc.NewClient("dns:///"+cfg.allocatorAddress,
		grpc.WithTransportCredentials(credentials.NewTLS(&tls.Config{MinVersion: tls.VersionTLS12, RootCAs: pool, ServerName: host, Certificates: []tls.Certificate{certificate}})),
		grpc.WithDisableRetry(),
		grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(4*1024*1024)),
	)
	if err != nil {
		return nil, nil, errors.New("nakama handoff: allocator transport unavailable")
	}
	return allocationpb.NewAllocationServiceClient(conn), func() { _ = conn.Close() }, nil
}

func readPrivateKey(path string) (*rsa.PrivateKey, error) {
	data, err := readMaterial(path)
	if err != nil {
		return nil, errMaterial
	}
	block, rest := pem.Decode(data)
	if block == nil || len(bytes.TrimSpace(rest)) != 0 {
		return nil, errMaterial
	}
	var key *rsa.PrivateKey
	switch block.Type {
	case "RSA PRIVATE KEY":
		key, err = x509.ParsePKCS1PrivateKey(block.Bytes)
	case "PRIVATE KEY":
		var parsed any
		parsed, err = x509.ParsePKCS8PrivateKey(block.Bytes)
		key, _ = parsed.(*rsa.PrivateKey)
	default:
		return nil, errMaterial
	}
	if err != nil || key == nil || key.N.BitLen() < 3072 || key.Validate() != nil {
		return nil, errMaterial
	}
	return key, nil
}

func readMaterial(path string) ([]byte, error) {
	clean := filepath.Clean(path)
	file, err := os.DirFS(filepath.Dir(clean)).Open(filepath.Base(clean))
	if err != nil {
		return nil, errMaterial
	}
	defer func() { _ = file.Close() }()
	data, err := io.ReadAll(io.LimitReader(file, 1024*1024+1))
	if err != nil || len(data) == 0 || len(data) > 1024*1024 {
		return nil, errMaterial
	}
	return data, nil
}
