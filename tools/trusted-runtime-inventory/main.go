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
	packages, files := map[string]string{}, map[string]bool{}
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
			if err != nil || size <= 0 || size > 256*1024*1024 || filepath.Clean(path) != path || strings.ContainsAny(path, "\r\x00") || files[path] || len(files) >= 256 || !allowedInput(path) {
				return fail()
			}
			files[path] = true
			signed = signed || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.HasSuffix(path, "_InRelease"))
			indexes = indexes || (strings.HasPrefix(path, "/var/lib/apt/lists/") && strings.Contains(filepath.Base(path), "_Packages"))
			out.Files = append(out.Files, ingredientFile{path, fields[1], size})
		case "engine":
			if len(fields) != 2 || out.Engine != "" || fields[1] != expectedEngine {
				return fail()
			}
			out.Engine = fields[1]
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
		if !files[required] {
			return fail()
		}
	}
	if !signed || !indexes || out.Engine == "" || len(packages) <= len(directPins) {
		return fail()
	}
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
	for _, path := range []string{".github/containers/trusted-regressions.Dockerfile", "tools/build-trusted-regression-runtime.sh", "tools/install-ci-godot.sh", "tools/trusted-regression-lifecycle.sh", "tools/trusted-regression-phase.sh", "tools/trusted-phase-command.sh", "tools/process-group-lifecycle.sh", "tools/capture-trusted-runtime-inventory.sh", "tools/inspect-trusted-runtime.sh", "tools/trusted-runtime-inventory/main.go"} {
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
