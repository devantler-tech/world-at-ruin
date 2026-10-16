// Command trusted-runtime-inventory reports observed ingredients, never cache admission.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
)

const maximumInventoryBytes = 1024 * 1024

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var versionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$`)
var packagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9+.:~-]*$`)
var archiveNamePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~%_-]*\.deb$`)
var pathPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+._~%/-]*$`)
var directPins = map[string]string{
	"libfontconfig1": "2.15.0-1.1ubuntu2", "libx11-6": "2:1.8.7-1build1",
	"libxcursor1": "1:1.2.1-1build1", "libxinerama1": "2:1.1.4-3build1",
	"libgl1": "1.7.0-1build1", "libxi6": "2:1.8.1-1build1", "libxrandr2": "2:1.5.2-2build1",
	"libwayland-client0": "1.22.0-2.1build1", "libxkbcommon0": "1.6.0-1build1", "libdbus-1-3": "1.14.10-4ubuntu4.1",
}

type installedPackage struct {
	Name         string `json:"name"`
	Version      string `json:"version"`
	Architecture string `json:"architecture"`
}
type ingredientFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}
type inventory struct {
	Architecture string             `json:"architecture"`
	Packages     []installedPackage `json:"installed_packages"`
	Files        []ingredientFile   `json:"apt_inputs"`
	Engine       string             `json:"engine_sha256"`
	Transaction  transaction        `json:"transaction"`
}
type archiveObservation struct {
	installedPackage
	Basename string          `json:"basename"`
	URI      string          `json:"requested_uri"`
	Bytes    int64           `json:"bytes"`
	SHA256   string          `json:"sha256"`
	Origins  []archiveOrigin `json:"apt_origins"`
}
type archiveOrigin struct {
	PackageFilename string         `json:"package_filename"`
	RepositoryURI   string         `json:"repository_uri"`
	BaseURI         string         `json:"base_uri"`
	Release         string         `json:"release"`
	Component       string         `json:"component"`
	Architecture    string         `json:"target_architecture"`
	Trusted         bool           `json:"trusted"`
	Origin          string         `json:"origin"`
	Label           string         `json:"label"`
	Codename        string         `json:"codename"`
	Suite           string         `json:"suite"`
	IndexURI        string         `json:"index_uri"`
	Index           ingredientFile `json:"index"`
	InRelease       ingredientFile `json:"inrelease"`
}
type aptTarget struct {
	IndexURI      string         `json:"index_uri"`
	RepositoryURI string         `json:"repository_uri"`
	BaseURI       string         `json:"base_uri"`
	Release       string         `json:"release"`
	Component     string         `json:"component"`
	Architecture  string         `json:"architecture"`
	Trusted       bool           `json:"trusted"`
	Origin        string         `json:"origin"`
	Label         string         `json:"label"`
	Codename      string         `json:"codename"`
	Suite         string         `json:"suite"`
	Index         ingredientFile `json:"index"`
	InRelease     ingredientFile `json:"inrelease"`
}
type transaction struct {
	APTVersion string               `json:"apt_version"`
	Arguments  []string             `json:"direct_arguments"`
	Inherited  []installedPackage   `json:"preinstall_packages"`
	Targets    []aptTarget          `json:"apt_targets"`
	Archives   []archiveObservation `json:"downloaded_archives"`
}

func safeEvidenceText(value string, maximum int) bool {
	return value != "" && len(value) <= maximum && !strings.ContainsAny(value, "\x00\r\n\t")
}

func evidenceURL(raw string, slash bool) bool {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Hostname() == "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || strings.ContainsAny(raw, "\r\n\t\x00 ") {
		return false
	}
	return !slash || strings.HasSuffix(raw, "/")
}

// requestMatchesOrigin derives APT's effective archive repository from the
// selected Packages target URI, then compares the escaped request suffix with
// the raw Filename carried by that target. REPO_URI and BASE_URI can retain
// logical source names when APT redirects through its immutable snapshot service.
func requestMatchesOrigin(requestURI, indexURI, release, filename string) bool {
	marker := "/dists/" + release + "/"
	position := strings.LastIndex(indexURI, marker)
	if !packagePattern.MatchString(release) || position <= 0 || strings.Contains(indexURI[:position], marker) {
		return false
	}
	repositoryURI := indexURI[:position+1]
	if !evidenceURL(repositoryURI, true) || !strings.HasPrefix(requestURI, repositoryURI) {
		return false
	}
	decoded, err := url.PathUnescape(strings.TrimPrefix(requestURI, repositoryURI))
	return err == nil && decoded == filename
}

