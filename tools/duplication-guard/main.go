// The scanner still reports all copies. This boundary accepts only the reviewed
// multiset, not a percentage budget or a baseline silently refreshed by a PR.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	_ "embed"
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
	"strings"
	"time"
	"unicode/utf8"
)

const adoptionRevision = "afd354c2987d92b89156d7bd96ddc34f7172bb8a"
const scannerVersion = "cpd 5.0.16"
const cleanupOwner = 276

// A frozen reference is a historical copy kept byte-for-byte as a compatibility
// oracle. Its text can never be shared, so editing the live file it was copied
// from splits clones into new fragments without adding any duplicated text.
const frozenReferencePrefix = "client/tests/historical/"
const frozenReferenceReason = "Frozen version-4 save-reader reference; changing it would erase the historical compatibility oracle."

// Hash of the generated catalog from the independently measured adoption tree.
// Neither an absent base file nor the adoption SHA permits an invented baseline.
const adoptionCatalogSHA = "2acbd35b5aec09ce46e1797987dd7b32fcefe41449ef1526c0e32ccb6d4889d7"

//go:embed formats.json
var formatData []byte

type location struct {
	Name     string    `json:"name"`
	Start    int       `json:"start"`
	End      int       `json:"end"`
	StartLoc *position `json:"startLoc"`
	EndLoc   *position `json:"endLoc"`
}

// position is the scanner's offset in UTF-16 code units, as JavaScript counts.
type position struct {
	Position *int `json:"position"`
}

type clone struct {
	Format   string   `json:"format"`
	Fragment string   `json:"fragment"`
	First    location `json:"firstFile"`
	Second   location `json:"secondFile"`
	Lines    int      `json:"lines"`
	Tokens   int      `json:"tokens"`
}

type statistics struct {
	Clones           *int `json:"clones"`
	Sources          *int `json:"sources"`
	Lines            *int `json:"lines"`
	Tokens           *int `json:"tokens"`
	DuplicatedLines  *int `json:"duplicatedLines"`
	DuplicatedTokens *int `json:"duplicatedTokens"`
}

type report struct {
	Duplicates *[]clone `json:"duplicates"`
	Statistics *struct {
		DetectionDate string                `json:"detectionDate"`
		Total         statistics            `json:"total"`
		Formats       map[string]statistics `json:"formats"`
	} `json:"statistics"`
}

type entry struct {
	Key          string    `json:"identitySHA256"`
	Format       string    `json:"format"`
	Files        [2]string `json:"files"`
	FragmentSHA  string    `json:"fragmentSHA256"`
	Occurrences  int       `json:"occurrences"`
	CleanupIssue int       `json:"cleanupIssue,omitempty"`
	Reason       string    `json:"reason,omitempty"`
}

type catalog struct {
	Schema           int     `json:"schema"`
	AdoptionRevision string  `json:"adoptionRevision"`
	Scanner          string  `json:"scanner"`
	SettingsSHA      string  `json:"settingsSHA256"`
	Entries          []entry `json:"entries"`
}

// main dispatches bounded scanning, catalog generation or acceptance checking.
func main() {
	var err error
	args := os.Args[1:]
	switch {
	case len(args) == 4 && args[0] == "generate":
		err = generate(args[1], args[2], args[3])
	case len(args) == 4 && args[0] == "scan":
		err = scan(args[1], args[2], args[3])
	case len(args) == 7 && args[0] == "check":
		err = check(args[1], args[2], args[3], args[4], args[5], args[6])
	default:
		err = fmt.Errorf("usage: duplication-guard scan SCANNER OUTPUT CONFIG | generate REPORT CONFIG CATALOG | check REPORT CATALOG BASE-CATALOG CONFIG OWNER BASE-REVISION")
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "DUPLICATION FAIL:", err)
		os.Exit(1)
	}
}

