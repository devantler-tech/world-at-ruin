package main

import (
	"bytes"
	"context"
	"errors"
	"net"
	"path/filepath"
	"strings"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/handoffidentity"
	"github.com/devantler-tech/world-at-ruin/server/nakamaruntime"
	"github.com/spiffe/go-spiffe/v2/spiffeid"
	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc"
)

// issuedClaimsMaterial is a single startup fetch, never a credential watcher.
// Only this experimental entry imports the SDK. The fixed runtime initializer
// independently validates the inspectable chain, signer and trust separation.
func issuedClaimsMaterial(parent context.Context, env map[string]string) (*nakamaruntime.ClaimsTLSMaterial, error) {
	switch env["WAR_ISSUED_CLAIMS_ENABLED"] {
	case "", "false":
		return nil, nil
	case "true":
	default:
		return nil, errors.New("issued claims enablement refused")
	}
	probe := env["WAR_ISSUED_SDK_PROBE_ENABLED"]
	if env["WAR_HANDOFF_ENABLED"] != "true" || env["WAR_HANDOFF_CLAIMS_ENABLED"] != "true" || probe != "" && probe != "false" {
		return nil, errors.New("issued claims mode refused")
	}
	socket := env["WAR_ISSUED_CLAIMS_SOCKET"]
	dns := env["WAR_ISSUED_CLAIMS_SERVER_DNS"]
	expected, err := spiffeid.FromString(env["WAR_ISSUED_CLAIMS_SERVER_URI"])
	if err != nil || expected.TrustDomain().String() != env["WAR_HANDOFF_CLAIMS_TRUST_DOMAIN"] || !handoffidentity.DNSSubdomain(dns) || net.ParseIP(dns) != nil || !filepath.IsAbs(socket) || filepath.Clean(socket) != socket || len(socket) > 100 || strings.ContainsAny(socket, "\x00\r\n?#%") {
		return nil, errors.New("issued claims configuration refused")
	}
	if parent.Err() != nil {
		return nil, errors.New("issued claims startup canceled")
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	client, err := workloadapi.New(ctx, workloadapi.WithAddr("unix://"+socket),
		workloadapi.WithDialOptions(grpc.WithDefaultCallOptions(grpc.MaxCallRecvMsgSize(256*1024))))
	if err != nil {
		return nil, errors.New("issued claims SDK construction refused")
	}
	material, requestErr := client.FetchX509Context(ctx)
	closeErr := client.Close()
	if closeErr != nil {
		return nil, errors.New("issued claims SDK cleanup unknown")
	}
	if requestErr != nil || ctx.Err() != nil {
		return nil, errors.New("issued claims WorkloadAPI request refused")
	}
	if material == nil || len(material.SVIDs) != 1 || material.SVIDs[0] == nil || material.Bundles == nil {
		return nil, errors.New("issued claims credential selection refused")
	}
	svid := material.SVIDs[0]
	if svid.ID != expected || svid.PrivateKey == nil || len(svid.Certificates) == 0 {
		return nil, errors.New("issued claims identity refused")
	}
	bundle, err := material.Bundles.GetX509BundleForTrustDomain(expected.TrustDomain())
	if err != nil || len(bundle.X509Authorities()) == 0 {
		return nil, errors.New("issued claims trust bundle refused")
	}
	result := &nakamaruntime.ClaimsTLSMaterial{Signer: svid.PrivateKey, ExpectedServerDNS: dns, ExpectedServerURI: expected.String()}
	for _, certificate := range svid.Certificates {
		result.CertificateChainDER = append(result.CertificateChainDER, bytes.Clone(certificate.Raw))
	}
	for _, authority := range bundle.X509Authorities() {
		result.ClientAuthoritiesDER = append(result.ClientAuthoritiesDER, bytes.Clone(authority.Raw))
	}
	return result, nil
}
