package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
)

func testDigest(data []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(data)) }
func testJSON(value any) []byte {
	data, err := json.Marshal(value)
	if err != nil {
		panic(err)
	}
	return data
}

// baseFixture supplies a complete offline chain, not a pre-approved verdict.
func baseFixture(t *testing.T) (string, map[string]any) {
	t.Helper()
	root := t.TempDir()
	directory := filepath.Join(root, ".github", "containers")
	if err := os.MkdirAll(directory, 0700); err != nil {
		t.Fatal(err)
	}
	config := testJSON(map[string]any{"os": "linux", "architecture": "amd64"})
	descriptor := func(media string, raw []byte) map[string]any {
		return map[string]any{"mediaType": media, "digest": testDigest(raw), "size": len(raw)}
	}
	manifest := testJSON(map[string]any{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.manifest.v1+json", "config": descriptor("application/vnd.oci.image.config.v1+json", config), "layers": []any{descriptor("application/vnd.oci.image.layer.v1.tar+gzip", []byte("layer"))}})
	child := descriptor("application/vnd.oci.image.manifest.v1+json", manifest)
	child["platform"] = map[string]any{"os": "linux", "architecture": "amd64"}
	index := testJSON(map[string]any{"schemaVersion": 2, "mediaType": "application/vnd.oci.image.index.v1+json", "manifests": []any{child}})
	sources := map[string]any{"schema": 1, "bases": []any{
		map[string]any{"name": "certificates", "image": "golang:1.27.1", "index_digest": testDigest(index)},
		map[string]any{"name": "runtime", "image": "ubuntu:24.04", "index_digest": testDigest(index)},
	}}
	lock := map[string]any{"schema": 1, "proofs": []any{
		map[string]any{"name": "certificates", "index": index, "manifest": manifest, "config": config},
		map[string]any{"name": "runtime", "index": index, "manifest": manifest, "config": config},
	}}
	writeFixture(t, root, "trusted-runtime-bases.sources.json", sources)
	writeFixture(t, root, "trusted-runtime-bases.lock.json", lock)
	dockerfile := fmt.Sprintf("FROM golang:1.27.1@%s AS certificates\nFROM ubuntu:24.04@%s\n", testDigest(manifest), testDigest(manifest))
	if err := os.WriteFile(filepath.Join(directory, "trusted-regressions.Dockerfile"), []byte(dockerfile), 0600); err != nil {
		t.Fatal(err)
	}
	return root, lock
}

func writeFixture(t *testing.T, root, name string, value any) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(root, ".github", "containers", name), testJSON(value), 0600); err != nil {
		t.Fatal(err)
	}
}

func TestOfflineCommandChecksCompleteChainAndActualFroms(t *testing.T) {
	root, _ := baseFixture(t)
	command := exec.Command("go", "run", "main.go", "--check", root)
	result, err := command.CombinedOutput()
	if err != nil {
		t.Fatalf("complete verified base recipe refused: %v\n%s", err, result)
	}
	if !strings.Contains(string(result), "linux/amd64") || !strings.Contains(string(result), "certificates") || !strings.Contains(string(result), "runtime") {
		t.Fatalf("missing actual selected base identities: %s", result)
	}
}