// decode reads exactly one JSON value, optionally rejecting unknown fields.
func decode(path string, value any, strict bool) error {
	data, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	decoder := json.NewDecoder(bytes.NewReader(data))
	if strict {
		decoder.DisallowUnknownFields()
	}
	if err = decoder.Decode(value); err != nil {
		return err
	}
	if decoder.Decode(new(any)) != io.EOF {
		return fmt.Errorf("trailing JSON")
	}
	return nil
}

// digest returns the hexadecimal SHA-256 used to bind policy and clone identity.
func digest(value []byte) string {
	sum := sha256.Sum256(value)
	return hex.EncodeToString(sum[:])
}

// settings binds detection configuration, arguments and the source inventory.
func settings(path string) (string, error) {
	var config map[string]any
	if err := decode(path, &config, false); err != nil {
		return "", fmt.Errorf("settings: %w", err)
	}
	if config == nil {
		return "", fmt.Errorf("settings are missing")
	}
	data, err := json.Marshal(struct {
		Config          map[string]any `json:"config"`
		Arguments       []string       `json:"arguments"`
		SourceSelection string         `json:"sourceSelection"`
		FormatsSHA      string         `json:"formatsSHA256"`
	}{Config: config, Arguments: []string{"--no-gitignore"}, SourceSelection: "tracked-readable-unsuppressed-v1", FormatsSHA: digest(formatData)})
	return digest(data), err
}

// statsValues requires present, nonnegative counters and plausible source totals.
func statsValues(s statistics) ([]int, error) {
	var result []int
	for _, value := range []*int{s.Clones, s.Sources, s.Lines, s.Tokens, s.DuplicatedLines, s.DuplicatedTokens} {
		if value == nil || *value < 0 {
			return nil, fmt.Errorf("missing or negative statistics")
		}
		result = append(result, *value)
	}
	if result[1] == 0 || result[2] == 0 || result[3] == 0 || result[4] > result[2] || result[5] > result[3] {
		return nil, fmt.Errorf("empty or inconsistent source statistics")
	}
	return result, nil
}

// readReport validates clone locations and reconciles format and total counters.
func readReport(path string) (report, error) {
	var value report
	if err := decode(path, &value, false); err != nil {
		return value, fmt.Errorf("report: %w", err)
	}
	if value.Duplicates == nil || value.Statistics == nil || len(value.Statistics.Formats) == 0 {
		return value, fmt.Errorf("missing report statistics or duplicates")
	}
	if _, err := time.Parse(time.RFC3339Nano, value.Statistics.DetectionDate); err != nil {
		return value, fmt.Errorf("missing detection timestamp")
	}
	total, err := statsValues(value.Statistics.Total)
	if err != nil {
		return value, err
	}
	var sums [6]int
	byFormat := make(map[string]int)
	for _, copy := range *value.Duplicates {
		if copy.Format == "" || strings.TrimSpace(copy.Fragment) == "" || copy.Lines < 1 || copy.Tokens < 1 {
			return value, fmt.Errorf("incomplete clone")
		}
		for _, where := range []location{copy.First, copy.Second} {
			if where.Name == "" || filepath.IsAbs(where.Name) || filepath.ToSlash(filepath.Clean(where.Name)) != where.Name || strings.HasPrefix(where.Name, "../") || where.Start < 1 || where.End < where.Start {
				return value, fmt.Errorf("invalid clone location")
			}
		}
		byFormat[copy.Format]++
	}
	for format, stats := range value.Statistics.Formats {
		values, err := statsValues(stats)
		if err != nil {
			return value, err
		}
		if values[0] != byFormat[format] {
			return value, fmt.Errorf("inconsistent format statistics")
		}
		delete(byFormat, format)
		for i, v := range values {
			sums[i] += v
		}
	}
	if len(byFormat) != 0 || total[0] != len(*value.Duplicates) {
		return value, fmt.Errorf("inconsistent clone statistics")
	}
	for i, v := range sums {
		if v != total[i] {
			return value, fmt.Errorf("inconsistent total statistics")
		}
	}
	return value, nil
}