func evidenceFile(path, sizeText, digest string, maximum int64) (ingredientFile, error) {
	size, err := strconv.ParseInt(sizeText, 10, 64)
	if err != nil || size <= 0 || size > maximum || !digestPattern.MatchString(digest) || !strings.HasPrefix(path, "/var/lib/apt/lists/") || strings.Contains(strings.TrimPrefix(path, "/var/lib/apt/lists/"), "/") || filepath.Clean(path) != path || strings.ContainsAny(path, "\r\n\t\x00") {
		return ingredientFile{}, errors.New("APT evidence file refused")
	}
	return ingredientFile{Path: path, SHA256: digest, Bytes: size}, nil
}

func parseTargetRecord(fields []string) (aptTarget, error) {
	var out aptTarget
	if len(fields) != 17 || !evidenceURL(fields[0], false) || !evidenceURL(fields[4], true) || !evidenceURL(fields[5], true) || (fields[8] != "amd64" && fields[8] != "all") || fields[9] != "yes" {
		return out, errors.New("APT target identity refused")
	}
	for _, value := range fields[6:14] {
		if !safeEvidenceText(value, 256) {
			return out, errors.New("APT target release identity refused")
		}
	}
	index, err := evidenceFile(fields[1], fields[2], fields[3], 256*1024*1024)
	if err != nil || !strings.Contains(filepath.Base(index.Path), "_Packages") {
		return out, errors.New("APT target index refused")
	}
	release, err := evidenceFile(fields[14], fields[15], fields[16], 16*1024*1024)
	if err != nil || !strings.HasSuffix(release.Path, "_InRelease") {
		return out, errors.New("APT target release refused")
	}
	out = aptTarget{IndexURI: fields[0], RepositoryURI: fields[4], BaseURI: fields[5], Release: fields[6], Component: fields[7], Architecture: fields[8], Trusted: true, Origin: fields[10], Label: fields[11], Codename: fields[12], Suite: fields[13], Index: index, InRelease: release}
	return out, nil
}

func parseOriginRecord(fields []string) (string, installedPackage, archiveOrigin, error) {
	var origin archiveOrigin
	if len(fields) != 22 || !archiveNamePattern.MatchString(fields[0]) || !pathPattern.MatchString(fields[4]) || filepath.IsAbs(fields[4]) || filepath.Clean(fields[4]) != fields[4] || strings.HasPrefix(fields[4], "../") || !evidenceURL(fields[5], true) || !evidenceURL(fields[6], true) || (fields[9] != "amd64" && fields[9] != "all") || fields[10] != "yes" || !evidenceURL(fields[15], false) {
		return "", installedPackage{}, origin, errors.New("APT archive origin refused")
	}
	identity, err := transactionIdentity(fields[1:4])
	if err != nil {
		return "", installedPackage{}, origin, err
	}
	for _, value := range fields[7:15] {
		if !safeEvidenceText(value, 256) {
			return "", installedPackage{}, origin, errors.New("APT archive release identity refused")
		}
	}
	index, err := evidenceFile(fields[16], fields[17], fields[18], 256*1024*1024)
	if err != nil || !strings.Contains(filepath.Base(index.Path), "_Packages") {
		return "", installedPackage{}, origin, errors.New("APT archive index refused")
	}
	release, err := evidenceFile(fields[19], fields[20], fields[21], 16*1024*1024)
	if err != nil || !strings.HasSuffix(release.Path, "_InRelease") {
		return "", installedPackage{}, origin, errors.New("APT archive release refused")
	}
	origin = archiveOrigin{PackageFilename: fields[4], RepositoryURI: fields[5], BaseURI: fields[6], Release: fields[7], Component: fields[8], Architecture: fields[9], Trusted: true, Origin: fields[11], Label: fields[12], Codename: fields[13], Suite: fields[14], IndexURI: fields[15], Index: index, InRelease: release}
	return fields[0], identity, origin, nil
}

