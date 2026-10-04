package updatepublisher

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/x509"
	"encoding/json"
	"encoding/pem"
	"os"
	"strings"
	"testing"
	"time"
)

var proofTime = time.Date(2030, 1, 15, 0, 0, 0, 0, time.UTC)

const proofURL = "https://updates.worldatruin.example/live/revocation-head.json"

// newKey creates ephemeral test keys without borrowing operator credentials.
func newKey(t *testing.T) *ecdsa.PrivateKey {
	t.Helper()
	k, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return k
}

// publicPEM exposes only a fixture key's public half for independent verifier tests.
func publicPEM(t *testing.T, k *ecdsa.PublicKey) string {
	t.Helper()
	b, err := x509.MarshalPKIXPublicKey(k)
	if err != nil {
		t.Fatal(err)
	}
	return string(pem.EncodeToMemory(&pem.Block{Type: "PUBLIC KEY", Bytes: b}))
}

// rawJSON serializes fixture facts before the production parser examines them.
func rawJSON(t *testing.T, v any) []byte {
	t.Helper()
	b, err := json.Marshal(v)
	if err != nil {
		t.Fatal(err)
	}
	return b
}

// parsed lets tests alter signed facts and prove independent readback refusal.
func parsed(t *testing.T, b []byte) map[string]any {
	t.Helper()
	var v map[string]any
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	return v
}

// certificate creates a public leaf fixture with an explicit rotation epoch.
func certificate(t *testing.T, k *ecdsa.PublicKey, epoch int) map[string]any {
	t.Helper()
	return map[string]any{"algorithm": "ecdsa-p256-sha256", "public_key": publicPEM(t, k), "id": "leaf-2030", "epoch": epoch, "not_before": "2030-01-01T00:00:00Z", "not_after": "2030-02-01T00:00:00Z"}
}

// revocation builds endpoint-bound test lists, including empty lists.
func revocation(ids ...string) map[string]any {
	if ids == nil {
		ids = []string{}
	}
	return map[string]any{"version": 4, "head_url": proofURL, "revoked_ids": ids}
}

// head models an independently retained floor with a short validity budget.
func head() map[string]any {
	return map[string]any{"head_url": proofURL, "version_floor": 4, "not_after": "2030-01-15T00:30:00Z"}
}

// signOK requires the real issuer to accept fixtures before downstream tests use them.
func signOK(t *testing.T, kind string, v any, k *ecdsa.PrivateKey) []byte {
	t.Helper()
	got, err := SignDocument(kind, rawJSON(t, v), k, proofTime)
	if err != nil {
		t.Fatalf("%s issue: %v", kind, err)
	}
	return got
}

// buildFacts retains client metadata while issuing a fresh bounded expiry.
func buildFacts(t *testing.T) ([]byte, json.RawMessage) {
	t.Helper()
	b, err := os.ReadFile("../../../client/tests/data/update_trust_chain_vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v struct {
		Manifest  map[string]any
		Installed json.RawMessage
	}
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	delete(v.Manifest, "key")
	delete(v.Manifest, "revocation")
	delete(v.Manifest, "signature")
	delete(v.Manifest, "key_epoch")
	v.Manifest["not_after"] = "2030-01-15T12:00:00Z"
	return rawJSON(t, v.Manifest), v.Installed
}

