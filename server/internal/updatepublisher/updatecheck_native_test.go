package updatepublisher

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/json"
	"encoding/pem"
	"math/big"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// TestNativeUpdateCheck exercises actual Godot HTTPRequest against a loopback
// TLS listener. Explicit opt-in avoids starting native tools in ordinary Go tests.
func TestNativeUpdateCheck(t *testing.T) {
	if os.Getenv("WAR_UPDATE_CHECK_PROOF") != "1" {
		t.Skip("native HTTPS proof requires WAR_UPDATE_CHECK_PROOF=1")
	}
	t.Run("malformed_fixture", func(t *testing.T) {
		fixturePath := filepath.Join(t.TempDir(), "malformed.json")
		if err := os.WriteFile(fixturePath, []byte("[]"), 0600); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
		defer cancel()
		cmd := exec.CommandContext(ctx, "godot", "--headless", "--path", "client", "--script", "res://tests/update_check_network_probe.gd")
		cmd.Dir = "../../.."
		cmd.Env = append(os.Environ(), "WAR_UPDATE_CHECK_PROBE_FILE="+fixturePath)
		out, err := cmd.CombinedOutput()
		if err == nil || ctx.Err() != nil || !bytes.Contains(out, []byte("TEST FAIL: native update fixture")) || bytes.Contains(out, []byte("SCRIPT ERROR")) {
			t.Fatalf("malformed fixture did not terminate with an explicit refusal: %v\n%s", err, out)
		}
	})
	rootKey, leaf := newKey(t), newKey(t)
	tlsCert, ca := nativeTLS(t)
	type response struct {
		body   []byte
		status int
		delay  bool
	}
	documents := map[string]response{}
	var redirected atomic.Int64
	listener := httptest.NewUnstartedServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path == "/redirect-target" {
			redirected.Add(1)
		}
		doc, ok := documents[r.URL.Path]
		if !ok {
			http.NotFound(w, r)
			return
		}
		if doc.delay {
			select {
			case <-r.Context().Done():
				return
			case <-time.After(3 * time.Second):
			}
		}
		if doc.status == http.StatusFound {
			w.Header().Set("Location", "/redirect-target")
		}
		w.WriteHeader(doc.status)
		if _, err := w.Write(doc.body); err != nil && r.Context().Err() == nil {
			t.Errorf("fixture response: %v", err)
		}
	}))
	listener.TLS = &tls.Config{Certificates: []tls.Certificate{tlsCert}, MinVersion: tls.VersionTLS12}
	listener.Config.ReadHeaderTimeout = 2 * time.Second
	listener.StartTLS()
	t.Cleanup(listener.Close)
	origin := strings.Replace(listener.URL, "127.0.0.1", "localhost", 1)
	facts, installedRaw := buildFacts(t)
	var installed map[string]any
	if err := json.Unmarshal(installedRaw, &installed); err != nil {
		t.Fatal(err)
	}
	modes := []string{"positive", "disabled", "unsafe", "override", "system_ca", "wrong_hostname", "altered", "raised_floor", "expired_head", "revoked", "missing_head", "status", "redirect", "oversized", "truncated", "deadline", "cancel", "detach", "slow_clock"}
	fixtures := map[string]map[string]any{}
	for _, mode := range modes {
		headURL := origin + "/" + mode + "/head.json"
		cert := signOK(t, "certificate", certificate(t, &leaf.PublicKey, 7), rootKey)
		revFields := revocation()
		revFields["head_url"] = headURL
		rev := signOK(t, "revocation", revFields, rootKey)
		headFields := head()
		headFields["head_url"] = headURL
		h := signOK(t, "head", headFields, rootKey)
		manifest, err := Assemble(facts, cert, rev, h, &rootKey.PublicKey, leaf, proofTime)
		if err != nil {
			t.Fatal(err)
		}
		switch mode {
		case "raised_floor":
			headFields["version_floor"] = 5
			h = signOK(t, "head", headFields, rootKey)
		case "expired_head":
			headFields["not_after"] = "2030-01-14T23:59:59Z"
			h, err = signObject(headFields, "root_signature", rootKey)
		case "revoked":
			revFields["revoked_ids"] = []string{"leaf-2030"}
			rev = signOK(t, "revocation", revFields, rootKey)
			m := parsed(t, manifest)
			delete(m, "signature")
			m["revocation"] = parsed(t, rev)
			manifest, err = signObject(m, "signature", leaf)
		case "altered":
			m := parsed(t, manifest)
			m["sequence"] = 99
			manifest, err = encode(m)
		}
		if err != nil {
			t.Fatal(err)
		}
		manifestPath, headPath := "/"+mode+"/manifest.json", "/"+mode+"/head.json"
		mResponse := response{body: manifest, status: http.StatusOK}
		switch mode {
		case "status":
			mResponse.status = http.StatusServiceUnavailable
		case "redirect":
			mResponse.status = http.StatusFound
		case "oversized":
			mResponse.body = bytes.Repeat([]byte("x"), MaxDocumentBytes+1)
		case "truncated":
			mResponse.body = manifest[:len(manifest)/2]
		case "deadline", "cancel", "detach":
			mResponse.delay = true
		}
		documents[manifestPath] = mResponse
		if mode != "missing_head" {
			documents[headPath] = response{body: h, status: http.StatusOK}
		}
		manifestURL := origin + manifestPath
		if mode == "wrong_hostname" {
			manifestURL = listener.URL + manifestPath
		}
		timeout := 2.0
		if mode == "deadline" {
			timeout = 0.2
		}
		fixtures[mode] = map[string]any{"mode": mode, "accepted": mode == "positive", "timeout": timeout,
			"tls_ca": string(ca), "installed": installed, "observed_at": proofTime.Format(time.RFC3339),
			"config": map[string]any{"channel": "live", "manifest_url": manifestURL, "revocation_head_url": headURL, "root_public_key": publicPEM(t, &rootKey.PublicKey)}}
	}
	for _, mode := range modes {
		t.Run(mode, func(t *testing.T) {
			fixturePath := filepath.Join(t.TempDir(), "public-fixture.json")
			if err := os.WriteFile(fixturePath, rawJSON(t, fixtures[mode]), 0600); err != nil {
				t.Fatal(err)
			}
			ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, "godot", "--headless", "--path", "client", "--script", "res://tests/update_check_network_probe.gd")
			cmd.Dir = "../../.."
			cmd.Env = append(os.Environ(), "WAR_UPDATE_CHECK_PROBE_FILE="+fixturePath)
			out, err := cmd.CombinedOutput()
			if err != nil || !bytes.Contains(out, []byte("TEST PASS")) || bytes.Contains(out, []byte("SCRIPT ERROR")) {
				t.Fatalf("native %s: %v\n%s", mode, err, out)
			}
			// Godot emits a native TLS diagnostic for deliberately invalid chains.
			// Only those two transport controls may emit that exact error class.
			for line := range strings.SplitSeq(string(out), "\n") {
				expectedTLS := (mode == "system_ca" || mode == "wrong_hostname") && strings.TrimSpace(line) == "ERROR: TLS handshake error: -9984"
				if strings.Contains(line, "ERROR:") && !expectedTLS {
					t.Fatalf("unexpected native error:\n%s", out)
				}
			}
			if mode == "redirect" && redirected.Load() != 0 {
				t.Fatal("redirect was followed")
			}
		})
	}
}