func originMatchesTarget(origin archiveOrigin, target aptTarget) bool {
	return origin.RepositoryURI == target.RepositoryURI && origin.BaseURI == target.BaseURI && origin.Release == target.Release && origin.Component == target.Component && origin.Architecture == target.Architecture && origin.Trusted == target.Trusted && origin.Origin == target.Origin && origin.Label == target.Label && origin.Codename == target.Codename && origin.Suite == target.Suite && origin.IndexURI == target.IndexURI && origin.Index == target.Index && origin.InRelease == target.InRelease
}

// transactionIdentity validates data fields without deriving package identity from filenames.
func transactionIdentity(fields []string) (installedPackage, error) {
	if len(fields) != 3 || !packagePattern.MatchString(fields[0]) || !versionPattern.MatchString(fields[1]) || (fields[2] != "amd64" && fields[2] != "all") {
		return installedPackage{}, errors.New("transaction package identity refused")
	}
	return installedPackage{fields[0], fields[1], fields[2]}, nil
}

// archiveMetadata accepts bounded archive names and complete SHA-256/size observations.
func archiveMetadata(name, sizeText, hash string) (archiveObservation, error) {
	var out archiveObservation
	if !archiveNamePattern.MatchString(name) || !digestPattern.MatchString(hash) {
		return out, errors.New("transaction archive request refused")
	}
	size, err := strconv.ParseInt(sizeText, 10, 64)
	if err != nil || size <= 0 || size > 64*1024*1024 {
		return out, errors.New("transaction archive size refused")
	}
	out.Basename, out.Bytes, out.SHA256 = name, size, hash
	return out, nil
}

// planRecord retains requested URLs as data, never as authenticated selected-index evidence.
func planRecord(fields []string) (archiveObservation, error) {
	item, err := archiveMetadata(fields[1], fields[2], fields[3])
	if err != nil {
		return item, err
	}
	uri, err := url.Parse(fields[0])
	if err != nil || (uri.Scheme != "https" && uri.Scheme != "http") || uri.Hostname() == "" || uri.User != nil || uri.RawQuery != "" || uri.Fragment != "" || strings.ContainsAny(fields[0], "\r\n\t\x00 ") {
		return archiveObservation{}, errors.New("transaction request URI refused")
	}
	item.URI = fields[0]
	return item, nil
}

