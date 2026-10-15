// Command trusted-runtime-bases generates and checks immutable Linux base proofs.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strings"
	"time"
)

const metadataLimit = 1 << 20
const sourcePath = ".github/containers/trusted-runtime-bases.sources.json"
const lockPath = ".github/containers/trusted-runtime-bases.lock.json"

var digestSyntax = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var imageSyntax = regexp.MustCompile(`^(golang|ubuntu):[A-Za-z0-9][A-Za-z0-9_.-]*$`)

type source struct {
	Name        string `json:"name"`
	Image       string `json:"image"`
	IndexDigest string `json:"index_digest"`
}
type sourceSet struct {
	Schema int      `json:"schema"`
	Bases  []source `json:"bases"`
}
type proof struct {
	Name     string `json:"name"`
	Index    []byte `json:"index"`
	Manifest []byte `json:"manifest"`
	Config   []byte `json:"config"`
}
type lock struct {
	Schema int     `json:"schema"`
	Proofs []proof `json:"proofs"`
}
type platform struct {
	OS           string   `json:"os"`
	Architecture string   `json:"architecture"`
	Variant      string   `json:"variant"`
	OSVersion    string   `json:"os.version"`
	OSFeatures   []string `json:"os.features"`
}
type descriptor struct {
	MediaType string   `json:"mediaType"`
	Digest    string   `json:"digest"`
	Size      int64    `json:"size"`
	Platform  platform `json:"platform"`
}
type index struct {
	SchemaVersion int          `json:"schemaVersion"`
	MediaType     string       `json:"mediaType"`
	Manifests     []descriptor `json:"manifests"`
}
type manifest struct {
	SchemaVersion int          `json:"schemaVersion"`
	MediaType     string       `json:"mediaType"`
	Config        descriptor   `json:"config"`
	Layers        []descriptor `json:"layers"`
}
type selection struct {
	Source   source
	Manifest descriptor
	Config   descriptor
}

func digest(raw []byte) string { return fmt.Sprintf("sha256:%x", sha256.Sum256(raw)) }
func manifestType(media string) bool {
	return media == "application/vnd.oci.image.manifest.v1+json" || media == "application/vnd.docker.distribution.manifest.v2+json"
}

// selectedDescriptor refuses ambiguous platforms; attestations are never executors.
func selectedDescriptor(raw []byte, expected string) (descriptor, error) {
	var item index
	if len(raw) > metadataLimit || digest(raw) != expected || json.Unmarshal(raw, &item) != nil || item.SchemaVersion != 2 ||
		(item.MediaType != "application/vnd.oci.image.index.v1+json" && item.MediaType != "application/vnd.docker.distribution.manifest.list.v2+json") {
		return descriptor{}, errors.New("base index identity or structure refused")
	}
	var matches []descriptor
	for _, candidate := range item.Manifests {
		if candidate.Platform.OS == "linux" && candidate.Platform.Architecture == "amd64" {
			matches = append(matches, candidate)
		}
	}
	if len(matches) != 1 {
		return descriptor{}, errors.New("base index requires exactly one linux/amd64 manifest")
	}
	chosen := matches[0]
	if !manifestType(chosen.MediaType) || !digestSyntax.MatchString(chosen.Digest) || chosen.Size <= 0 || chosen.Size > metadataLimit ||
		chosen.Platform.Variant != "" || chosen.Platform.OSVersion != "" || len(chosen.Platform.OSFeatures) != 0 {
		return descriptor{}, errors.New("base platform descriptor refused")
	}
	return chosen, nil
}

func descriptorBytes(raw []byte, item descriptor) bool {
	return item.Size > 0 && item.Size <= metadataLimit && int64(len(raw)) == item.Size && digestSyntax.MatchString(item.Digest) && digest(raw) == item.Digest
}

