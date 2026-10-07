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
	"sync"
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
		late   bool
	}
	documents := map[string]response{}
	lateStarted, releaseLate := make(chan struct{}), make(chan struct{})
	var lateOnce sync.Once
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
		if doc.late {
			lateOnce.Do(func() { close(lateStarted) })
			select {
			case <-r.Context().Done():
				return
			case <-releaseLate:
			}
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
		if mode == "positive" {
			revFields["version"] = 9
		}
		rev := signOK(t, "revocation", revFields, rootKey)
		headFields := head()
		headFields["head_url"] = headURL
		h := signOK(t, "head", headFields, rootKey)
		manifest, err := Assemble(facts, cert, rev, h, &rootKey.PublicKey, leaf, proofTime)
		if err != nil {
			t.Fatal(err)
		}
		if mode == "positive" {
			// A replay has real root/leaf signatures and a HIGHER sequence, so
			// only retained revocation knowledge can refuse it after restart.
			revFields["version"] = 4
			oldRev := signOK(t, "revocation", revFields, rootKey)
			replayFacts := parsed(t, facts)
			replayFacts["sequence"] = 99
			replay, replayErr := Assemble(rawJSON(t, replayFacts), cert, oldRev, h, &rootKey.PublicKey, leaf, proofTime)
			if replayErr != nil {
				t.Fatal(replayErr)
			}
			documents["/replay/manifest.json"] = response{body: replay, status: http.StatusOK}
			documents["/late/manifest.json"] = response{body: replay, status: http.StatusOK, late: true}
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
			// The fixture's physical parent avoids macOS's /var symlink alias.
			physical, resolveErr := filepath.EvalSymlinks(filepath.Dir(fixturePath))
			if resolveErr != nil {
				t.Fatal(resolveErr)
			}
			fixturePath = filepath.Join(physical, "public-fixture.json")
			fixtures[mode]["history_path"] = fixturePath + ".history.json"
			if err := os.WriteFile(fixturePath, rawJSON(t, fixtures[mode]), 0600); err != nil {
				t.Fatal(err)
			}
			runNativeProbe(t, fixturePath, mode)
			if mode == "positive" {
				before := nativeHistoryBytes(t, physical, "public-fixture.json.history.json")
				state := parsed(t, before)
				if state["revocation_floor"] != float64(9) || state["sequence"] != float64(42) {
					t.Fatal("native admission did not retain authenticated list knowledge")
				}
				// The same list9/head4 pair must still pass in a fresh process.
				runNativeProbe(t, fixturePath, mode)
				fixtures[mode]["accepted"] = false
				fixtures[mode]["mode"] = "retained_floor"
				fixtures[mode]["expected_error"] = "authenticated revocation list regressed below retained history"
				nativeFixtureConfig(t, fixtures[mode])["manifest_url"] = origin + "/replay/manifest.json"
				if err := os.WriteFile(fixturePath, rawJSON(t, fixtures[mode]), 0600); err != nil {
					t.Fatal(err)
				}
				runNativeProbe(t, fixturePath, "retained_floor")
				after := nativeHistoryBytes(t, physical, "public-fixture.json.history.json")
				if !bytes.Equal(before, after) {
					t.Fatal("restart replay changed retained history")
				}
			} else if _, statErr := os.Stat(fixturePath + ".history.json"); !os.IsNotExist(statErr) {
				t.Fatal("refused network control created history")
			}
			if mode == "redirect" && redirected.Load() != 0 {
				t.Fatal("redirect was followed")
			}
		})
	}
	t.Run("refusal_reason_guard", func(t *testing.T) {
		fixture := parsed(t, rawJSON(t, fixtures["expired_head"]))
		fixture["expected_error"] = "deliberately incorrect refusal reason"
		fixturePath := filepath.Join(t.TempDir(), "wrong-reason.json")
		fixture["history_path"] = fixturePath + ".history.json"
		if err := os.WriteFile(fixturePath, rawJSON(t, fixture), 0600); err != nil {
			t.Fatal(err)
		}
		ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
		defer cancel()
		out, err := nativeProbeOutput(ctx, fixturePath)
		if err == nil || ctx.Err() != nil || !bytes.Contains(out, []byte("TEST FAIL: unexpected refusal reason")) || bytes.Contains(out, []byte("SCRIPT ERROR")) {
			t.Fatalf("incorrect expected refusal reason did not fail the native proof: %v\n%s", err, out)
		}
	})
	t.Run("late_response_after_foreign_process_admission", func(t *testing.T) {
		physical, err := filepath.EvalSymlinks(t.TempDir())
		if err != nil {
			t.Fatal(err)
		}
		historyPath := filepath.Join(physical, "shared-history.json")
		lateFixture := parsed(t, rawJSON(t, fixtures["positive"]))
		lateFixture["mode"], lateFixture["accepted"], lateFixture["timeout"] = "late_floor", false, 10.0
		lateFixture["expected_error"] = "authenticated revocation list regressed below retained history"
		lateFixture["history_path"] = historyPath
		nativeFixtureConfig(t, lateFixture)["manifest_url"] = origin + "/late/manifest.json"
		latePath := filepath.Join(physical, "late.json")
		freshFixture := parsed(t, rawJSON(t, lateFixture))
		freshFixture["mode"], freshFixture["accepted"] = "positive", true
		delete(freshFixture, "expected_error")
		nativeFixtureConfig(t, freshFixture)["manifest_url"] = origin + "/positive/manifest.json"
		freshPath := filepath.Join(physical, "fresh.json")
		for path, fixture := range map[string]map[string]any{latePath: lateFixture, freshPath: freshFixture} {
			if err := os.WriteFile(path, rawJSON(t, fixture), 0600); err != nil {
				t.Fatal(err)
			}
		}
		ctx, cancel := context.WithTimeout(t.Context(), 12*time.Second)
		defer cancel()
		type nativeResult struct {
			out []byte
			err error
		}
		finished := make(chan nativeResult, 1)
		go func() {
			out, runErr := nativeProbeOutput(ctx, latePath)
			finished <- nativeResult{out: out, err: runErr}
		}()
		select {
		case <-lateStarted:
		case result := <-finished:
			t.Fatalf("late process exited before its response was held: %v\n%s", result.err, result.out)
		case <-ctx.Done():
			t.Fatal("late process never reached the native HTTPS origin")
		}
		// A separate real client admits list9 while the old list4 response is held.
		runNativeProbe(t, freshPath, "positive")
		before := nativeHistoryBytes(t, physical, "shared-history.json")
		if parsed(t, before)["revocation_floor"] != float64(9) {
			t.Fatal("foreign process did not publish its retained floor")
		}
		close(releaseLate)
		select {
		case result := <-finished:
			assertNativeProbe(t, result.out, result.err, "late_floor")
		case <-ctx.Done():
			t.Fatal("held response did not finish after release")
		}
		after := nativeHistoryBytes(t, physical, "shared-history.json")
		if !bytes.Equal(before, after) {
			t.Fatal("late response erased a different process's accepted trust")
		}
	})
}