// nativeTLS creates an ephemeral CA and localhost-only leaf. No production key
// is read, and the wrong-host control uses the same trusted CA with another name.
func nativeTLS(t *testing.T) (tls.Certificate, []byte) {
	t.Helper()
	caKey, serverKey := newKey(t), newKey(t)
	now := time.Now()
	ca := &x509.Certificate{SerialNumber: big.NewInt(1), Subject: pkix.Name{CommonName: "World at Ruin test CA"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), IsCA: true, BasicConstraintsValid: true, KeyUsage: x509.KeyUsageCertSign}
	caDER, err := x509.CreateCertificate(rand.Reader, ca, ca, &caKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	leaf := &x509.Certificate{SerialNumber: big.NewInt(2), Subject: pkix.Name{CommonName: "localhost"}, NotBefore: now.Add(-time.Hour), NotAfter: now.Add(time.Hour), DNSNames: []string{"localhost"}, KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}}
	leafDER, err := x509.CreateCertificate(rand.Reader, leaf, ca, &serverKey.PublicKey, caKey)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalPKCS8PrivateKey(serverKey)
	if err != nil {
		t.Fatal(err)
	}
	caPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: caDER})
	certPEM := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: leafDER})
	certPEM = append(certPEM, caPEM...)
	keyPEM := pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: keyDER})
	cert, err := tls.X509KeyPair(certPEM, keyPEM)
	if err != nil {
		t.Fatal(err)
	}
	return cert, caPEM
}
