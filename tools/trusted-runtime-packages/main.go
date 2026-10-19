// Command trusted-runtime-packages prepares an expected installed identity set.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
)

const maximumLockBytes = 1024 * 1024

type packageIdentity struct {
	Name         string `json:"name"`
	Version      string `json:"version"`
	Architecture string `json:"architecture"`
}

type packageLock struct {
	Schema          int               `json:"schema"`
	Architecture    string            `json:"architecture"`
	RuntimeManifest string            `json:"runtime_manifest"`
	Snapshot        string            `json:"snapshot"`
	Packages        []packageIdentity `json:"packages"`
}

type reportFile struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Bytes  int64  `json:"bytes"`
}

type coldReport struct {
	Schema   int    `json:"schema"`
	Evidence string `json:"evidence"`
	Image    struct {
		Id, Os, Architecture string
		Config               struct {
			User, WorkingDir string
			Entrypoint       []string
		}
	} `json:"image"`
	Inventory struct {
		Architecture string            `json:"architecture"`
		Packages     []packageIdentity `json:"installed_packages"`
		Files        []reportFile      `json:"apt_inputs"`
		Engine       string            `json:"engine_sha256"`
	} `json:"inventory"`
	Recipe              []reportFile `json:"recipe_files"`
	EngineVersion       string       `json:"caller_engine_version"`
	EngineArchiveSHA512 string       `json:"caller_engine_archive_sha512"`
}

var packageName = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)
var packageVersion = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$`)
var manifestDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var snapshotID = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z$`)
var runtimeFrom = regexp.MustCompile(`(?m)^FROM ubuntu:24\.04@(sha256:[0-9a-f]{64})\s*$`)
var snapshotSourceRewrite = regexp.MustCompile(`s#\^URIs: \.\*#URIs: https://snapshot[.]ubuntu[.]com/ubuntu/([0-9]{8}T[0-9]{6}Z)/#`)
var installPin = regexp.MustCompile(`^([a-z0-9][a-z0-9+.-]*)=([A-Za-z0-9][A-Za-z0-9+.:~_-]*)$`)
var fileDigest = regexp.MustCompile(`^[0-9a-f]{64}$`)
var archiveDigest = regexp.MustCompile(`^[0-9a-f]{128}$`)

// minimumRecipeFiles covers the original cold-report producer, before package locks existed.
var minimumRecipeFiles = []string{
	".github/containers/trusted-regressions.Dockerfile", "tools/build-trusted-regression-runtime.sh", "tools/install-ci-godot.sh",
	"tools/trusted-regression-lifecycle.sh", "tools/trusted-regression-phase.sh", "tools/trusted-phase-command.sh",
	"tools/process-group-lifecycle.sh", "tools/capture-trusted-runtime-inventory.sh", "tools/inspect-trusted-runtime.sh",
	"tools/trusted-runtime-inventory/main.go", ".github/containers/trusted-runtime-bases.sources.json",
	".github/containers/trusted-runtime-bases.lock.json", "tools/trusted-runtime-bases/main.go", "tools/build-locked-trusted-runtime.sh",
}

// decode reads one complete bounded JSON document; a valid prefix is insufficient.
func decode(raw []byte, value any, strict bool) error {
	if len(raw) > maximumLockBytes {
		return errors.New("package input exceeds bound")
	}
	decoder := json.NewDecoder(bytes.NewReader(raw))
	if strict {
		decoder.DisallowUnknownFields()
	}
	if err := decoder.Decode(value); err != nil {
		return err
	}
	var trailing any
	if decoder.Decode(&trailing) != io.EOF {
		return errors.New("package input has trailing or incomplete content")
	}
	return nil
}

// validate requires one bounded, sorted installed identity for every package name.
func validate(value packageLock) error {
	if value.Schema != 1 || value.Architecture != "amd64" || !manifestDigest.MatchString(value.RuntimeManifest) || !snapshotID.MatchString(value.Snapshot) || len(value.Packages) == 0 || len(value.Packages) > 2048 {
		return errors.New("package lock identity refused")
	}
	previous := ""
	for _, item := range value.Packages {
		if !packageName.MatchString(item.Name) || !packageVersion.MatchString(item.Version) || (item.Architecture != "amd64" && item.Architecture != "all") || item.Name <= previous {
			return errors.New("package lock must contain unique sorted installed identities")
		}
		previous = item.Name
	}
	return nil
}

