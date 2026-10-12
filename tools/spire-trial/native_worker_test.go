//go:build war_spire_trial && linux

package spiretrial

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"
	"sync/atomic"
	"time"

	"github.com/spiffe/go-spiffe/v2/bundle/x509bundle"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/spiffetls/tlsconfig"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

type command struct {
	Op, Address, Server, Method, Path, Credential, TrustBundle string
	DNS                                                        string
	Expiry                                                     int64
}
type response struct {
	ID, Address, Error, Code   string
	Status                     int
	Effects                    uint64
	Claimed, Receipt, Verified bool
	Version                    string
	Writes                     uint64
	Generation, Expiry         int64
}

// roleUID maps fixed diagnostic roles to disjoint users; unknown roles refuse.
func roleUID(role string) uint32 {
	switch role {
	case "supervisor":
		return 10101
	case "custodian":
		return 10102
	case "child":
		return 10103
	case "unregistered":
		return 10104
	case "zone":
		return 10105
	case "wrong-zone":
		return 10106
	case "claims":
		return 10107
	case "URI-only-claims":
		return 10108
	case "wrong-claims":
		return 10109
	default:
		return 0
	}
}

// roleID constructs the exact test-domain principal used by both independent issuers.
func roleID(role string) spiffeid.ID {
	switch role {
	case "zone":
		return spiffeid.RequireFromString("spiffe://war-fixture.test/zone/world/uid-1")
	case "wrong-zone":
		return spiffeid.RequireFromString("spiffe://war-fixture.test/zone/world/uid-2")
	case "claims":
		return spiffeid.RequireFromString("spiffe://war-fixture.test/claims/private")
	case "URI-only-claims":
		return spiffeid.RequireFromString("spiffe://war-fixture.test/claims/uri-only")
	case "wrong-claims":
		return spiffeid.RequireFromString("spiffe://war-fixture.test/claims/other")
	}
	return spiffeid.RequireFromString("spiffe://war-fixture.test/role/" + role)
}

// verifyWorker observes real UID/GID, groups, capability sets and no-new-privileges,
// then requires permission-denied access to the known-existing issuer state.
func verifyWorker(role, private string) error {
	uid := roleUID(role)
	if uid == 0 || os.Getuid() != int(uid) || os.Geteuid() != int(uid) || os.Getgid() != int(uid) || os.Getegid() != int(uid) {
		return errors.New("role did not switch to its unprivileged UID/GID")
	}
	groups, err := os.Getgroups()
	if err != nil || len(groups) != 0 {
		return errors.New("role has supplementary groups")
	}
	fields, err := statusFields()
	if err != nil {
		return err
	}
	for _, key := range []string{"CapEff", "CapPrm", "CapInh", "CapAmb"} {
		if fields[key] != "0000000000000000" {
			return errors.New("role retained a capability")
		}
	}
	if fields["NoNewPrivs"] != "1" {
		return errors.New("role did not inherit no-new-privileges")
	}
	for _, key := range []string{"Uid", "Gid"} {
		parts := strings.Fields(fields[key])
		if len(parts) != 4 {
			return errors.New("missing native role credentials")
		}
		for _, part := range parts {
			if part != strconv.FormatUint(uint64(uid), 10) {
				return errors.New("native credential did not match role UID/GID")
			}
		}
	}
	if private == "" {
		return errors.New("missing private issuer-state refusal control")
	}
	d, err := os.Open(private)
	if err == nil {
		_ = d.Close()
		return errors.New("role can open private issuer state")
	}
	if !errors.Is(err, os.ErrPermission) {
		return errors.New("private issuer-state refusal was not permission denied")
	}
	return nil
}