// verifyBase authenticates all metadata bytes from the independently pinned index root.
func verifyBase(src source, p proof) (selection, error) {
	chosen, err := selectedDescriptor(p.Index, src.IndexDigest)
	if err != nil {
		return selection{}, err
	}
	var child manifest
	if p.Name != src.Name || !descriptorBytes(p.Manifest, chosen) || json.Unmarshal(p.Manifest, &child) != nil ||
		child.SchemaVersion != 2 || child.MediaType != chosen.MediaType || len(child.Layers) == 0 ||
		(child.Config.MediaType != "application/vnd.oci.image.config.v1+json" && child.Config.MediaType != "application/vnd.docker.container.image.v1+json") {
		return selection{}, errors.New("base manifest bytes or configuration descriptor refused")
	}
	var config platform
	if !descriptorBytes(p.Config, child.Config) || json.Unmarshal(p.Config, &config) != nil ||
		config.OS != "linux" || config.Architecture != "amd64" || config.Variant != "" {
		return selection{}, errors.New("base configuration bytes or platform refused")
	}
	for _, layer := range child.Layers {
		if !digestSyntax.MatchString(layer.Digest) || layer.Size <= 0 {
			return selection{}, errors.New("base layer descriptor refused")
		}
	}
	return selection{src, chosen, child.Config}, nil
}

// regularBytes bounds complete reads of the opened regular handle, including failures.
func regularBytes(path string, maximum int64) ([]byte, error) {
	before, err := os.Lstat(path)
	if err != nil || !before.Mode().IsRegular() {
		return nil, errors.New("base recipe file missing or not regular")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || !os.SameFile(before, info) || info.Size() > maximum {
		return nil, errors.New("base recipe file changed or oversized")
	}
	data, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(data)) > maximum || int64(len(data)) != info.Size() {
		return nil, errors.New("base recipe file read incomplete")
	}
	return data, nil
}

func strictJSON(raw []byte, target any) error {
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(target); err != nil {
		return err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return errors.New("trailing base recipe content")
	}
	return nil
}

func sources(root string) (sourceSet, error) {
	raw, err := regularBytes(filepath.Join(root, sourcePath), 65536)
	if err != nil {
		return sourceSet{}, err
	}
	var set sourceSet
	if strictJSON(raw, &set) != nil || set.Schema != 1 || len(set.Bases) != 2 {
		return sourceSet{}, errors.New("base sources incomplete")
	}
	for i, want := range []struct{ name, image string }{{"certificates", "golang:"}, {"runtime", "ubuntu:"}} {
		got := set.Bases[i]
		if got.Name != want.name || !strings.HasPrefix(got.Image, want.image) || !imageSyntax.MatchString(got.Image) || !digestSyntax.MatchString(got.IndexDigest) {
			return sourceSet{}, errors.New("base source repository or index refused")
		}
	}
	return set, nil
}

func check(root string, set sourceSet) ([]selection, error) {
	raw, err := regularBytes(filepath.Join(root, lockPath), 8*metadataLimit)
	if err != nil {
		return nil, err
	}
	var locked lock
	if strictJSON(raw, &locked) != nil || locked.Schema != 1 || len(locked.Proofs) != len(set.Bases) {
		return nil, errors.New("base lock incomplete")
	}
	var selected []selection
	for i, src := range set.Bases {
		item, verifyErr := verifyBase(src, locked.Proofs[i])
		if verifyErr != nil {
			return nil, verifyErr
		}
		selected = append(selected, item)
	}
	dockerfile, err := regularBytes(filepath.Join(root, ".github/containers/trusted-regressions.Dockerfile"), 65536)
	if err != nil {
		return nil, err
	}
	var froms []string
	for _, line := range strings.Split(string(dockerfile), "\n") {
		fields := strings.Fields(line)
		if len(fields) > 0 && strings.EqualFold(fields[0], "FROM") {
			froms = append(froms, strings.Join(fields, " "))
		}
	}
	if len(froms) != 2 || froms[0] != "FROM "+selected[0].Source.Image+"@"+selected[0].Manifest.Digest+" AS certificates" ||
		froms[1] != "FROM "+selected[1].Source.Image+"@"+selected[1].Manifest.Digest {
		return nil, errors.New("Dockerfile does not consume the verified base lock")
	}
	return selected, nil
}