// parseTransaction accounts for the installed set and APT target join; it grants no lock authority.
func parseTransaction(lines []string, final []installedPackage) (transaction, error) {
	var out transaction
	refuse := func() (transaction, error) {
		return transaction{}, errors.New("runtime transaction incomplete or inconsistent")
	}
	if len(lines) == 0 || lines[len(lines)-1] != "transaction-complete" {
		return refuse()
	}
	base, acquired := map[string]installedPackage{}, map[string]bool{}
	plans, archives := map[string]archiveObservation{}, map[string]archiveObservation{}
	origins, originIdentities := map[string][]archiveOrigin{}, map[string]installedPackage{}
	originCount := 0
	targets := map[string]aptTarget{}
	arguments := map[string]bool{}
	for _, line := range lines[:len(lines)-1] {
		f := strings.Split(line, "\t")
		switch f[0] {
		case "apt-version":
			if len(f) != 2 || out.APTVersion != "" || !versionPattern.MatchString(f[1]) {
				return refuse()
			}
			out.APTVersion = f[1]
		case "argument":
			if len(f) != 2 || arguments[f[1]] {
				return refuse()
			}
			name, version, ok := strings.Cut(f[1], "=")
			if !ok || directPins[name] != version || version == "" {
				return refuse()
			}
			arguments[f[1]] = true
			out.Arguments = append(out.Arguments, f[1])
		case "base-package":
			if len(f) != 5 || f[4] != "installed" || len(base) >= 2048 {
				return refuse()
			}
			item, err := transactionIdentity(f[1:4])
			if err != nil || base[item.Name].Name != "" {
				return refuse()
			}
			base[item.Name] = item
			out.Inherited = append(out.Inherited, item)
		case "plan":
			if len(f) != 5 || len(plans) >= 1024 {
				return refuse()
			}
			item, err := planRecord(f[1:])
			if err != nil || plans[item.Basename].Basename != "" {
				return refuse()
			}
			plans[item.Basename] = item
		case "archive":
			if len(f) != 7 || len(archives) >= 1024 {
				return refuse()
			}
			identity, err := transactionIdentity(f[2:5])
			if err != nil || acquired[identity.Name] {
				return refuse()
			}
			item, err := archiveMetadata(f[1], f[5], f[6])
			if err != nil || archives[item.Basename].Basename != "" {
				return refuse()
			}
			item.installedPackage = identity
			archives[item.Basename], acquired[identity.Name] = item, true
		case "target":
			if len(targets) >= 64 {
				return refuse()
			}
			item, err := parseTargetRecord(f[1:])
			if err != nil || targets[item.Index.Path].Index.Path != "" {
				return refuse()
			}
			targets[item.Index.Path] = item
			out.Targets = append(out.Targets, item)
		case "origin":
			if originCount >= 4096 {
				return refuse()
			}
			name, identity, item, err := parseOriginRecord(f[1:])
			if err != nil || (originIdentities[name].Name != "" && originIdentities[name] != identity) {
				return refuse()
			}
			for _, existing := range origins[name] {
				if existing == item {
					return refuse()
				}
			}
			origins[name] = append(origins[name], item)
			originIdentities[name], originCount = identity, originCount+1
		default:
			return refuse()
		}
	}
	if len(arguments) != len(directPins) || len(base) == 0 || base["apt"].Version != out.APTVersion || out.APTVersion == "" || len(archives) == 0 || len(plans) != len(archives) || len(origins) != len(archives) || len(targets) == 0 {
		return refuse()
	}
	var totalBytes int64
	for name, item := range archives {
		plan := plans[name]
		archiveOrigins := origins[name]
		if plan.Basename == "" || plan.Bytes != item.Bytes || plan.SHA256 != item.SHA256 || base[item.Name] == item.installedPackage || originIdentities[name] != item.installedPackage || len(archiveOrigins) == 0 {
			return refuse()
		}
		for _, origin := range archiveOrigins {
			target := targets[origin.Index.Path]
			if !requestMatchesOrigin(plan.URI, origin.IndexURI, origin.Release, origin.PackageFilename) || target.Index.Path == "" || !originMatchesTarget(origin, target) {
				return refuse()
			}
		}
		sort.Slice(archiveOrigins, func(i, j int) bool { return archiveOrigins[i].Index.Path < archiveOrigins[j].Index.Path })
		item.URI = plan.URI
		item.Origins = archiveOrigins
		totalBytes += item.Bytes
		if totalBytes > 256*1024*1024 {
			return refuse()
		}
		base[item.Name] = item.installedPackage
		out.Archives = append(out.Archives, item)
	}
	if len(base) != len(final) {
		return refuse()
	}
	for _, item := range final {
		if base[item.Name] != item {
			return refuse()
		}
	}
	sort.Strings(out.Arguments)
	sort.Slice(out.Inherited, func(i, j int) bool { return out.Inherited[i].Name < out.Inherited[j].Name })
	sort.Slice(out.Targets, func(i, j int) bool { return out.Targets[i].Index.Path < out.Targets[j].Index.Path })
	sort.Slice(out.Archives, func(i, j int) bool { return out.Archives[i].Basename < out.Archives[j].Basename })
	return out, nil
}

type imageConfig struct {
	User       string
	WorkingDir string
	Entrypoint []string
}
type image struct {
	Id           string
	Os           string
	Architecture string
	Config       imageConfig
}
type report struct {
	Schema              int              `json:"schema"`
	Evidence            string           `json:"evidence"`
	Image               image            `json:"image"`
	Inventory           inventory        `json:"inventory"`
	Recipe              []ingredientFile `json:"recipe_files"`
	EngineVersion       string           `json:"caller_engine_version"`
	EngineArchiveSHA512 string           `json:"caller_engine_archive_sha512"`
}