// decodeLock accepts only the complete supported lock schema and valid identities.
func decodeLock(raw []byte) (packageLock, error) {
	var value packageLock
	if err := decode(raw, &value, true); err != nil {
		return value, err
	}
	return value, validate(value)
}

// joinRecipe binds the expectation to the actual immutable base, snapshot and direct pins.
func joinRecipe(value packageLock, recipe []byte) error {
	const required = "\nCOPY expected-packages.tsv verify-trusted-runtime-packages.sh /tmp/\nRUN bash /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv \\\n    && rm /tmp/verify-trusted-runtime-packages.sh /tmp/expected-packages.tsv\n"
	if bytes.Count(recipe, []byte(required)) != 1 {
		return errors.New("mandatory package verifier recipe missing, altered or repeated")
	}
	bases, snapshots := runtimeFrom.FindAllSubmatch(recipe, -1), snapshotSourceRewrite.FindAllSubmatch(recipe, -1)
	if len(bases) != 1 || len(snapshots) != 1 || string(bases[0][1]) != value.RuntimeManifest || string(snapshots[0][1]) != value.Snapshot {
		return errors.New("package lock does not match runtime base or snapshot")
	}
	versions := make(map[string]string, len(value.Packages))
	for _, item := range value.Packages {
		versions[item.Name] = item.Version
	}
	pins, err := parseInstallPins(recipe)
	if err != nil {
		return err
	}
	for name, version := range pins {
		if versions[name] != version {
			return errors.New("package lock does not match direct install pin")
		}
	}
	return nil
}

// parseInstallPins checks every argument rather than selecting only already-pinned substrings.
func parseInstallPins(recipe []byte) (map[string]string, error) {
	const command = "apt-get install -y --no-install-recommends"
	if strings.Count(string(recipe), command) != 1 {
		return nil, errors.New("runtime install declaration missing or repeated")
	}
	_, install, found := strings.Cut(string(recipe), command)
	if !found {
		return nil, errors.New("runtime install declaration missing")
	}
	install, _, found = strings.Cut(install, "&&")
	if !found {
		return nil, errors.New("runtime install boundary missing")
	}
	pins := map[string]string{}
	for _, argument := range strings.Fields(strings.ReplaceAll(install, "\\\n", " ")) {
		pin := installPin.FindStringSubmatch(argument)
		if len(pin) != 3 || pins[pin[1]] != "" {
			return nil, errors.New("every runtime install argument must be a unique exact package-version pin")
		}
		pins[pin[1]] = pin[2]
	}
	if len(pins) == 0 {
		return nil, errors.New("runtime direct pins missing")
	}
	return pins, nil
}