// identity names a clone by language, file pair and content rather than line offset.
func identity(copy clone) entry {
	files := [2]string{copy.First.Name, copy.Second.Name}
	if files[1] < files[0] {
		files[0], files[1] = files[1], files[0]
	}
	e := entry{Format: copy.Format, Files: files, FragmentSHA: digest([]byte(copy.Fragment)), Occurrences: 1}
	key, _ := json.Marshal([]string{e.Format, e.Files[0], e.Files[1], e.FragmentSHA})
	e.Key = digest(key)
	return e
}

// generate proposes current occurrences while preserving retained review annotations.
func generate(reportPath, configPath, catalogPath string) error {
	r, err := readReport(reportPath)
	if err != nil {
		return err
	}
	sha, err := settings(configPath)
	if err != nil {
		return err
	}
	_, previous, err := readCatalog(catalogPath)
	if err != nil && !errors.Is(err, os.ErrNotExist) {
		return fmt.Errorf("existing catalog annotations: %w", err)
	}
	entries := make(map[string]entry)
	for _, copy := range *r.Duplicates {
		e := identity(copy)
		if _, known := previous[e.Key]; !known && len(previous) > 0 && frozenPair(e.Files) {
			// A split of an existing frozen-reference clone is accepted by
			// check's base proof, never by a new catalog entry.
			continue
		}
		if existing, ok := entries[e.Key]; ok {
			e.Occurrences = existing.Occurrences + 1
		}
		e.CleanupIssue = cleanupOwner
		if frozenPair(e.Files) {
			e.CleanupIssue = 0
			e.Reason = frozenReferenceReason
		} else if e.Format == "csv" && strings.HasPrefix(e.Files[0], "docs/evidence/") && strings.HasPrefix(e.Files[1], "docs/evidence/") {
			e.CleanupIssue = 0
			e.Reason = "Before/after measurement records preserve the original observations, including unchanged rows."
		}
		if old, ok := previous[e.Key]; ok {
			e.CleanupIssue, e.Reason = old.CleanupIssue, old.Reason
		}
		entries[e.Key] = e
	}
	value := catalog{Schema: 1, AdoptionRevision: adoptionRevision, Scanner: scannerVersion, SettingsSHA: sha, Entries: []entry{}}
	for _, e := range entries {
		value.Entries = append(value.Entries, e)
	}
	sort.Slice(value.Entries, func(i, j int) bool { return value.Entries[i].Key < value.Entries[j].Key })
	data, err := json.MarshalIndent(value, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(catalogPath, append(data, '\n'), 0o644)
}

// readCatalog requires fixed policy, unique identities and one ownership rationale.
func readCatalog(path string) (catalog, map[string]entry, error) {
	var value catalog
	if err := decode(path, &value, true); err != nil {
		return value, nil, fmt.Errorf("catalog: %w", err)
	}
	if value.Schema != 1 || value.AdoptionRevision != adoptionRevision || value.Scanner != scannerVersion || len(value.SettingsSHA) != 64 || value.Entries == nil {
		return value, nil, fmt.Errorf("invalid catalog policy")
	}
	entries := make(map[string]entry)
	for _, e := range value.Entries {
		key, _ := json.Marshal([]string{e.Format, e.Files[0], e.Files[1], e.FragmentSHA})
		if e.Key != digest(key) || e.Occurrences < 1 || e.Format == "" || e.Files[0] == "" || e.Files[0] > e.Files[1] || len(e.FragmentSHA) != 64 {
			return value, nil, fmt.Errorf("invalid catalog identity")
		}
		if _, exists := entries[e.Key]; exists {
			return value, nil, fmt.Errorf("duplicate catalog identity")
		}
		if (e.CleanupIssue == cleanupOwner) == (strings.TrimSpace(e.Reason) != "") || (e.CleanupIssue != 0 && e.CleanupIssue != cleanupOwner) {
			return value, nil, fmt.Errorf("entry %s needs one cleanup owner or deliberate-copy reason", e.Key)
		}
		entries[e.Key] = e
	}
	return value, entries, nil
}

// check rejects catalog growth, unaccepted copies, stale entries and unproven ownership.
func check(reportPath, catalogPath, basePath, configPath, ownerPath, revision string) error {
	r, err := readReport(reportPath)
	if err != nil {
		return err
	}
	c, accepted, err := readCatalog(catalogPath)
	if err != nil {
		return err
	}
	sha, err := settings(configPath)
	if err != nil {
		return err
	}
	if c.SettingsSHA != sha {
		return fmt.Errorf("detection settings changed")
	}
	if basePath == "" {
		if revision != adoptionRevision {
			return fmt.Errorf("catalog bootstrap requires exact adoption revision")
		}
		data, err := json.Marshal(c)
		if err != nil || digest(append(data, '\n')) != adoptionCatalogSHA {
			return fmt.Errorf("catalog bootstrap requires the exact reviewed adoption catalog")
		}
	} else {
		base, previous, err := readCatalog(basePath)
		if err != nil {
			return err
		}
		if base.SettingsSHA != c.SettingsSHA {
			return fmt.Errorf("catalog settings policy changed")
		}
		for key, e := range accepted {
			old, ok := previous[key]
			if !ok || e.Occurrences > old.Occurrences {
				return fmt.Errorf("catalog growth: %s; share the code instead of adding accepted copies", key)
			}
		}
	}
	for _, e := range accepted {
		if e.CleanupIssue == cleanupOwner {
			var owner struct {
				Number int             `json:"number"`
				State  string          `json:"state"`
				PR     json.RawMessage `json:"pull_request"`
			}
			if err := decode(ownerPath, &owner, false); err != nil {
				return fmt.Errorf("open cleanup owner: %w", err)
			}
			if owner.Number != cleanupOwner || owner.State != "open" || len(owner.PR) != 0 {
				return fmt.Errorf("open cleanup owner #%d is not proven", cleanupOwner)
			}
			break
		}
	}
	observed := make(map[string]int)
	for _, copy := range *r.Duplicates {
		e := identity(copy)
		observed[e.Key]++
		if observed[e.Key] > accepted[e.Key].Occurrences {
			shared := false
			if basePath != "" {
				if shared, err = sharedAtBase(copy, revision); err != nil {
					return err
				}
			}
			if !shared {
				return fmt.Errorf("unaccepted clone: %s:%d and %s:%d; share the code and regenerate the shrinking catalog", copy.First.Name, copy.First.Start, copy.Second.Name, copy.Second.Start)
			}
			// Accepted by the base proof, not by this identity's catalog entry.
			observed[e.Key]--
		}
	}
	for key, e := range accepted {
		if observed[key] != e.Occurrences {
			return fmt.Errorf("stale catalog entry: %s and %s; regenerate the catalog with the cleanup", e.Files[0], e.Files[1])
		}
	}
	fmt.Printf("DUPLICATION PASS: %d clones, %d duplicated lines; every identity and occurrence accepted, catalog only shrinks\n", len(*r.Duplicates), *r.Statistics.Total.DuplicatedLines)
	return nil
}

// frozenPair reports whether either file of a clone pair is a frozen reference.
func frozenPair(files [2]string) bool {
	return strings.HasPrefix(files[0], frozenReferencePrefix) || strings.HasPrefix(files[1], frozenReferencePrefix)
}

// sharedAtBase proves that a clone between one live file and one frozen
// reference repeats text both files already held at the base revision: the
// reference is byte-identical to its base, and the exact duplicated span of the
// live file occurs verbatim in that file's base. An edit inside such a clone
// only splits it. Every other clone, and any proof that cannot be completed, is
// not shared.
func sharedAtBase(copy clone, revision string) (bool, error) {
	first := strings.HasPrefix(copy.First.Name, frozenReferencePrefix)
	second := strings.HasPrefix(copy.Second.Name, frozenReferencePrefix)
	if first == second {
		return false, nil
	}
	frozen, live, span := copy.First.Name, copy.Second.Name, copy.Second
	if second {
		frozen, live, span = live, frozen, copy.First
	}
	if span.StartLoc == nil || span.EndLoc == nil || span.StartLoc.Position == nil || span.EndLoc.Position == nil {
		return false, nil
	}
	for _, name := range []string{frozen, live} {
		if filepath.IsAbs(name) || filepath.ToSlash(filepath.Clean(name)) != name || strings.HasPrefix(name, "../") || strings.Contains(name, ":") {
			return false, nil
		}
	}
	if !regexp.MustCompile(`^[0-9a-f]{40}$`).MatchString(revision) {
		return false, fmt.Errorf("invalid base revision for the frozen-reference proof")
	}
	baseFrozen, ok := atRevision(revision, frozen)
	if !ok {
		return false, nil
	}
	current, err := os.ReadFile(frozen)
	if err != nil || !bytes.Equal(current, baseFrozen) {
		return false, nil
	}
	baseLive, ok := atRevision(revision, live)
	if !ok {
		return false, nil
	}
	headLive, err := os.ReadFile(live)
	if err != nil {
		return false, nil
	}
	duplicated, ok := byteSpan(headLive, span)
	if !ok {
		return false, nil
	}
	return bytes.Contains(baseLive, duplicated), nil
}

// byteSpan returns the exact duplicated bytes of one clone side. The pinned
// scanner reports positions as byte offsets; the offsets must land on the
// reported start and end lines, so a misread offset refuses rather than
// proving the wrong text.
func byteSpan(data []byte, span location) ([]byte, bool) {
	start, end := *span.StartLoc.Position, *span.EndLoc.Position
	if start < 0 || end <= start || end > len(data) {
		return nil, false
	}
	if bytes.Count(data[:start], []byte("\n"))+1 != span.Start || bytes.Count(data[:end], []byte("\n"))+1 != span.End {
		return nil, false
	}
	out := data[start:end]
	if !utf8.Valid(out) || len(bytes.TrimSpace(out)) == 0 {
		return nil, false
	}
	return out, true
}

// atRevision reads one tracked file's bytes at a commit; absence is not an error.
func atRevision(revision, name string) ([]byte, bool) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	data, err := exec.CommandContext(ctx, "git", "show", revision+":"+name).Output()
	if err != nil {
		return nil, false
	}
	return data, true
}