// parseInventory accepts one complete bounded installed-package and APT observation.
func parseInventory(raw []byte, expectedEngine string) (inventory, error) {
	var out inventory
	fail := func() (inventory, error) {
		return inventory{}, errors.New("runtime inventory incomplete or inconsistent")
	}
	if len(raw) > maximumInventoryBytes || !digestPattern.MatchString(expectedEngine) {
		return fail()
	}
	lines := strings.Split(string(raw), "\n")
	if len(lines) < 5 || lines[0] != "WAR_RUNTIME_INVENTORY\t1" || lines[1] != "amd64" || lines[len(lines)-1] != "" || lines[len(lines)-2] != "END" {
		return fail()
	}
	out.Architecture = lines[1]
	packages, files := map[string]string{}, map[string]ingredientFile{}
	var transactionLines []string
	signed, indexes := false, false
	for _, line := range lines[2 : len(lines)-2] {
		fields := strings.Split(line, "\t")
		switch fields[0] {
		case "package":
			if len(fields) != 5 || !packagePattern.MatchString(fields[1]) || !versionPattern.MatchString(fields[2]) || (fields[3] != "amd64" && fields[3] != "all") || fields[4] != "installed" || packages[fields[1]] != "" || len(packages) >= 2048 {
				return fail()
			}
			packages[fields[1]] = fields[2]
			out.Packages = append(out.Packages, installedPackage{fields[1], fields[2], fields[3]})
		case "file":
			if len(fields) != 4 || !digestPattern.MatchString(fields[1]) {
				return fail()
			}
			path := fields[3]
			size, err := strconv.ParseInt(fields[2], 10, 64)
			if err != nil || size <= 0 || size > 256*1024*1024 || filepath.Clean(path) != path || strings.ContainsAny(path, "\r\x00") || files[path].Path != "" || len(files) >= 256 || !allowedInput(path) {
				return fail()
			}
			files[path] = ingredientFile{Path: path, SHA256: fields[1], Bytes: size}
			signed = signed || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.HasSuffix(path, "_InRelease"))
			indexes = indexes || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.Contains(filepath.Base(path), "_Packages"))
			out.Files = append(out.Files, ingredientFile{path, fields[1], size})
		case "engine":
			if len(fields) != 2 || out.Engine != "" || fields[1] != expectedEngine {
				return fail()
			}
			out.Engine = fields[1]
		case "apt-version", "argument", "base-package", "plan", "archive", "target", "origin", "transaction-complete":
			transactionLines = append(transactionLines, line)
		default:
			return fail()
		}
	}
	for name, version := range directPins {
		if packages[name] != version {
			return fail()
		}
	}
	for _, required := range []string{"/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt"} {
		if files[required].Path == "" {
			return fail()
		}
	}
	if !signed || !indexes || out.Engine == "" || len(packages) <= len(directPins) {
		return fail()
	}
	observedTransaction, err := parseTransaction(transactionLines, out.Packages)
	if err != nil {
		return fail()
	}
	for _, target := range observedTransaction.Targets {
		if files[target.Index.Path] != target.Index || files[target.InRelease.Path] != target.InRelease {
			return fail()
		}
	}
	out.Transaction = observedTransaction
	sort.Slice(out.Packages, func(i, j int) bool { return out.Packages[i].Name < out.Packages[j].Name })
	sort.Slice(out.Files, func(i, j int) bool { return out.Files[i].Path < out.Files[j].Path })
	return out, nil
}

// allowedInput confines evidence names to the package inputs captured by the image.
func allowedInput(path string) bool {
	if path == "/etc/ssl/certs/ca-certificates.crt" || path == "/usr/share/keyrings/ubuntu-archive-keyring.gpg" {
		return true
	}
	for _, prefix := range []string{"/var/lib/apt/lists/", "/etc/apt/apt.conf.d/", "/etc/apt/sources.list.d/"} {
		if strings.HasPrefix(path, prefix) && !strings.Contains(strings.TrimPrefix(path, prefix), "/") {
			return true
		}
	}
	return path == "/etc/apt/sources.list"
}

// parseImage requires the executor configuration used by the non-root Linux probe.
func parseImage(raw []byte) (image, error) {
	var images []image
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	err := decoder.Decode(&images)
	var extra any
	if err != nil || decoder.Decode(&extra) != io.EOF || len(images) != 1 {
		return image{}, errors.New("runtime image inspection incomplete")
	}
	item := images[0]
	if !strings.HasPrefix(item.Id, "sha256:") || !digestPattern.MatchString(strings.TrimPrefix(item.Id, "sha256:")) || item.Os != "linux" || item.Architecture != "amd64" || item.Config.User != "1001:1001" || item.Config.WorkingDir != "/project" || len(item.Config.Entrypoint) != 1 || item.Config.Entrypoint[0] != "/usr/local/bin/godot" {
		return image{}, errors.New("runtime image contract refused")
	}
	return item, nil
}