func TestOfflineCommandRefusesStaleDockerfile(t *testing.T) {
	root, _ := baseFixture(t)
	file := filepath.Join(root, ".github", "containers", "trusted-regressions.Dockerfile")
	if err := os.WriteFile(file, []byte("FROM ubuntu:24.04@sha256:"+strings.Repeat("0", 64)+"\n"), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := exec.Command("go", "run", "main.go", "--check", root).CombinedOutput()
	if err == nil || !strings.Contains(string(result), "Dockerfile") {
		t.Fatalf("stale source join did not refuse specifically: %v %s", err, result)
	}
}

// rewriteIndex changes an authenticated fixture root so structure refusals are
// exercised separately from digest mismatches.
func rewriteIndex(t *testing.T, src *source, p *proof, change func(*index)) {
	t.Helper()
	var item index
	if err := json.Unmarshal(p.Index, &item); err != nil {
		t.Fatal(err)
	}
	change(&item)
	p.Index = testJSON(item)
	src.IndexDigest = testDigest(p.Index)
}

func TestProofRefusals(t *testing.T) {
	root, data := baseFixture(t)
	set, err := sources(root)
	if err != nil {
		t.Fatal(err)
	}
	var original lock
	if err = json.Unmarshal(testJSON(data), &original); err != nil {
		t.Fatal(err)
	}
	cases := map[string]func(*source, *proof){
		"wrong index digest":  func(s *source, p *proof) { s.IndexDigest = "sha256:" + strings.Repeat("0", 64) },
		"altered index bytes": func(s *source, p *proof) { p.Index = append(p.Index, ' ') },
		"partial index":       func(s *source, p *proof) { p.Index = p.Index[:len(p.Index)-1] },
		"duplicate platform": func(s *source, p *proof) {
			rewriteIndex(t, s, p, func(i *index) { i.Manifests = append(i.Manifests, i.Manifests[0]) })
		},
		"wrong architecture": func(s *source, p *proof) {
			rewriteIndex(t, s, p, func(i *index) { i.Manifests[0].Platform.Architecture = "arm64" })
		},
		"architecture variant": func(s *source, p *proof) {
			rewriteIndex(t, s, p, func(i *index) { i.Manifests[0].Platform.Variant = "v3" })
		},
		"missing platform": func(s *source, p *proof) {
			rewriteIndex(t, s, p, func(i *index) { i.Manifests[0].Platform = platform{} })
		},
		"wrong child size": func(s *source, p *proof) { rewriteIndex(t, s, p, func(i *index) { i.Manifests[0].Size++ }) },
		"index is not an index": func(s *source, p *proof) {
			rewriteIndex(t, s, p, func(i *index) { i.MediaType = "application/vnd.oci.image.manifest.v1+json" })
		},
		"altered child":            func(s *source, p *proof) { p.Manifest = append(p.Manifest, ' ') },
		"altered configuration":    func(s *source, p *proof) { p.Config = append(p.Config, ' ') },
		"incomplete configuration": func(s *source, p *proof) { p.Config = nil },
		"wrong identity":           func(s *source, p *proof) { p.Name = "runtime" },
		"oversized index": func(s *source, p *proof) {
			p.Index = bytes.Repeat([]byte(" "), metadataLimit+1)
			s.IndexDigest = testDigest(p.Index)
		},
		"trailing JSON": func(s *source, p *proof) {
			p.Index = append(p.Index, []byte("{}")...)
			s.IndexDigest = testDigest(p.Index)
		},
		"authenticated wrong config platform": func(s *source, p *proof) {
			p.Config = testJSON(map[string]any{"os": "linux", "architecture": "arm64"})
			var m manifest
			if err := json.Unmarshal(p.Manifest, &m); err != nil {
				t.Fatal(err)
			}
			m.Config.Digest = testDigest(p.Config)
			m.Config.Size = int64(len(p.Config))
			p.Manifest = testJSON(m)
			rewriteIndex(t, s, p, func(i *index) {
				i.Manifests[0].Digest = testDigest(p.Manifest)
				i.Manifests[0].Size = int64(len(p.Manifest))
			})
		},
	}
	for name, change := range cases {
		t.Run(name, func(t *testing.T) {
			src := set.Bases[0]
			var p proof
			if err := json.Unmarshal(testJSON(original.Proofs[0]), &p); err != nil {
				t.Fatal(err)
			}
			change(&src, &p)
			if _, err := verifyBase(src, p); err == nil {
				t.Fatal("invalid proof admitted")
			}
		})
	}
}

type registryTransport func(*http.Request) (*http.Response, error)

func (f registryTransport) RoundTrip(request *http.Request) (*http.Response, error) {
	return f(request)
}

type partialBody struct{ *bytes.Reader }

func TestResolverRedirectsConfineEgressAndToken(t *testing.T) {
	for _, target := range []string{
		"https://production.cloudfront.docker.com/blob",
		"https://unreviewed.example/blob", "https://registry-1.docker.io.evil.example/blob",
		"http://production.cloudfront.docker.com/blob", "https://production.cloudfront.docker.com:444/blob",
		"https://user@production.cloudfront.docker.com/blob",
	} {
		t.Run(target, func(t *testing.T) {
			calls := 0
			client := registryClient()
			client.Transport = registryTransport(func(request *http.Request) (*http.Response, error) {
				calls++
				if calls == 1 {
					if request.Header.Get("Authorization") != "Bearer anonymous-pull" {
						t.Error("registry did not receive its token")
					}
					return &http.Response{StatusCode: http.StatusTemporaryRedirect, Header: http.Header{"Location": {target}}, Body: http.NoBody}, nil
				}
				if target != "https://production.cloudfront.docker.com/blob" || request.Header.Get("Authorization") != "" {
					t.Fatal("redirect widened egress or forwarded registry token")
				}
				return &http.Response{StatusCode: http.StatusOK, Header: make(http.Header), Body: io.NopCloser(strings.NewReader("blob")), ContentLength: 4}, nil
			})
			raw, err := registryGet(context.Background(), client, "https://registry-1.docker.io/v2/library/ubuntu/blobs/fixture", "anonymous-pull")
			if target == "https://production.cloudfront.docker.com/blob" {
				if err != nil || string(raw) != "blob" || calls != 2 {
					t.Fatalf("reviewed CDN refused: %v calls=%d", err, calls)
				}
			} else if err == nil || calls != 1 {
				t.Fatalf("unreviewed redirect was contacted: %v calls=%d", err, calls)
			}
		})
	}
}

func (p partialBody) Read(data []byte) (int, error) {
	n, err := p.Reader.Read(data)
	if err == io.EOF {
		return n, io.ErrUnexpectedEOF
	}
	return n, err
}
func (p partialBody) Close() error { return nil }

func TestRegistryResolutionRequiresCompleteAuthenticatedReads(t *testing.T) {
	root, data := baseFixture(t)
	set, err := sources(root)
	if err != nil {
		t.Fatal(err)
	}
	var fixture lock
	if err = json.Unmarshal(testJSON(data), &fixture); err != nil {
		t.Fatal(err)
	}
	for _, failure := range []string{"", "index partial", "child partial", "config partial", "status", "oversized"} {
		t.Run(failure, func(t *testing.T) {
			calls := 0
			client := &http.Client{Transport: registryTransport(func(request *http.Request) (*http.Response, error) {
				calls++
				var payload []byte
				stage := ""
				switch {
				case request.URL.Host == "auth.docker.io":
					if request.Header.Get("Authorization") != "" {
						t.Error("authorization sent to token issuer")
					}
					if request.URL.Query().Get("scope") != "repository:library/golang:pull" && request.URL.Query().Get("scope") != "repository:library/ubuntu:pull" {
						t.Fatal("unreviewed registry scope")
					}
					payload = []byte("{\"token\":\"anonymous-pull\"}")
				case strings.Contains(request.URL.Path, "/manifests/"+set.Bases[0].IndexDigest):
					payload = fixture.Proofs[0].Index
					stage = "index"
				case strings.Contains(request.URL.Path, "/manifests/"+testDigest(fixture.Proofs[0].Manifest)):
					payload = fixture.Proofs[0].Manifest
					stage = "child"
				case strings.Contains(request.URL.Path, "/blobs/"+testDigest(fixture.Proofs[0].Config)):
					payload = fixture.Proofs[0].Config
					stage = "config"
				default:
					t.Fatalf("unexpected metadata request %s", request.URL.Path)
				}
				body := io.ReadCloser(io.NopCloser(bytes.NewReader(payload)))
				if failure == stage+" partial" {
					body = partialBody{bytes.NewReader(payload)}
				}
				status := http.StatusOK
				if failure == "status" {
					status = http.StatusServiceUnavailable
				}
				length := int64(len(payload))
				if failure == "oversized" {
					length = metadataLimit + 1
				}
				return &http.Response{StatusCode: status, Body: body, Header: make(http.Header), ContentLength: length}, nil
			})}
			output, err := resolve(context.Background(), set, client)
			if failure == "" {
				if err != nil || len(output.Proofs) != 2 || calls != 8 {
					t.Fatalf("real metadata chain refused: %v calls=%d", err, calls)
				}
			} else if err == nil || len(output.Proofs) != 0 {
				t.Fatalf("failed/partial observation admitted: %v", err)
			}
		})
	}
}

func TestOfflineRefusesMissingAndUntrustedRecipeFiles(t *testing.T) {
	for _, bad := range []string{"missing lock", "linked lock", "partial lock", "wrong repository", "extra source", "unknown lock field"} {
		t.Run(bad, func(t *testing.T) {
			root, data := baseFixture(t)
			path := filepath.Join(root, lockPath)
			switch bad {
			case "missing lock":
				if err := os.Remove(path); err != nil {
					t.Fatal(err)
				}
			case "linked lock":
				if err := os.Rename(path, path+".real"); err != nil {
					t.Fatal(err)
				}
				if err := os.Symlink(path+".real", path); err != nil {
					t.Fatal(err)
				}
			case "partial lock":
				if err := os.WriteFile(path, []byte("{"), 0600); err != nil {
					t.Fatal(err)
				}
			case "unknown lock field":
				data["accepted"] = true
				writeFixture(t, root, "trusted-runtime-bases.lock.json", data)
			default:
				raw, err := os.ReadFile(filepath.Join(root, sourcePath))
				if err != nil {
					t.Fatal(err)
				}
				var set sourceSet
				if err = json.Unmarshal(raw, &set); err != nil {
					t.Fatal(err)
				}
				if bad == "wrong repository" {
					set.Bases[0].Image = "other:1"
				} else {
					set.Bases = append(set.Bases, set.Bases[0])
				}
				writeFixture(t, root, "trusted-runtime-bases.sources.json", set)
			}
			var output bytes.Buffer
			if err := run([]string{"--check", root}, &output); err == nil || output.Len() != 0 {
				t.Fatalf("invalid recipe emitted a usable verdict: %v %s", err, output.String())
			}
		})
	}
}
