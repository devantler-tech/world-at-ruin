// Command trusted-runtime-archives generates and enforces reviewed APT archive expectations.
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
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"syscall"
)

const maximumInputBytes = 2 * 1024 * 1024

var digestPattern = regexp.MustCompile(`^[0-9a-f]{64}$`)
var manifestPattern = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var packagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)
var versionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$`)
var archivePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~%_-]*[.]deb$`)
var snapshotPattern = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z$`)
var runtimeFrom = regexp.MustCompile(`(?m)^FROM ubuntu:24[.]04@(sha256:[0-9a-f]{64})\s*$`)
var snapshotSetting = regexp.MustCompile(`APT::Snapshot "([0-9]{8}T[0-9]{6}Z)";`)
var installPin = regexp.MustCompile(`^([a-z0-9][a-z0-9+.-]*)=([A-Za-z0-9][A-Za-z0-9+.:~_-]*)$`)

var requiredRecipeFiles = []string{
	".github/containers/trusted-regressions.Dockerfile",
	"tools/build-trusted-regression-runtime.sh",
	"tools/install-ci-godot.sh",
	"tools/trusted-regression-lifecycle.sh",
	"tools/trusted-regression-phase.sh",
	"tools/trusted-phase-command.sh",
	"tools/process-group-lifecycle.sh",
	"tools/capture-trusted-runtime-inventory.sh",
	"tools/inspect-trusted-runtime.sh",
	"tools/trusted-runtime-inventory/main.go",
	".github/containers/trusted-runtime-bases.sources.json",
	".github/containers/trusted-runtime-bases.lock.json",
	"tools/trusted-runtime-bases/main.go",
	"tools/build-locked-trusted-runtime.sh",
	".github/containers/trusted-runtime-packages.lock.json",
	"tools/trusted-runtime-packages/main.go",
	"tools/verify-trusted-runtime-packages.sh",
	"tools/observe-runtime-transaction.sh",
	"tools/trusted-runtime-origin/main.go",
	"tools/propose-trusted-runtime-archives.sh",
}

type evidenceFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type packageIdentity struct {
	Name         string `json:"name"`
	Version      string `json:"version"`
	Architecture string `json:"architecture"`
}

type originExpectation struct {
	Trusted         bool         `json:"trusted"`
	Index           evidenceFile `json:"index"`
	InRelease       evidenceFile `json:"inrelease"`
	PackageFilename string       `json:"package_filename"`
	Architecture    string       `json:"target_architecture"`
	RepositoryURI   string       `json:"repository_uri"`
	BaseURI         string       `json:"base_uri"`
	IndexURI        string       `json:"index_uri"`
	Release         string       `json:"release"`
	Component       string       `json:"component"`
	Origin          string       `json:"origin"`
	Codename        string       `json:"codename"`
	Suite           string       `json:"suite"`
	Label           string       `json:"label"`
}

type archiveExpectation struct {
	Name         string              `json:"name"`
	Version      string              `json:"version"`
	Architecture string              `json:"architecture"`
	Basename     string              `json:"basename"`
	RequestedURI string              `json:"requested_uri"`
	Bytes        int64               `json:"bytes"`
	SHA256       string              `json:"sha256"`
	Origins      []originExpectation `json:"apt_origins"`
}

type targetObservation struct {
	Release       string       `json:"release"`
	Label         string       `json:"label"`
	RepositoryURI string       `json:"repository_uri"`
	Component     string       `json:"component"`
	Suite         string       `json:"suite"`
	BaseURI       string       `json:"base_uri"`
	Origin        string       `json:"origin"`
	Architecture  string       `json:"architecture"`
	Codename      string       `json:"codename"`
	IndexURI      string       `json:"index_uri"`
	Trusted       bool         `json:"trusted"`
	Index         evidenceFile `json:"index"`
	InRelease     evidenceFile `json:"inrelease"`
}

type archiveLock struct {
	Schema            int                  `json:"schema"`
	Architecture      string               `json:"architecture"`
	RuntimeManifest   string               `json:"runtime_manifest"`
	Snapshot          string               `json:"snapshot"`
	APTVersion        string               `json:"apt_version"`
	DirectArguments   []string             `json:"direct_arguments"`
	PackageLockSHA256 string               `json:"package_lock_sha256"`
	BaseLockSHA256    string               `json:"base_lock_sha256"`
	ReportSHA256      string               `json:"source_report_sha256"`
	ReportImageID     string               `json:"source_image_id"`
	Archives          []archiveExpectation `json:"archives"`
}

type packageLock struct {
	Schema          int               `json:"schema"`
	Architecture    string            `json:"architecture"`
	RuntimeManifest string            `json:"runtime_manifest"`
	Snapshot        string            `json:"snapshot"`
	Packages        []packageIdentity `json:"packages"`
}

type coldReport struct {
	Schema   int    `json:"schema"`
	Evidence string `json:"evidence"`
	Image    struct {
		ID           string `json:"Id"`
		OS           string `json:"Os"`
		Architecture string `json:"Architecture"`
		Config       struct {
			User       string   `json:"User"`
			WorkingDir string   `json:"WorkingDir"`
			Entrypoint []string `json:"Entrypoint"`
		} `json:"Config"`
	} `json:"image"`
	Inventory struct {
		Architecture string            `json:"architecture"`
		Packages     []packageIdentity `json:"installed_packages"`
		Files        []evidenceFile    `json:"apt_inputs"`
		Engine       string            `json:"engine_sha256"`
		Transaction  struct {
			APTVersion string               `json:"apt_version"`
			Arguments  []string             `json:"direct_arguments"`
			Inherited  []packageIdentity    `json:"preinstall_packages"`
			Targets    []targetObservation  `json:"apt_targets"`
			Archives   []archiveExpectation `json:"downloaded_archives"`
		} `json:"transaction"`
	} `json:"inventory"`
	Recipe              []evidenceFile `json:"recipe_files"`
	EngineVersion       string         `json:"caller_engine_version"`
	EngineArchiveSHA512 string         `json:"caller_engine_archive_sha512"`
}

func sha256Hex(raw []byte) string {
	sum := sha256.Sum256(raw)
	return hex.EncodeToString(sum[:])
}

func strictJSON(raw []byte, target any) error {
	if len(raw) == 0 || len(raw) > maximumInputBytes {
		return errors.New("archive expectation input missing or oversized")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	decoder.DisallowUnknownFields()
	decodeErr := decoder.Decode(target)
	var extra json.RawMessage
	terminalErr := decoder.Decode(&extra)
	if decodeErr != nil {
		return decodeErr
	}
	if terminalErr != io.EOF {
		return errors.New("archive expectation input has trailing or partial content")
	}
	return nil
}

func regularBytes(path string, maximum int64) ([]byte, error) {
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("archive expectation input cannot be opened")
	}
	defer file.Close()
	opened, err := file.Stat()
	named, namedErr := os.Lstat(path)
	stat, statOK := opened.Sys().(*syscall.Stat_t)
	if err != nil || namedErr != nil || !opened.Mode().IsRegular() || !named.Mode().IsRegular() || !os.SameFile(named, opened) || opened.Size() <= 0 || opened.Size() > maximum || opened.Size() != named.Size() || !statOK || stat.Nlink != 1 {
		return nil, errors.New("archive expectation input is linked, changed or outside bounds")
	}
	raw, err := io.ReadAll(io.LimitReader(file, maximum+1))
	if err != nil || int64(len(raw)) != opened.Size() {
		return nil, errors.New("archive expectation input read incomplete")
	}
	return raw, nil
}

func evidenceURL(raw string, trailingSlash bool) bool {
	parsed, err := url.Parse(raw)
	if err != nil || (parsed.Scheme != "https" && parsed.Scheme != "http") || parsed.Hostname() == "" || parsed.Port() != "" || parsed.User != nil || parsed.RawQuery != "" || parsed.Fragment != "" || strings.ContainsAny(raw, "\x00\r\n\t ") {
		return false
	}
	return !trailingSlash || strings.HasSuffix(raw, "/")
}

func safeText(value string) bool {
	return value != "" && len(value) <= 256 && !strings.ContainsAny(value, "\x00\r\n\t")
}

func validEvidenceFile(item evidenceFile, suffix string) bool {
	return item.Bytes > 0 && item.Bytes <= 256*1024*1024 && digestPattern.MatchString(item.SHA256) && filepath.IsAbs(item.Path) && filepath.Clean(item.Path) == item.Path && strings.Contains(filepath.Base(item.Path), suffix) && !strings.ContainsAny(item.Path, "\x00\r\n\t")
}

func validPackage(item packageIdentity) bool {
	return packagePattern.MatchString(item.Name) && versionPattern.MatchString(item.Version) && (item.Architecture == "amd64" || item.Architecture == "all")
}

func fileSet(items []evidenceFile, absolute bool) (map[string]evidenceFile, error) {
	if len(items) == 0 || len(items) > 512 {
		return nil, errors.New("report evidence files missing or over bound")
	}
	out := make(map[string]evidenceFile, len(items))
	for _, item := range items {
		if item.Path == "" || item.Path == "." || filepath.Clean(item.Path) != item.Path || filepath.IsAbs(item.Path) != absolute || (!absolute && strings.HasPrefix(item.Path, "../")) || strings.ContainsAny(item.Path, "\x00\r\n\t") || item.Bytes <= 0 || item.Bytes > 256*1024*1024 || !digestPattern.MatchString(item.SHA256) || out[item.Path].Path != "" {
			return nil, errors.New("report evidence file refused")
		}
		out[item.Path] = item
	}
	return out, nil
}

func dockerRunInstructions(raw []byte) ([]string, error) {
	var logical strings.Builder
	var runs []string
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimRight(line, " \t\r")
		continued := strings.HasSuffix(line, "\\")
		part := strings.TrimSpace(strings.TrimSuffix(line, "\\"))
		if strings.HasPrefix(part, "#") {
			continue
		}
		if part != "" {
			if logical.Len() > 0 {
				logical.WriteByte(' ')
			}
			logical.WriteString(part)
		}
		if continued {
			continue
		}
		instruction := strings.TrimSpace(logical.String())
		logical.Reset()
		fields := strings.Fields(instruction)
		if len(fields) > 1 && strings.EqualFold(fields[0], "RUN") {
			runs = append(runs, strings.Join(fields[1:], " "))
		}
	}
	if logical.Len() != 0 {
		return nil, errors.New("runtime recipe has an incomplete Dockerfile instruction")
	}
	return runs, nil
}

func parseRecipe(raw []byte) (string, string, []string, error) {
	runs, err := dockerRunInstructions(raw)
	if err != nil {
		return "", "", nil, err
	}
	const observer = `bash /tmp/observe-runtime-transaction.sh "$WAR_RUNTIME_INVENTORY" "$WAR_RUNTIME_ARCHIVE_POLICY"`
	const command = "apt-get install -y --no-install-recommends"
	wrapped := "&& " + observer + " " + command
	installCount, observerCount, transaction := 0, 0, ""
	for _, run := range runs {
		installCount += strings.Count(run, command)
		count := strings.Count(run, wrapped)
		observerCount += count
		if count == 1 {
			transaction = run
		}
	}
	if observerCount != 1 {
		return "", "", nil, errors.New("runtime transaction verifier invocation missing or repeated")
	}
	bases := runtimeFrom.FindAllSubmatch(raw, -1)
	snapshots := snapshotSetting.FindAllStringSubmatch(strings.Join(runs, "\n"), -1)
	if len(bases) != 1 || len(snapshots) != 1 {
		return "", "", nil, errors.New("runtime base or snapshot identity missing")
	}
	if installCount != 1 {
		return "", "", nil, errors.New("runtime install declaration missing or repeated")
	}
	_, tail, _ := strings.Cut(transaction, wrapped)
	tail, _, found := strings.Cut(tail, "&&")
	if !found {
		return "", "", nil, errors.New("runtime install boundary missing")
	}
	seen := map[string]bool{}
	var arguments []string
	for _, field := range strings.Fields(strings.ReplaceAll(tail, "\\\n", " ")) {
		match := installPin.FindStringSubmatch(field)
		if len(match) != 3 || seen[match[1]] {
			return "", "", nil, errors.New("runtime install arguments must be unique exact pins")
		}
		seen[match[1]] = true
		arguments = append(arguments, field)
	}
	if len(arguments) == 0 {
		return "", "", nil, errors.New("runtime install arguments missing")
	}
	sort.Strings(arguments)
	return string(bases[0][1]), string(snapshots[0][1]), arguments, nil
}

func decodePackageLock(raw []byte) (packageLock, error) {
	var value packageLock
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	if value.Schema != 1 || value.Architecture != "amd64" || !manifestPattern.MatchString(value.RuntimeManifest) || !snapshotPattern.MatchString(value.Snapshot) || len(value.Packages) == 0 || len(value.Packages) > 2048 {
		return value, errors.New("installed package lock identity refused")
	}
	previous := ""
	for _, item := range value.Packages {
		if !validPackage(item) || item.Name <= previous {
			return value, errors.New("installed package lock is not a unique sorted set")
		}
		previous = item.Name
	}
	return value, nil
}

func originKey(item originExpectation) string {
	return strings.Join([]string{item.PackageFilename, item.RepositoryURI, item.BaseURI, item.Release, item.Component, item.Architecture, item.Origin, item.Label, item.Codename, item.Suite, item.IndexURI, item.Index.Path, strconv.FormatInt(item.Index.Bytes, 10), item.Index.SHA256, item.InRelease.Path, strconv.FormatInt(item.InRelease.Bytes, 10), item.InRelease.SHA256}, "\t")
}

func targetMatchesOrigin(target targetObservation, origin originExpectation) bool {
	return target.Trusted && origin.Trusted && target.IndexURI == origin.IndexURI && target.RepositoryURI == origin.RepositoryURI && target.BaseURI == origin.BaseURI && target.Release == origin.Release && target.Component == origin.Component && target.Architecture == origin.Architecture && target.Origin == origin.Origin && target.Label == origin.Label && target.Codename == origin.Codename && target.Suite == origin.Suite && target.Index == origin.Index && target.InRelease == origin.InRelease
}

func targetKey(item targetObservation) string {
	return strings.Join([]string{item.IndexURI, item.RepositoryURI, item.BaseURI, item.Release, item.Component, item.Architecture, item.Origin, item.Label, item.Codename, item.Suite, item.Index.Path, item.Index.SHA256, item.InRelease.Path, item.InRelease.SHA256}, "\t")
}

func validateTargets(items []targetObservation, aptFiles map[string]evidenceFile) error {
	seen := map[string]bool{}
	seenPaths, seenURIs := map[string]bool{}, map[string]bool{}
	for _, item := range items {
		if !item.Trusted || !evidenceURL(item.IndexURI, false) || !evidenceURL(item.RepositoryURI, true) || !evidenceURL(item.BaseURI, true) || !packagePattern.MatchString(item.Release) || !safeText(item.Component) || !safeText(item.Origin) || !safeText(item.Label) || !safeText(item.Codename) || !safeText(item.Suite) || (item.Architecture != "amd64" && item.Architecture != "all") || !validEvidenceFile(item.Index, "_Packages") || !validEvidenceFile(item.InRelease, "_InRelease") || aptFiles[item.Index.Path] != item.Index || aptFiles[item.InRelease.Path] != item.InRelease || seen[targetKey(item)] || seenPaths[item.Index.Path] || seenURIs[item.IndexURI] {
			return errors.New("cold report target set invalid, untrusted or duplicated")
		}
		seen[targetKey(item)] = true
		seenPaths[item.Index.Path], seenURIs[item.IndexURI] = true, true
	}
	return nil
}

func requestMatchesOrigin(request string, origin originExpectation) bool {
	marker := "/dists/" + origin.Release + "/"
	position := strings.LastIndex(origin.IndexURI, marker)
	if position <= 0 || strings.Contains(origin.IndexURI[:position], marker) {
		return false
	}
	repository := origin.IndexURI[:position+1]
	if !strings.HasPrefix(request, repository) {
		return false
	}
	decoded, err := url.PathUnescape(strings.TrimPrefix(request, repository))
	return err == nil && decoded == origin.PackageFilename
}

func validateOrigin(item originExpectation) error {
	if !item.Trusted || !packagePattern.MatchString(item.Release) || !safeText(item.Component) || !safeText(item.Origin) || !safeText(item.Label) || !safeText(item.Codename) || !safeText(item.Suite) || (item.Architecture != "amd64" && item.Architecture != "all") || !evidenceURL(item.RepositoryURI, true) || !evidenceURL(item.BaseURI, true) || !evidenceURL(item.IndexURI, false) || item.PackageFilename == "." || filepath.IsAbs(item.PackageFilename) || filepath.Clean(item.PackageFilename) != item.PackageFilename || strings.HasPrefix(item.PackageFilename, "../") || strings.ContainsAny(item.PackageFilename, "\x00\r\n\t") || !validEvidenceFile(item.Index, "_Packages") || !validEvidenceFile(item.InRelease, "_InRelease") {
		return errors.New("archive origin identity refused")
	}
	return nil
}

func validateArchive(item archiveExpectation, targets []targetObservation) error {
	if !validPackage(packageIdentity{item.Name, item.Version, item.Architecture}) || !archivePattern.MatchString(item.Basename) || !evidenceURL(item.RequestedURI, false) || item.Bytes <= 0 || item.Bytes > 64*1024*1024 || !digestPattern.MatchString(item.SHA256) || len(item.Origins) == 0 || len(item.Origins) > 16 {
		return errors.New("archive expectation identity refused")
	}
	seen := map[string]bool{}
	for _, origin := range item.Origins {
		if err := validateOrigin(origin); err != nil || !requestMatchesOrigin(item.RequestedURI, origin) {
			return errors.New("archive origin does not explain requested bytes")
		}
		matched := false
		for _, target := range targets {
			if targetMatchesOrigin(target, origin) {
				matched = true
				break
			}
		}
		key := originKey(origin)
		if !matched || seen[key] {
			return errors.New("archive origin missing from targets or duplicated")
		}
		seen[key] = true
	}
	return nil
}

func samePackages(left, right []packageIdentity) bool {
	if len(left) != len(right) {
		return false
	}
	for i := range left {
		if left[i] != right[i] {
			return false
		}
	}
	return true
}

func validateReport(report coldReport, root string, packageBytes, baseBytes, recipe []byte) error {
	if report.Schema != 1 || report.Evidence != "observed-cold-build-inventory-only" || !manifestPattern.MatchString(report.Image.ID) || report.Image.OS != "linux" || report.Image.Architecture != "amd64" || report.Inventory.Architecture != "amd64" || report.Image.Config.User != "1001:1001" || report.Image.Config.WorkingDir != "/project" || len(report.Image.Config.Entrypoint) != 1 || report.Image.Config.Entrypoint[0] != "/usr/local/bin/godot" || !digestPattern.MatchString(report.Inventory.Engine) || !versionPattern.MatchString(report.EngineVersion) || len(report.EngineArchiveSHA512) != 128 {
		return errors.New("cold report identity refused")
	}
	if _, err := hex.DecodeString(report.EngineArchiveSHA512); err != nil {
		return errors.New("cold report engine archive digest refused")
	}
	aptFiles, err := fileSet(report.Inventory.Files, true)
	if err != nil {
		return err
	}
	for _, path := range []string{"/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt"} {
		if aptFiles[path].Path == "" {
			return errors.New("cold report APT inputs incomplete")
		}
	}
	recipeFiles, err := fileSet(report.Recipe, false)
	if err != nil {
		return err
	}
	if len(recipeFiles) != len(requiredRecipeFiles) {
		return errors.New("cold report recipe evidence is not the exact required set")
	}
	for _, path := range requiredRecipeFiles {
		item := recipeFiles[path]
		if item.Path == "" {
			return errors.New("cold report recipe evidence incomplete")
		}
		current, readErr := regularBytes(filepath.Join(root, path), maximumInputBytes)
		if readErr != nil || item.SHA256 != sha256Hex(current) || item.Bytes != int64(len(current)) {
			return errors.New("cold report does not bind every current recipe file")
		}
	}
	locked, err := decodePackageLock(packageBytes)
	if err != nil || !samePackages(report.Inventory.Packages, locked.Packages) {
		return errors.New("cold report final packages do not match installed lock")
	}
	manifest, snapshot, arguments, err := parseRecipe(recipe)
	if err != nil || manifest != locked.RuntimeManifest || snapshot != locked.Snapshot {
		return errors.New("cold report recipe does not match installed lock")
	}
	observedArguments := append([]string(nil), report.Inventory.Transaction.Arguments...)
	sort.Strings(observedArguments)
	if strings.Join(arguments, "\n") != strings.Join(observedArguments, "\n") {
		return errors.New("cold report direct arguments do not match recipe")
	}
	if !versionPattern.MatchString(report.Inventory.Transaction.APTVersion) || len(report.Inventory.Transaction.Targets) == 0 || len(report.Inventory.Transaction.Targets) > 128 || len(report.Inventory.Transaction.Archives) == 0 || len(report.Inventory.Transaction.Archives) > 1024 {
		return errors.New("cold report transaction missing or over bound")
	}
	if err = validateTargets(report.Inventory.Transaction.Targets, aptFiles); err != nil {
		return err
	}
	final := map[string]packageIdentity{}
	for _, item := range report.Inventory.Transaction.Inherited {
		if !validPackage(item) || final[item.Name].Name != "" {
			return errors.New("cold report inherited packages invalid or duplicated")
		}
		final[item.Name] = item
	}
	archiveNames, packageNames := map[string]bool{}, map[string]bool{}
	for i := range report.Inventory.Transaction.Archives {
		item := &report.Inventory.Transaction.Archives[i]
		if err := validateArchive(*item, report.Inventory.Transaction.Targets); err != nil || archiveNames[item.Basename] || packageNames[item.Name] {
			return errors.New("cold report archive set invalid or duplicated")
		}
		archiveNames[item.Basename], packageNames[item.Name] = true, true
		sort.Slice(item.Origins, func(i, j int) bool { return originKey(item.Origins[i]) < originKey(item.Origins[j]) })
		final[item.Name] = packageIdentity{item.Name, item.Version, item.Architecture}
	}
	if len(final) != len(locked.Packages) {
		return errors.New("cold report transaction does not explain final package set")
	}
	for _, item := range locked.Packages {
		if final[item.Name] != item {
			return errors.New("cold report transaction final package mismatch")
		}
		if item.Name == "apt" && item.Version != report.Inventory.Transaction.APTVersion {
			return errors.New("cold report APT version disagrees with final set")
		}
	}
	return nil
}

func generate(raw []byte, root string) (archiveLock, error) {
	var report coldReport
	var result archiveLock
	if err := strictJSON(raw, &report); err != nil {
		return result, err
	}
	containerDir := filepath.Join(root, ".github", "containers")
	packageBytes, err := regularBytes(filepath.Join(containerDir, "trusted-runtime-packages.lock.json"), maximumInputBytes)
	if err != nil {
		return result, err
	}
	baseBytes, err := regularBytes(filepath.Join(containerDir, "trusted-runtime-bases.lock.json"), maximumInputBytes)
	if err != nil {
		return result, err
	}
	recipe, err := regularBytes(filepath.Join(containerDir, "trusted-regressions.Dockerfile"), maximumInputBytes)
	if err != nil {
		return result, err
	}
	if err = validateReport(report, root, packageBytes, baseBytes, recipe); err != nil {
		return result, err
	}
	locked, _ := decodePackageLock(packageBytes)
	arguments := append([]string(nil), report.Inventory.Transaction.Arguments...)
	sort.Strings(arguments)
	archives := append([]archiveExpectation(nil), report.Inventory.Transaction.Archives...)
	sort.Slice(archives, func(i, j int) bool { return archives[i].Name < archives[j].Name })
	result = archiveLock{
		Schema: 1, Architecture: "amd64", RuntimeManifest: locked.RuntimeManifest, Snapshot: locked.Snapshot,
		APTVersion: report.Inventory.Transaction.APTVersion, DirectArguments: arguments,
		PackageLockSHA256: sha256Hex(packageBytes), BaseLockSHA256: sha256Hex(baseBytes),
		ReportSHA256: sha256Hex(raw), ReportImageID: report.Image.ID, Archives: archives,
	}
	return result, validateLock(result)
}

func validateLock(value archiveLock) error {
	if value.Schema != 1 || value.Architecture != "amd64" || !manifestPattern.MatchString(value.RuntimeManifest) || !snapshotPattern.MatchString(value.Snapshot) || !versionPattern.MatchString(value.APTVersion) || !digestPattern.MatchString(value.PackageLockSHA256) || !digestPattern.MatchString(value.BaseLockSHA256) || !digestPattern.MatchString(value.ReportSHA256) || !manifestPattern.MatchString(value.ReportImageID) || len(value.DirectArguments) == 0 || len(value.Archives) == 0 || len(value.Archives) > 1024 {
		return errors.New("archive lock identity refused")
	}
	previous := ""
	for _, argument := range value.DirectArguments {
		if !installPin.MatchString(argument) || argument <= previous {
			return errors.New("archive lock arguments must be unique and sorted")
		}
		previous = argument
	}
	previous = ""
	for _, archive := range value.Archives {
		if err := validateArchive(archive, originsAsTargets(archive.Origins)); err != nil || archive.Name <= previous {
			return errors.New("archive lock entries must be valid, unique and sorted")
		}
		originPrevious := ""
		for _, origin := range archive.Origins {
			key := originKey(origin)
			if key <= originPrevious {
				return errors.New("archive lock origins must be unique and sorted")
			}
			originPrevious = key
		}
		previous = archive.Name
	}
	return nil
}

func originsAsTargets(origins []originExpectation) []targetObservation {
	result := make([]targetObservation, 0, len(origins))
	for _, item := range origins {
		result = append(result, targetObservation{
			Trusted: item.Trusted, Index: item.Index, InRelease: item.InRelease, Architecture: item.Architecture,
			RepositoryURI: item.RepositoryURI, BaseURI: item.BaseURI, IndexURI: item.IndexURI,
			Release: item.Release, Component: item.Component, Origin: item.Origin,
			Codename: item.Codename, Suite: item.Suite, Label: item.Label,
		})
	}
	return result
}

func decodeLock(raw []byte) (archiveLock, error) {
	var value archiveLock
	if err := strictJSON(raw, &value); err != nil {
		return value, err
	}
	return value, validateLock(value)
}

func validateRecipeBindings(value archiveLock, root string) error {
	dir := filepath.Join(root, ".github", "containers")
	packageBytes, err := regularBytes(filepath.Join(dir, "trusted-runtime-packages.lock.json"), maximumInputBytes)
	if err != nil {
		return err
	}
	baseBytes, err := regularBytes(filepath.Join(dir, "trusted-runtime-bases.lock.json"), maximumInputBytes)
	if err != nil {
		return err
	}
	recipe, err := regularBytes(filepath.Join(dir, "trusted-regressions.Dockerfile"), maximumInputBytes)
	if err != nil {
		return err
	}
	manifest, snapshot, arguments, err := parseRecipe(recipe)
	if err != nil || manifest != value.RuntimeManifest || snapshot != value.Snapshot || strings.Join(arguments, "\n") != strings.Join(value.DirectArguments, "\n") || sha256Hex(packageBytes) != value.PackageLockSHA256 || sha256Hex(baseBytes) != value.BaseLockSHA256 {
		return errors.New("archive lock does not match current runtime recipe")
	}
	return nil
}

func writeComplete(out io.Writer, raw []byte) error {
	written, err := out.Write(raw)
	if err != nil || written != len(raw) {
		return errors.New("archive expectation output incomplete")
	}
	return nil
}

func emit(root string, out io.Writer) error {
	raw, err := regularBytes(filepath.Join(root, ".github", "containers", "trusted-runtime-archives.lock.json"), maximumInputBytes)
	if err != nil {
		return err
	}
	value, err := decodeLock(raw)
	if err != nil {
		return err
	}
	if err = validateRecipeBindings(value, root); err != nil {
		return err
	}
	canonical, err := json.Marshal(value)
	if err != nil {
		return err
	}
	return writeComplete(out, append(canonical, '\n'))
}

func parseOriginFields(fields []string) (originExpectation, error) {
	var item originExpectation
	if len(fields) != 22 || fields[10] != "yes" {
		return item, errors.New("transaction origin record refused")
	}
	indexBytes, indexErr := strconv.ParseInt(fields[17], 10, 64)
	releaseBytes, releaseErr := strconv.ParseInt(fields[20], 10, 64)
	if indexErr != nil || releaseErr != nil {
		return item, errors.New("transaction origin size refused")
	}
	item = originExpectation{
		PackageFilename: fields[4], RepositoryURI: fields[5], BaseURI: fields[6], Release: fields[7], Component: fields[8], Architecture: fields[9], Trusted: true,
		Origin: fields[11], Label: fields[12], Codename: fields[13], Suite: fields[14], IndexURI: fields[15],
		Index: evidenceFile{fields[16], fields[18], indexBytes}, InRelease: evidenceFile{fields[19], fields[21], releaseBytes},
	}
	return item, validateOrigin(item)
}

func verify(lockRaw, transactionRaw []byte) error {
	value, err := decodeLock(lockRaw)
	if err != nil {
		return err
	}
	if len(transactionRaw) == 0 || len(transactionRaw) > maximumInputBytes || transactionRaw[len(transactionRaw)-1] != '\n' {
		return errors.New("transaction evidence missing, partial or oversized")
	}
	type planRecord struct {
		URI, Basename, SHA256 string
		Bytes                 int64
	}
	plans := map[string]planRecord{}
	archives := map[string]archiveExpectation{}
	origins := map[string][]originExpectation{}
	var arguments []string
	aptVersion := ""
	for _, line := range strings.Split(strings.TrimSuffix(string(transactionRaw), "\n"), "\n") {
		fields := strings.Split(line, "\t")
		if len(fields) == 0 {
			return errors.New("empty transaction evidence record")
		}
		switch fields[0] {
		case "apt-version":
			if len(fields) != 2 || aptVersion != "" || !versionPattern.MatchString(fields[1]) {
				return errors.New("transaction APT version refused")
			}
			aptVersion = fields[1]
		case "argument":
			if len(fields) != 2 || !installPin.MatchString(fields[1]) {
				return errors.New("transaction argument refused")
			}
			arguments = append(arguments, fields[1])
		case "base-package":
			if len(fields) != 5 || !validPackage(packageIdentity{fields[1], fields[2], fields[3]}) || fields[4] != "installed" {
				return errors.New("transaction inherited package refused")
			}
		case "plan":
			if len(fields) != 5 || plans[fields[2]].Basename != "" {
				return errors.New("transaction plan missing fields or duplicated")
			}
			size, parseErr := strconv.ParseInt(fields[3], 10, 64)
			if parseErr != nil {
				return errors.New("transaction plan size refused")
			}
			plans[fields[2]] = planRecord{fields[1], fields[2], fields[4], size}
		case "archive":
			if len(fields) != 7 || archives[fields[1]].Basename != "" {
				return errors.New("transaction archive missing fields or duplicated")
			}
			size, parseErr := strconv.ParseInt(fields[5], 10, 64)
			if parseErr != nil {
				return errors.New("transaction archive size refused")
			}
			archives[fields[1]] = archiveExpectation{Name: fields[2], Version: fields[3], Architecture: fields[4], Basename: fields[1], Bytes: size, SHA256: fields[6]}
		case "origin":
			if len(fields) != 23 {
				return errors.New("transaction origin missing fields")
			}
			origin, parseErr := parseOriginFields(fields[1:])
			if parseErr != nil {
				return parseErr
			}
			archive, exists := archives[fields[1]]
			if !exists || fields[2] != archive.Name || fields[3] != archive.Version || fields[4] != archive.Architecture {
				return errors.New("transaction origin tuple differs from acquired archive")
			}
			for _, previous := range origins[fields[1]] {
				if originKey(previous) == originKey(origin) {
					return errors.New("transaction origin duplicated")
				}
			}
			origins[fields[1]] = append(origins[fields[1]], origin)
		case "target":
			if len(fields) != 18 {
				return errors.New("transaction target record refused")
			}
		default:
			return errors.New("unexpected or completed transaction evidence refused")
		}
	}
	sort.Strings(arguments)
	if aptVersion != value.APTVersion || strings.Join(arguments, "\n") != strings.Join(value.DirectArguments, "\n") || len(plans) != len(value.Archives) || len(archives) != len(value.Archives) || len(origins) != len(value.Archives) {
		return errors.New("transaction archive set incomplete or detached from recipe")
	}
	for _, expected := range value.Archives {
		plan, ok := plans[expected.Basename]
		observed, archiveOK := archives[expected.Basename]
		observedOrigins := origins[expected.Basename]
		sort.Slice(observedOrigins, func(i, j int) bool { return originKey(observedOrigins[i]) < originKey(observedOrigins[j]) })
		if !ok || !archiveOK || plan.URI != expected.RequestedURI || plan.Bytes != expected.Bytes || plan.SHA256 != expected.SHA256 || observed.Name != expected.Name || observed.Version != expected.Version || observed.Architecture != expected.Architecture || observed.Bytes != expected.Bytes || observed.SHA256 != expected.SHA256 || len(observedOrigins) != len(expected.Origins) {
			return errors.New("transaction archive identity differs from reviewed lock")
		}
		for i := range expected.Origins {
			if originKey(observedOrigins[i]) != originKey(expected.Origins[i]) {
				return errors.New("transaction archive origin set differs from reviewed lock")
			}
		}
	}
	return nil
}

func run(args []string, out io.Writer) error {
	switch {
	case len(args) == 2 && args[0] == "--emit":
		return emit(args[1], out)
	case len(args) == 3 && args[0] == "--from-report":
		raw, err := regularBytes(args[1], maximumInputBytes)
		if err != nil {
			return err
		}
		value, err := generate(raw, args[2])
		if err != nil {
			return err
		}
		encoded, err := json.MarshalIndent(value, "", "  ")
		if err != nil {
			return err
		}
		return writeComplete(out, append(encoded, '\n'))
	case len(args) == 3 && args[0] == "--verify":
		lockRaw, err := regularBytes(args[1], maximumInputBytes)
		if err != nil {
			return err
		}
		transactionRaw, err := regularBytes(args[2], maximumInputBytes)
		if err != nil {
			return err
		}
		return verify(lockRaw, transactionRaw)
	default:
		return errors.New("usage: --from-report REPORT ROOT | --emit ROOT | --verify LOCK TRANSACTION")
	}
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