// runWorker fetches its own SPIRE credential before serving diagnostic mTLS.
// The unregistered user preserves a single-shot issuer refusal instead of
// turning it into a generic deadline or receiving controller-provided keys.
func runWorker(role, api, private string) int {
	out := json.NewEncoder(os.Stdout)
	fail := func(err error, code string) int {
		if out.Encode(response{Error: err.Error(), Code: code}) != nil {
			return 1
		}
		return 1
	}
	if err := verifyWorker(role, private); err != nil {
		return fail(err, "Credentials")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 8*time.Second)
	defer cancel()
	client, err := workloadapi.New(ctx, workloadapi.WithAddr("unix://"+api))
	if err != nil {
		return fail(err, status.Code(err).String())
	}
	defer func() { _ = client.Close() }()
	material, err := client.FetchX509Context(ctx)
	// The public socket can appear before the agent's first registration sync.
	// Only registered-role startup may wait for that sync; the unregistered
	// control must preserve the actual single-shot PermissionDenied verdict.
	for role != "unregistered" && err != nil && ctx.Err() == nil && (status.Code(err) == codes.PermissionDenied || status.Code(err) == codes.Unavailable) {
		select {
		case <-ctx.Done():
		case <-time.After(100 * time.Millisecond):
		}
		if ctx.Err() != nil {
			break
		}
		material, err = client.FetchX509Context(ctx)
	}
	if err != nil {
		return fail(err, status.Code(err).String())
	}
	if len(material.SVIDs) != 1 || material.DefaultSVID().ID != roleID(role) {
		return fail(errors.New("issuer did not supply the exact role principal"), "Principal")
	}
	svid := material.DefaultSVID()
	if role == "zone" || role == "wrong-zone" {
		return runClaimCaller(material, out)
	}
	if role == "claims" || role == "URI-only-claims" || role == "wrong-claims" {
		return runClaimServer(material, out)
	}
	cfg := tlsconfig.MTLSServerConfig(svid, material.Bundles, tlsconfig.AuthorizeID(roleID(expectedCaller(role))))
	cfg.MinVersion = tls.VersionTLS13
	cfg.SessionTicketsDisabled = true
	listener, err := tls.Listen("tcp", "127.0.0.1:0", cfg)
	if err != nil {
		return fail(err, "Listener")
	}
	var effects uint64
	stopHTTP := startWorkerHTTP(listener, diagnosticHandler(&effects))
	defer stopHTTP()
	return workerCommands(out, response{ID: svid.ID.String(), Address: listener.Addr().String()}, func(c command) (response, bool) {
		r := response{}
		switch c.Op {
		case "stats":
			r.Effects = atomic.LoadUint64(&effects)
		case "call":
			r = callDiagnostic(c, material)
		case "claim":
			r = callPrivateClaim(c, material)
		default:
			r.Error = "unknown private diagnostic command"
		}
		return r, false
	})
}

// callDiagnostic uses one fresh authenticated connection, the exact expected
// server and locally fetched key. Negative controls change only the specified
// key or public verifier bundle; the original credential remains private.
func callDiagnostic(c command, material *workloadapi.X509Context) response {
	// Every dial is fresh. Neither session resumption nor connection reuse can
	// satisfy a key-possession or expected-server control.
	bundles := x509bundle.Source(material.Bundles)
	if c.TrustBundle != "" {
		b, err := x509bundle.Load(spiffeid.RequireTrustDomainFromString("war-fixture.test"), c.TrustBundle)
		if err != nil {
			return response{Error: "public issuer bundle could not be loaded"}
		}
		bundles = b
	}
	cfg := tlsconfig.MTLSClientConfig(material.DefaultSVID(), bundles, tlsconfig.AuthorizeID(roleID(c.Server)))
	cfg.MinVersion = tls.VersionTLS13
	switch c.Credential {
	case "":
	case "missing":
		cfg.GetClientCertificate = func(*tls.CertificateRequestInfo) (*tls.Certificate, error) { return &tls.Certificate{}, nil }
	case "mismatched":
		wrong, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
		if err != nil {
			return response{Error: "mismatched key generation failed"}
		}
		original := cfg.GetClientCertificate
		cfg.GetClientCertificate = func(info *tls.CertificateRequestInfo) (*tls.Certificate, error) {
			cert, err := original(info)
			if err != nil {
				return nil, err
			}
			copy := *cert
			copy.PrivateKey = wrong
			return &copy, nil
		}
	default:
		return response{Error: "unknown key control"}
	}
	host, port, err := net.SplitHostPort(c.Address)
	if err != nil || host != "127.0.0.1" || port == "" {
		return response{Error: "diagnostic peer must be owned loopback"}
	}
	transport := &http.Transport{TLSClientConfig: cfg, DisableKeepAlives: true, Proxy: nil, DialContext: (&net.Dialer{Timeout: 2 * time.Second}).DialContext, TLSHandshakeTimeout: 2 * time.Second, ResponseHeaderTimeout: 2 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 3 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	request, err := http.NewRequestWithContext(ctx, c.Method, "https://"+c.Address+c.Path, nil)
	if err != nil {
		return response{Error: "invalid diagnostic request"}
	}
	result, err := client.Do(request)
	if err != nil {
		return response{Error: fmt.Sprint(err)}
	}
	if err = result.Body.Close(); err != nil {
		return response{Error: "diagnostic response close failed"}
	}
	return response{Status: result.StatusCode}
}