// boundedFile verifies the opened regular handle and bounds its complete contents.
func boundedFile(path string, maximum int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	opened, statErr := file.Stat()
	named, linkErr := os.Lstat(path)
	if statErr != nil || linkErr != nil || !opened.Mode().IsRegular() || !named.Mode().IsRegular() || !os.SameFile(opened, named) || opened.Size() > maximum {
		return nil, errors.New("runtime evidence handle or file identity refused")
	}
	limited := &io.LimitedReader{R: file, N: maximum + 1}
	raw, err := io.ReadAll(limited)
	if err != nil || int64(len(raw)) > maximum {
		return nil, errors.New("runtime evidence read incomplete")
	}
	return raw, nil
}

// fileIdentity binds a selected source or engine to its actual bytes and size.
func fileIdentity(path, name string, maximum int64) (ingredientFile, error) {
	raw, err := boundedFile(path, maximum)
	if err != nil {
		return ingredientFile{}, err
	}
	sum := sha256.Sum256(raw)
	return ingredientFile{name, hex.EncodeToString(sum[:]), int64(len(raw))}, nil
}

// writeReport refuses short writes so incomplete output cannot report success.
func writeReport(value any, writer io.Writer) error {
	raw, err := json.Marshal(value)
	if err != nil {
		return err
	}
	raw = append(raw, '\n')
	count, err := writer.Write(raw)
	if err != nil || count != len(raw) {
		return errors.New("runtime inventory report incomplete")
	}
	return nil
}

// run keeps observation off unless explicitly selected and joins engine, image and recipe.
func run(args []string, output io.Writer) error {
	if len(args) == 0 {
		return nil
	}
	if len(args) != 4 || args[0] != "--experimental" {
		return errors.New("runtime inventory requires explicit selection and three input paths")
	}
	root, inspectPath, inventoryPath := args[1], args[2], args[3]
	enginePath, err := exec.LookPath("godot")
	if err != nil {
		return err
	}
	engine, err := fileIdentity(enginePath, "godot", 512*1024*1024)
	if err != nil {
		return err
	}
	imageRaw, err := boundedFile(inspectPath, 16*1024)
	if err != nil {
		return err
	}
	observedImage, err := parseImage(imageRaw)
	if err != nil {
		return err
	}
	raw, err := boundedFile(inventoryPath, maximumInventoryBytes)
	if err != nil {
		return err
	}
	observed, err := parseInventory(raw, engine.SHA256)
	if err != nil {
		return err
	}
	result := report{Schema: 1, Evidence: "observed-cold-build-inventory-only", Image: observedImage, Inventory: observed}
	for _, path := range []string{".github/containers/trusted-regressions.Dockerfile", "tools/build-trusted-regression-runtime.sh", "tools/install-ci-godot.sh", "tools/trusted-regression-lifecycle.sh", "tools/trusted-regression-phase.sh", "tools/trusted-phase-command.sh", "tools/process-group-lifecycle.sh", "tools/capture-trusted-runtime-inventory.sh", "tools/inspect-trusted-runtime.sh", "tools/trusted-runtime-inventory/main.go", ".github/containers/trusted-runtime-bases.sources.json", ".github/containers/trusted-runtime-bases.lock.json", "tools/trusted-runtime-bases/main.go", "tools/build-locked-trusted-runtime.sh", ".github/containers/trusted-runtime-packages.lock.json", "tools/trusted-runtime-packages/main.go", "tools/verify-trusted-runtime-packages.sh", "tools/observe-runtime-transaction.sh", "tools/trusted-runtime-origin/main.go", ".github/containers/trusted-runtime-archives.lock.json", "tools/trusted-runtime-archives/main.go"} {
		item, err := fileIdentity(filepath.Join(root, path), path, 1024*1024)
		if err != nil {
			return err
		}
		result.Recipe = append(result.Recipe, item)
	}
	result.EngineVersion = os.Getenv("GODOT_VERSION")
	result.EngineArchiveSHA512 = os.Getenv("GODOT_SHA512")
	if result.EngineVersion != "4.7.1" || len(result.EngineArchiveSHA512) != 128 {
		return errors.New("caller engine description missing")
	}
	if _, err = hex.DecodeString(result.EngineArchiveSHA512); err != nil {
		return errors.New("caller engine checksum malformed")
	}
	return writeReport(result, output)
}

// main makes every incomplete or inconsistent observation a command failure.
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
