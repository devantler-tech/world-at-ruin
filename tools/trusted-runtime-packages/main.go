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

var packageName = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)
var packageVersion = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$`)
var manifestDigest = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)
var snapshotID = regexp.MustCompile(`^[0-9]{8}T[0-9]{6}Z$`)
var runtimeFrom = regexp.MustCompile(`(?m)^FROM ubuntu:24\.04@(sha256:[0-9a-f]{64})\s*$`)
var snapshotSetting = regexp.MustCompile(`APT::Snapshot "([0-9]{8}T[0-9]{6}Z)";`)
var installPin = regexp.MustCompile(`\b([a-z0-9][a-z0-9+.-]*)=([A-Za-z0-9][A-Za-z0-9+.:~_-]*)`)

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
	bases, snapshots := runtimeFrom.FindAllSubmatch(recipe, -1), snapshotSetting.FindAllSubmatch(recipe, -1)
	if len(bases) != 1 || len(snapshots) != 1 || string(bases[0][1]) != value.RuntimeManifest || string(snapshots[0][1]) != value.Snapshot {
		return errors.New("package lock does not match runtime base or snapshot")
	}
	versions := make(map[string]string, len(value.Packages))
	for _, item := range value.Packages {
		versions[item.Name] = item.Version
	}
	_, install, found := strings.Cut(string(recipe), "apt-get install -y --no-install-recommends")
	if !found {
		return errors.New("runtime install declaration missing")
	}
	install, _, found = strings.Cut(install, "&&")
	if !found {
		return errors.New("runtime install boundary missing")
	}
	pins := installPin.FindAllSubmatch([]byte(install), -1)
	if len(pins) == 0 {
		return errors.New("runtime direct pins missing")
	}
	for _, pin := range pins {
		if versions[string(pin[1])] != string(pin[2]) {
			return errors.New("package lock does not match direct install pin")
		}
	}
	return nil
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
	var observed struct {
		Schema   int    `json:"schema"`
		Evidence string `json:"evidence"`
		Image    struct {
			Os, Architecture string
			Config           struct {
				User, WorkingDir string
				Entrypoint       []string
			}
		} `json:"image"`
		Inventory struct {
			Architecture string            `json:"architecture"`
			Packages     []packageIdentity `json:"installed_packages"`
		} `json:"inventory"`
	}
	var value packageLock
	if err := decode(raw, &observed, false); err != nil {
		return value, err
	}
	if observed.Schema != 1 || observed.Evidence != "observed-cold-build-inventory-only" || observed.Image.Os != "linux" || observed.Image.Architecture != "amd64" || observed.Inventory.Architecture != "amd64" || observed.Image.Config.User != "1001:1001" || observed.Image.Config.WorkingDir != "/project" || len(observed.Image.Config.Entrypoint) != 1 || observed.Image.Config.Entrypoint[0] != "/usr/local/bin/godot" {
		return value, errors.New("cold report identity refused")
	}
	bases, snapshots := runtimeFrom.FindAllSubmatch(recipe, -1), snapshotSetting.FindAllSubmatch(recipe, -1)
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

func main() {
	err := run(os.Args[1:], os.Stdout)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

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