// readInput refuses links, special files and complete reads over the fixed bound.
func readInput(path string) ([]byte, error) {
	if info, err := os.Lstat(path); err != nil || !info.Mode().IsRegular() || info.Size() > maximumLockBytes {
		return nil, errors.New("package input is not a bounded regular file")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer file.Close()
	raw, err := io.ReadAll(io.LimitReader(file, maximumLockBytes+1))
	if err != nil || len(raw) > maximumLockBytes {
		return nil, errors.New("package input read incomplete")
	}
	return raw, nil
}

// emit writes the complete canonical expectation only after lock and recipe validation.
func emit(root string, out io.Writer) error {
	dir := filepath.Join(root, ".github", "containers")
	raw, err := readInput(filepath.Join(dir, "trusted-runtime-packages.lock.json"))
	if err != nil {
		return err
	}
	value, err := decodeLock(raw)
	if err != nil {
		return err
	}
	recipe, err := readInput(filepath.Join(dir, "trusted-regressions.Dockerfile"))
	if err != nil {
		return err
	}
	if err = joinRecipe(value, recipe); err != nil {
		return err
	}
	var content bytes.Buffer
	for _, item := range value.Packages {
		fmt.Fprintf(&content, "package\t%s\t%s\t%s\tinstalled\n", item.Name, item.Version, item.Architecture)
	}
	n, err := out.Write(content.Bytes())
	if err != nil || n != content.Len() {
		return errors.New("package expectation write incomplete")
	}
	return nil
}

// generate creates a reviewable expectation, not authentication of the report's origin.
func generate(raw, recipe []byte) (packageLock, error) {
	var observed coldReport
	var value packageLock
	if err := decode(raw, &observed, false); err != nil {
		return value, err
	}
	if err := validateReport(observed); err != nil {
		return value, err
	}
	pins, err := parseInstallPins(recipe)
	if err != nil {
		return value, err
	}
	if len(observed.Inventory.Packages) <= len(pins) {
		return value, errors.New("cold report lacks installed dependency identities")
	}
	bases, snapshots := runtimeFrom.FindAllSubmatch(recipe, -1), snapshotSourceRewrite.FindAllSubmatch(recipe, -1)
	if len(bases) != 1 || len(snapshots) != 1 {
		return value, errors.New("runtime recipe identity missing")
	}
	value = packageLock{1, "amd64", string(bases[0][1]), string(snapshots[0][1]), observed.Inventory.Packages}
	sort.Slice(value.Packages, func(i, j int) bool { return value.Packages[i].Name < value.Packages[j].Name })
	if err := validate(value); err != nil {
		return value, err
	}
	return value, joinRecipe(value, recipe)
}

// reportFileSet refuses missing, duplicated, malformed or unbounded evidence identities.
func reportFileSet(files []reportFile, absolute bool) (map[string]bool, error) {
	if len(files) == 0 || len(files) > 256 {
		return nil, errors.New("cold report file identities missing or over bound")
	}
	seen := map[string]bool{}
	for _, file := range files {
		if file.Path == "" || filepath.Clean(file.Path) != file.Path || filepath.IsAbs(file.Path) != absolute || file.Path == "." || strings.HasPrefix(file.Path, "../") || strings.ContainsAny(file.Path, "\r\n\x00") || !fileDigest.MatchString(file.SHA256) || file.Bytes <= 0 || file.Bytes > 256*1024*1024 || seen[file.Path] {
			return nil, errors.New("cold report file identity refused")
		}
		seen[file.Path] = true
	}
	return seen, nil
}

// validateReport requires the complete observation envelope, without authenticating its origin.
func validateReport(observed coldReport) error {
	if observed.Schema != 1 || observed.Evidence != "observed-cold-build-inventory-only" || !manifestDigest.MatchString(observed.Image.Id) || observed.Image.Os != "linux" || observed.Image.Architecture != "amd64" || observed.Inventory.Architecture != "amd64" || observed.Image.Config.User != "1001:1001" || observed.Image.Config.WorkingDir != "/project" || len(observed.Image.Config.Entrypoint) != 1 || observed.Image.Config.Entrypoint[0] != "/usr/local/bin/godot" || !fileDigest.MatchString(observed.Inventory.Engine) || !packageVersion.MatchString(observed.EngineVersion) || !archiveDigest.MatchString(observed.EngineArchiveSHA512) {
		return errors.New("cold report identity refused")
	}
	apt, err := reportFileSet(observed.Inventory.Files, true)
	if err != nil {
		return err
	}
	for _, required := range []string{"/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt"} {
		if !apt[required] {
			return errors.New("cold report APT evidence incomplete")
		}
	}
	signed, indexes := false, false
	for path := range apt {
		signed = signed || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.HasSuffix(path, "_InRelease"))
		indexes = indexes || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.Contains(filepath.Base(path), "_Packages"))
	}
	if !signed || !indexes {
		return errors.New("cold report APT indexes missing")
	}
	recipes, err := reportFileSet(observed.Recipe, false)
	if err != nil {
		return err
	}
	for _, required := range minimumRecipeFiles {
		if !recipes[required] {
			return errors.New("cold report recipe evidence incomplete")
		}
	}
	return nil
}

// main reports validation failures with a nonzero exit and no success output.
func main() {
	err := run(os.Args[1:], os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

// run dispatches bounded report generation or validated expectation emission.
func run(args []string, out io.Writer) error {
	if len(args) == 2 && args[0] == "--emit" {
		return emit(args[1], out)
	}
	if len(args) == 3 && args[0] == "--from-report" {
		raw, err := readInput(args[1])
		if err != nil {
			return err
		}
		recipe, err := readInput(filepath.Join(args[2], ".github", "containers", "trusted-regressions.Dockerfile"))
		if err != nil {
			return err
		}
		value, err := generate(raw, recipe)
		if err != nil {
			return err
		}
		encoder := json.NewEncoder(out)
		encoder.SetIndent("", "  ")
		return encoder.Encode(value)
	}
	return errors.New("usage: --emit ROOT | --from-report REPORT ROOT")
}