// scan requires a fresh pinned report consistent with the independently staged sources.
func scan(scanner, output, configPath string) error {
	scanner, err := filepath.Abs(scanner)
	if err != nil {
		return err
	}
	output, err = filepath.Abs(output)
	if err != nil {
		return err
	}
	configPath, err = filepath.Abs(configPath)
	if err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), time.Minute)
	defer cancel()
	version, err := exec.CommandContext(ctx, scanner, "--version").CombinedOutput()
	if err != nil || strings.TrimSpace(string(version)) != scannerVersion {
		return fmt.Errorf("expected scanner %s, got %q (%v)", scannerVersion, version, err)
	}
	reportPath := filepath.Join(output, "jscpd-report.json")
	if _, err := os.Stat(output); !os.IsNotExist(err) {
		return fmt.Errorf("scan requires a fresh report directory")
	}
	stage, expected, err := stageSources(ctx, configPath)
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	var result bytes.Buffer
	started := time.Now()
	cmd := exec.CommandContext(ctx, scanner, "--no-gitignore", "--no-colors", "--no-tips", "--reporters", "console,json", "--output", output, "--config", configPath, ".")
	cmd.Dir = stage
	cmd.Stdout = io.MultiWriter(os.Stdout, &result)
	cmd.Stderr = cmd.Stdout
	scanErr := cmd.Run()
	if ctx.Err() != nil {
		return fmt.Errorf("scanner deadline: %w", ctx.Err())
	}
	r, err := readReport(reportPath)
	if err != nil {
		return err
	}
	detected, _ := time.Parse(time.RFC3339Nano, r.Statistics.DetectionDate)
	if detected.Before(started.Add(-time.Second)) || detected.After(time.Now().Add(time.Second)) {
		return fmt.Errorf("report was not produced during this scan")
	}
	for format, count := range expected {
		actual, ok := r.Statistics.Formats[format]
		// Upstream's statistics omit files below its 50-token threshold,
		// even though the walker and tokenizer read them. The independent
		// manifest proves the readable input scope; do not equate selected
		// files with threshold-eligible files or hide that distinction.
		if ok && (actual.Sources == nil || *actual.Sources > count) {
			return fmt.Errorf("incomplete source coverage: %s expected %d", format, count)
		}
	}
	for format := range r.Statistics.Formats {
		if expected[format] == 0 {
			return fmt.Errorf("unexpected analyzed source format")
		}
	}
	for _, copy := range *r.Duplicates {
		for _, where := range []location{copy.First, copy.Second} {
			if _, err := os.Stat(filepath.Join(stage, where.Name)); err != nil {
				return fmt.Errorf("clone outside selected tracked sources")
			}
		}
		data, err := os.ReadFile(filepath.Join(stage, copy.First.Name))
		if err != nil || !bytes.Contains(data, []byte(copy.Fragment)) {
			return fmt.Errorf("clone fragment is not in its selected source")
		}
	}
	manifest, _ := json.MarshalIndent(expected, "", "  ")
	if err := os.WriteFile(filepath.Join(output, "selected-source-counts.json"), append(manifest, '\n'), 0o600); err != nil {
		return err
	}
	count := len(*r.Duplicates)
	log := result.String()
	if !strings.Contains(log, fmt.Sprintf("Found %d clones.\n", count)) || !strings.Contains(log, "JSON report saved to "+reportPath+"\n") {
		return fmt.Errorf("scanner completion and report count do not agree")
	}
	thresholdErrors := 0
	for _, line := range strings.Split(log, "\n") {
		if strings.HasPrefix(line, "ERROR:") {
			if !strings.HasPrefix(line, "ERROR: jscpd found too many duplicates (") || !strings.HasSuffix(line, "over threshold (0.0%)") {
				return fmt.Errorf("scanner failed: %s", line)
			}
			thresholdErrors++
		}
	}
	if scanErr != nil {
		exit, ok := scanErr.(*exec.ExitError)
		if !ok || exit.ExitCode() != 1 || count == 0 || thresholdErrors != 1 {
			return fmt.Errorf("scanner failed: %w", scanErr)
		}
	} else if count != 0 || thresholdErrors != 0 {
		return fmt.Errorf("scanner did not enforce the zero threshold")
	}
	return nil
}