// nativeFixtureConfig refuses malformed owned configuration before a test mutates it.
func nativeFixtureConfig(t *testing.T, fixture map[string]any) map[string]any {
	t.Helper()
	config, ok := fixture["config"].(map[string]any)
	if !ok {
		t.Fatal("owned native fixture has no configuration object")
	}
	return config
}

// nativeHistoryBytes independently reads retained history through its owned directory root.
func nativeHistoryBytes(t *testing.T, directory, name string) []byte {
	t.Helper()
	root, err := os.OpenRoot(directory)
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if closeErr := root.Close(); closeErr != nil {
			t.Errorf("owned proof directory close: %v", closeErr)
		}
	}()
	raw, err := root.ReadFile(name)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// runNativeProbe uses one fixed executable and fixed arguments. Only the owned
// public fixture path enters its environment; no content can select a command.
func runNativeProbe(t *testing.T, fixturePath, mode string) {
	t.Helper()
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	out, err := nativeProbeOutput(ctx, fixturePath)
	assertNativeProbe(t, out, err, mode)
}

// nativeProbeOutput bounds one native process and captures its explicit test verdict.
func nativeProbeOutput(ctx context.Context, fixturePath string) ([]byte, error) {
	cmd := exec.CommandContext(ctx, "godot", "--headless", "--path", "client", "--script", "res://tests/update_check_network_probe.gd")
	cmd.Dir = "../../.."
	cmd.Env = append(os.Environ(), "WAR_UPDATE_CHECK_PROBE_FILE="+fixturePath)
	return cmd.CombinedOutput()
}

// assertNativeProbe requires a successful verdict with no hidden GDScript error.
func assertNativeProbe(t *testing.T, out []byte, err error, mode string) {
	t.Helper()
	if err != nil || !bytes.Contains(out, []byte("TEST PASS")) || bytes.Contains(out, []byte("SCRIPT ERROR")) {
		t.Fatalf("native %s: %v\n%s", mode, err, out)
	}
	for line := range strings.SplitSeq(string(out), "\n") {
		expectedTLS := (mode == "system_ca" || mode == "wrong_hostname") && strings.TrimSpace(line) == "ERROR: TLS handshake error: -9984"
		if strings.Contains(line, "ERROR:") && !expectedTLS {
			t.Fatalf("unexpected native error:\n%s", out)
		}
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