// registryGet requests only metadata; it never reads local Docker credentials.
func registryGet(ctx context.Context, client *http.Client, address, token string) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, address, nil)
	if err != nil {
		return nil, errors.New("registry metadata request refused")
	}
	req.Header.Set("Accept", "application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json")
	req.Header.Set("Accept-Encoding", "identity")
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	response, err := client.Do(req)
	if err != nil {
		return nil, errors.New("registry metadata unavailable")
	}
	defer response.Body.Close()
	if response.StatusCode != http.StatusOK || response.ContentLength > metadataLimit ||
		(response.Header.Get("Content-Encoding") != "" && response.Header.Get("Content-Encoding") != "identity") {
		return nil, errors.New("registry metadata status or encoding refused")
	}
	raw, err := io.ReadAll(io.LimitReader(response.Body, metadataLimit+1))
	if err != nil || len(raw) > metadataLimit || (response.ContentLength >= 0 && int64(len(raw)) != response.ContentLength) {
		return nil, errors.New("registry metadata read incomplete or oversized")
	}
	return raw, nil
}

func resolve(ctx context.Context, set sourceSet, client *http.Client) (lock, error) {
	out := lock{Schema: 1}
	for _, src := range set.Bases {
		image, _, _ := strings.Cut(src.Image, ":")
		repository := "library/" + image
		auth := "https://auth.docker.io/token?" + url.Values{"service": {"registry.docker.io"}, "scope": {"repository:" + repository + ":pull"}}.Encode()
		raw, err := registryGet(ctx, client, auth, "")
		if err != nil {
			return lock{}, err
		}
		var token struct{ Token string }
		if json.Unmarshal(raw, &token) != nil || token.Token == "" || strings.ContainsAny(token.Token, "\r\n") {
			return lock{}, errors.New("anonymous registry pull authorization refused")
		}
		base := "https://registry-1.docker.io/v2/" + repository
		p := proof{Name: src.Name}
		p.Index, err = registryGet(ctx, client, base+"/manifests/"+src.IndexDigest, token.Token)
		if err != nil {
			return lock{}, err
		}
		chosen, err := selectedDescriptor(p.Index, src.IndexDigest)
		if err != nil {
			return lock{}, err
		}
		p.Manifest, err = registryGet(ctx, client, base+"/manifests/"+chosen.Digest, token.Token)
		if err != nil {
			return lock{}, err
		}
		var child manifest
		if !descriptorBytes(p.Manifest, chosen) || json.Unmarshal(p.Manifest, &child) != nil ||
			!digestSyntax.MatchString(child.Config.Digest) || child.Config.Size <= 0 || child.Config.Size > metadataLimit {
			return lock{}, errors.New("registry child manifest refused")
		}
		p.Config, err = registryGet(ctx, client, base+"/blobs/"+child.Config.Digest, token.Token)
		if err != nil {
			return lock{}, err
		}
		if _, err = verifyBase(src, p); err != nil {
			return lock{}, err
		}
		out.Proofs = append(out.Proofs, p)
	}
	return out, nil
}

func registryClient() *http.Client {
	return &http.Client{Timeout: 30 * time.Second, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		// Docker Hub currently redirects configuration blobs to this public CDN.
		// A new destination requires a reviewed policy update, not metadata authority.
		if len(via) >= 3 || req.URL.Scheme != "https" || req.URL.User != nil ||
			(req.URL.Host != "registry-1.docker.io" && req.URL.Host != "production.cloudfront.docker.com") {
			return errors.New("registry metadata redirect refused")
		}
		if req.URL.Host != "registry-1.docker.io" {
			req.Header.Del("Authorization")
		}
		return nil
	}}
}

func run(args []string, out io.Writer) error {
	if len(args) != 2 || (args[0] != "--resolve" && args[0] != "--check") {
		return errors.New("usage: trusted-runtime-bases --resolve|--check <repository>")
	}
	set, err := sources(args[1])
	if err != nil {
		return err
	}
	if args[0] == "--check" {
		selected, checkErr := check(args[1], set)
		if checkErr != nil {
			return checkErr
		}
		for _, item := range selected {
			if _, err = fmt.Fprintf(out, "TRUSTED_RUNTIME_BASE %s linux/amd64 manifest=%s config=%s\n", item.Source.Name, item.Manifest.Digest, item.Config.Digest); err != nil {
				return err
			}
		}
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Minute)
	defer cancel()
	locked, err := resolve(ctx, set, registryClient())
	if err != nil {
		return err
	}
	encoder := json.NewEncoder(out)
	encoder.SetIndent("", "  ")
	return encoder.Encode(locked)
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "trusted runtime bases:", err)
		os.Exit(1)
	}
}