// stageSources copies readable tracked language sources without ignore-file suppression.
func stageSources(ctx context.Context, configPath string) (stage string, counts map[string]int, err error) {
	var formats map[string]string
	if err = json.Unmarshal(formatData, &formats); err != nil {
		return "", nil, err
	}
	var config struct {
		Ignore []string `json:"ignore"`
	}
	if err = decode(configPath, &config, false); err != nil {
		return "", nil, err
	}
	var ignores []*regexp.Regexp
	for _, pattern := range config.Ignore {
		// The pinned defaults use only literals, '*' and '**/'. Reject new
		// glob syntax instead of disagreeing silently with upstream globset.
		if strings.ContainsAny(pattern, "?[]{}\\") {
			return "", nil, fmt.Errorf("unsupported detection glob")
		}
		quoted := regexp.QuoteMeta(pattern)
		quoted = strings.ReplaceAll(quoted, `\*\*/`, "(?:.*/)?")
		quoted = strings.ReplaceAll(quoted, `\*\*`, ".*")
		quoted = strings.ReplaceAll(quoted, `\*`, "[^/]*")
		ignores = append(ignores, regexp.MustCompile("^"+quoted+"$"))
	}
	tracked, err := exec.CommandContext(ctx, "git", "ls-files", "-z", "--cached").Output()
	if err != nil {
		return "", nil, fmt.Errorf("tracked source inventory: %w", err)
	}
	stage, err = os.MkdirTemp("", "war-duplication-source-")
	if err != nil {
		return "", nil, err
	}
	defer func() {
		if err != nil {
			os.RemoveAll(stage)
		}
	}()
	counts = make(map[string]int)
	for _, name := range strings.Split(string(tracked), "\x00") {
		if name == "" {
			continue
		}
		if filepath.IsAbs(name) || filepath.ToSlash(filepath.Clean(name)) != name || strings.HasPrefix(name, "../") {
			return stage, nil, fmt.Errorf("invalid tracked path")
		}
		ignored, directoryExcluded := false, false
		for i, pattern := range ignores {
			if pattern.MatchString(name) {
				ignored = true
				directoryExcluded = strings.HasSuffix(config.Ignore[i], "/**")
				break
			}
		}
		if ignored && !directoryExcluded {
			continue
		}
		base := filepath.Base(name)
		if base == ".ignore" || base == ".gitignore" {
			continue
		}
		info, statErr := os.Lstat(name)
		if statErr != nil || !info.Mode().IsRegular() || info.Mode().Perm()&0o444 == 0 {
			return stage, nil, fmt.Errorf("unreadable or non-regular tracked source: %s", name)
		}
		// Known binary assets are not language inputs. For other paths, read
		// before language detection so unreadability cannot erase shebangs.
		ext := strings.TrimPrefix(filepath.Ext(name), ".")
		format := formats[ext]
		if format == "" && info.Size() > 1048576 {
			file, openErr := os.Open(name)
			if openErr != nil {
				return stage, nil, fmt.Errorf("unreadable tracked source: %s", name)
			}
			prefix, prefixErr := io.ReadAll(io.LimitReader(file, 4096))
			closeErr := file.Close()
			if prefixErr != nil || closeErr != nil {
				return stage, nil, fmt.Errorf("unreadable tracked source: %s", name)
			}
			if bytes.HasPrefix(prefix, []byte("#!")) {
				return stage, nil, fmt.Errorf("oversize tracked source: %s", name)
			}
			continue
		}
		data, readErr := os.ReadFile(name)
		if readErr != nil {
			return stage, nil, fmt.Errorf("unreadable tracked source: %s", name)
		}
		if format == "" {
			first, _, _ := strings.Cut(string(data), "\n")
			if strings.HasPrefix(first, "#!") {
				for _, shell := range []struct{ needle, format string }{{"python", "python"}, {"node", "javascript"}, {"ruby", "ruby"}, {"bash", "bash"}, {"/sh", "bash"}, {"perl", "perl"}, {"php", "php"}} {
					if strings.Contains(first, shell.needle) {
						format = shell.format
						break
					}
				}
			}
		}
		if format == "" {
			continue
		}
		if directoryExcluded {
			return stage, nil, fmt.Errorf("tracked source in excluded directory: %s; keep source outside generated/cache directories", name)
		}
		if len(data) > 1048576 {
			return stage, nil, fmt.Errorf("oversize tracked source: %s", name)
		}
		if !utf8.Valid(data) {
			return stage, nil, fmt.Errorf("invalid UTF-8 tracked source: %s", name)
		}
		for _, directive := range []string{"jscpd:" + "ignore-start", "jscpd:" + "ignore-end"} {
			if bytes.Contains(data, []byte(directive)) {
				return stage, nil, fmt.Errorf("inline duplication suppression: %s", name)
			}
		}
		lines := bytes.Count(data, []byte("\n"))
		if len(data) > 0 && data[len(data)-1] != '\n' {
			lines++
		}
		if lines < 5 || len(data) < 50 {
			continue
		}
		destination := filepath.Join(stage, filepath.FromSlash(name))
		if err = os.MkdirAll(filepath.Dir(destination), 0o700); err != nil {
			return stage, nil, err
		}
		if err = os.WriteFile(destination, data, 0o600); err != nil {
			return stage, nil, err
		}
		counts[format]++
	}
	if len(counts) == 0 {
		return stage, nil, fmt.Errorf("empty tracked source inventory")
	}
	return stage, counts, nil
}