// TestIssuedCertificateValidatesAndRejectsUnsupportedInputs refuses malformed certified leaves.
func TestIssuedCertificateValidatesAndRejectsUnsupportedInputs(t *testing.T) {
	root, leaf := newKey(t), newKey(t)
	valid := signOK(t, "certificate", certificate(t, &leaf.PublicKey, 7), root)
	if err := VerifyDocument("certificate", valid, &root.PublicKey, proofTime); err != nil {
		t.Fatal(err)
	}
	for _, change := range []func(map[string]any){func(v map[string]any) { v["epoch"] = 0 }, func(v map[string]any) { v["epoch"] = 1.5 }, func(v map[string]any) { v["id"] = "" }, func(v map[string]any) { v["algorithm"] = "rsa" }, func(v map[string]any) { v["not_after"] = "2030-01-01T00:00:00Z" }, func(v map[string]any) { v["not_before"] = "2030-02-01T00:00:00Z" }, func(v map[string]any) { v["root_signature"] = "old" }} {
		v := certificate(t, &leaf.PublicKey, 7)
		change(v)
		if _, err := SignDocument("certificate", rawJSON(t, v), root, proofTime); err == nil {
			t.Error("malformed certificate issued")
		}
	}
	other, err := ecdsa.GenerateKey(elliptic.P384(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := SignDocument("certificate", rawJSON(t, certificate(t, &other.PublicKey, 7)), root, proofTime); err == nil {
		t.Fatal("wrong curve issued")
	}
}

// TestRevocationAndFreshHeadProduction exercises signed freshness and endpoint controls.
func TestRevocationAndFreshHeadProduction(t *testing.T) {
	root := newKey(t)
	for _, kind := range []string{"revocation", "head"} {
		var v map[string]any
		if kind == "revocation" {
			v = revocation()
		} else {
			v = head()
		}
		signed := signOK(t, kind, v, root)
		if err := VerifyDocument(kind, signed, &root.PublicKey, proofTime); err != nil {
			t.Fatal(err)
		}
		altered := parsed(t, signed)
		altered["head_url"] = proofURL + "/foreign"
		if err := VerifyDocument(kind, rawJSON(t, altered), &root.PublicKey, proofTime); err == nil {
			t.Fatal("changed document verified")
		}
	}
	for _, v := range []map[string]any{revocation("same", "same"), revocation(""), {"version": -1, "head_url": proofURL, "revoked_ids": []string{}}, {"version": 4, "head_url": "http://insecure.example/head", "revoked_ids": []string{}}} {
		if _, err := SignDocument("revocation", rawJSON(t, v), root, proofTime); err == nil {
			t.Fatal("invalid revocation issued")
		}
	}
	for _, expiry := range []string{"2030-01-14T00:00:00Z", "2030-01-16T00:00:01Z", "2030-02-31T00:00:00Z"} {
		v := head()
		v["not_after"] = expiry
		if _, err := SignDocument("head", rawJSON(t, v), root, proofTime); err == nil {
			t.Fatal("unbounded, expired or invalid head issued")
		}
	}
}

// TestBundleAssemblyAndIndependentReadback emits authentic native-client controls.
func TestBundleAssemblyAndIndependentReadback(t *testing.T) {
	root, leaf := newKey(t), newKey(t)
	cert := signOK(t, "certificate", certificate(t, &leaf.PublicKey, 7), root)
	rev := signOK(t, "revocation", revocation(), root)
	h := signOK(t, "head", head(), root)
	facts, installed := buildFacts(t)
	bundle, err := Assemble(facts, cert, rev, h, &root.PublicKey, leaf, proofTime)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyBundle(bundle, h, &root.PublicKey, proofTime); err != nil {
		t.Fatal(err)
	}
	for _, field := range []string{"sequence", "key", "revocation", "signature"} {
		altered := parsed(t, bundle)
		altered[field] = "altered"
		if err := VerifyBundle(rawJSON(t, altered), h, &root.PublicKey, proofTime); err == nil {
			t.Errorf("altered %s verified", field)
		}
	}
	if err := VerifyBundle(bundle, h, &newKey(t).PublicKey, proofTime); err == nil {
		t.Fatal("foreign root accepted")
	}
	revoked := signOK(t, "revocation", revocation("leaf-2030"), root)
	oldHead := head()
	oldHead["version_floor"] = 5
	raised := signOK(t, "head", oldHead, root)
	foreignHead := head()
	foreignHead["head_url"] = proofURL + "/canary"
	foreign := signOK(t, "head", foreignHead, root)
	for _, inputs := range []struct {
		rev, h []byte
		leaf   *ecdsa.PrivateKey
	}{{revoked, h, leaf}, {rev, raised, leaf}, {rev, foreign, leaf}, {rev, nil, leaf}, {rev, h, newKey(t)}} {
		if _, err := Assemble(facts, cert, inputs.rev, inputs.h, &root.PublicKey, inputs.leaf, proofTime); err == nil {
			t.Fatal("untrusted chain signed")
		}
	}
	if err := VerifyBundle(bundle, h, &root.PublicKey, proofTime.Add(time.Hour)); err == nil {
		t.Fatal("expired independent head accepted")
	}
	// This optional output is public test evidence, never a key or production root.
	if dir := os.Getenv("WAR_PUBLISHER_PROOF_DIR"); dir != "" {
		proofRoot, err := os.OpenRoot(dir)
		if err != nil {
			t.Fatal(err)
		}
		t.Cleanup(func() {
			if err := proofRoot.Close(); err != nil {
				t.Error(err)
			}
		})
		write := func(name string, raw []byte) {
			file, err := proofRoot.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
			if err != nil {
				t.Fatal(err)
			}
			_, writeErr := file.Write(raw)
			closeErr := file.Close()
			if writeErr != nil || closeErr != nil {
				t.Fatalf("proof write: %v %v", writeErr, closeErr)
			}
		}
		// Negative fixtures remain fully signed. Only test code bypasses the
		// issuer's refusal to assemble a revoked or expired chain.
		badManifest := parsed(t, bundle)
		badManifest["revocation"] = parsed(t, revoked)
		delete(badManifest, "signature")
		revokedBundle, err := signObject(badManifest, "signature", leaf)
		if err != nil {
			t.Fatal(err)
		}
		expired := head()
		expired["not_after"] = "2030-01-14T23:59:59Z"
		expiredSigned, err := SignDocument("head", rawJSON(t, expired), root, proofTime.Add(-time.Hour))
		if err != nil {
			t.Fatal(err)
		}
		proof := map[string]any{"manifest": parsed(t, bundle), "head": parsed(t, h), "root_public_key": publicPEM(t, &root.PublicKey), "installed": installed, "revoked_manifest": parsed(t, revokedBundle), "raised_head": parsed(t, raised), "expired_head": parsed(t, expiredSigned)}
		write("chain.json", rawJSON(t, proof))
		for name, doc := range map[string]any{"certificate-input.json": certificate(t, &leaf.PublicKey, 7), "revocation-input.json": revocation(), "head-input.json": head(), "raised-head-input.json": oldHead} {
			write(name, rawJSON(t, doc))
		}
		write("build-facts.json", facts)
		write("root-public.pem", []byte(publicPEM(t, &root.PublicKey)))
		for name, key := range map[string]*ecdsa.PrivateKey{"root-private.pem": root, "leaf-private.pem": leaf} {
			der, err := x509.MarshalPKCS8PrivateKey(key)
			if err != nil {
				t.Fatal(err)
			}
			write(name, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: der}))
		}
	}
}

// TestExistingClientTrustVectorVerifies preserves historical verification windows.
func TestExistingClientTrustVectorVerifies(t *testing.T) {
	b, err := os.ReadFile("../../../client/tests/data/update_trust_chain_vector.json")
	if err != nil {
		t.Fatal(err)
	}
	var v map[string]json.RawMessage
	if err := json.Unmarshal(b, &v); err != nil {
		t.Fatal(err)
	}
	pub, err := os.ReadFile("../../../client/tests/data/update_trust_chain_root_public.pem")
	if err != nil {
		t.Fatal(err)
	}
	root, err := ParsePublicKey(pub)
	if err != nil {
		t.Fatal(err)
	}
	if err := VerifyBundle(v["manifest"], v["revocation_head"], root, proofTime); err != nil {
		t.Fatal(err)
	}
}

// TestNewManifestExpiryIsBoundedAndLeafRotationWorks bounds lifetime across rotation.
func TestNewManifestExpiryIsBoundedAndLeafRotationWorks(t *testing.T) {
	root, leaf := newKey(t), newKey(t)
	cert := signOK(t, "certificate", certificate(t, &leaf.PublicKey, 8), root)
	rev := signOK(t, "revocation", revocation(), root)
	h := signOK(t, "head", head(), root)
	facts, _ := buildFacts(t)
	if _, err := Assemble(facts, cert, rev, h, &root.PublicKey, leaf, proofTime); err != nil {
		t.Fatal(err)
	}
	m := parsed(t, facts)
	m["not_after"] = "2030-01-16T00:00:01Z"
	if _, err := Assemble(rawJSON(t, m), cert, rev, h, &root.PublicKey, leaf, proofTime); err == nil {
		t.Fatal("fresh manifest exceeded 24-hour publication TTL")
	}
}

// TestPrivateKeyParsingNeverEchoesMaterial protects private diagnostic contents.
func TestPrivateKeyParsingNeverEchoesMaterial(t *testing.T) {
	if _, err := ParsePrivateKey([]byte("PRIVATE_SENTINEL_SECRET")); err == nil || strings.Contains(err.Error(), "PRIVATE_SENTINEL_SECRET") {
		t.Fatal("private-key parse leaked or accepted material")
	}
}
