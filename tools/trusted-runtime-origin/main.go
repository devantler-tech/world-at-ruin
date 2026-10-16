// Command trusted-runtime-origin joins acquired runtime archives to APT's
// authenticated package targets. It emits diagnostic evidence, never authority.
package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
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
	"syscall"
)

const (
	maximumManifestBytes = 1024 * 1024
	maximumIndexBytes    = 256 * 1024 * 1024
	maximumExpandedBytes = 512 * 1024 * 1024
	maximumReleaseBytes  = 16 * 1024 * 1024
	maximumLineBytes     = 1024 * 1024
)

var (
	digestPattern  = regexp.MustCompile(`^[0-9a-f]{64}$`)
	packagePattern = regexp.MustCompile(`^[a-z0-9][a-z0-9+.-]*$`)
	versionPattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~_-]*$`)
	archivePattern = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+.:~%_-]*\.deb$`)
	pathPattern    = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9+._~%/-]*$`)
	fieldPattern   = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9-]*$`)
	aptHelperPath  = "/usr/lib/apt/apt-helper"
)

type planRequest struct {
	URI, Basename, Package, Version, Architecture, SHA256 string
	Bytes                                                 int64
}

type targetRecord struct {
	IndexPath, IndexURI, RepoURI, BaseURI string
	Release, Component, Architecture      string
	Trusted, Codename, Suite              string
	Origin, Label, InReleasePath          string
}

type originRecord struct {
	planRequest
	PackageFilename                  string
	RepositoryURI, BaseURI           string
	Release, Component, TargetArch   string
	Trusted                          string
	Origin, Label, Codename, Suite   string
	IndexURI, IndexPath, IndexSHA256 string
	IndexBytes                       int64
	InReleasePath, InReleaseSHA256   string
	InReleaseBytes                   int64
}

type targetEvidence struct {
	targetRecord
	IndexSHA256, InReleaseSHA256 string
	IndexBytes, InReleaseBytes   int64
}

type packageRecord struct {
	Package, Version, Architecture string
	Filename, SHA256               string
	Bytes                          int64
}

func safeText(value string, maximum int) bool {
	return value != "" && len(value) <= maximum && !strings.ContainsAny(value, "\x00\r\n\t")
}

func safeURL(raw string, requireSlash bool) bool {
	if !safeText(raw, 2048) {
		return false
	}
	u, err := url.Parse(raw)
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Hostname() == "" || u.User != nil || u.RawQuery != "" || u.Fragment != "" {
		return false
	}
	return !requireSlash || strings.HasSuffix(raw, "/")
}

func safeAbsolutePath(path string) bool {
	return safeText(path, 4096) && filepath.IsAbs(path) && filepath.Clean(path) == path
}

// aptArchiveURI mirrors APT 2.8's pkgAcquire::URIEncode default for a
// repository Filename. The accepted filename alphabet excludes every other
// byte that QuoteString would escape.
func aptArchiveURI(repositoryURI, filename string) string {
	var encoded strings.Builder
	encoded.Grow(len(filename))
	const hexadecimal = "0123456789abcdef"
	for i := 0; i < len(filename); i++ {
		value := filename[i]
		if value == '+' || value == '~' || value == '%' {
			encoded.WriteByte('%')
			encoded.WriteByte(hexadecimal[value>>4])
			encoded.WriteByte(hexadecimal[value&15])
		} else {
			encoded.WriteByte(value)
		}
	}
	return repositoryURI + encoded.String()
}

func archiveRepositoryURI(indexURI, release string) (string, error) {
	marker := "/dists/" + release + "/"
	position := strings.LastIndex(indexURI, marker)
	if !packagePattern.MatchString(release) || position <= 0 || strings.Contains(indexURI[:position], marker) {
		return "", errors.New("archive index namespace refused")
	}
	repositoryURI := indexURI[:position+1]
	if !safeURL(repositoryURI, true) {
		return "", errors.New("archive repository URI refused")
	}
	return repositoryURI, nil
}

func aptListsDirectory() string {
	if os.Getenv("WAR_TRUSTED_RUNTIME_ORIGIN_TEST") == "1" {
		candidate := os.Getenv("WAR_APT_LISTS_DIR")
		if safeAbsolutePath(candidate) {
			return candidate
		}
	}
	return "/var/lib/apt/lists"
}

// aptInReleasePath mirrors APT 2.8's URItoFileName for the deliberately
// restricted HTTPS/HTTP target URLs accepted here.
func aptInReleasePath(baseURI string) (string, error) {
	if !safeURL(baseURI, true) {
		return "", errors.New("release base URI refused")
	}
	parsed, err := url.Parse(baseURI + "InRelease")
	if err != nil || parsed.Port() != "" || strings.Contains(parsed.EscapedPath(), "%") || !pathPattern.MatchString(strings.TrimPrefix(parsed.EscapedPath(), "/")) {
		return "", errors.New("release URI filename refused")
	}
	name := parsed.Hostname() + strings.ReplaceAll(parsed.EscapedPath(), "/", "_")
	if !safeText(name, 2048) || strings.Contains(name, "..") {
		return "", errors.New("release filename refused")
	}
	return filepath.Join(aptListsDirectory(), name), nil
}

func scanManifest(reader io.Reader, fields int, maximumRows int, accept func([]string) error) error {
	limited := &io.LimitedReader{R: reader, N: maximumManifestBytes + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), maximumLineBytes)
	rows := 0
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" || strings.ContainsRune(line, '\x00') {
			return errors.New("empty or unsafe manifest row")
		}
		parts := strings.Split(line, "\t")
		if len(parts) != fields {
			return errors.New("manifest field count refused")
		}
		rows++
		if rows > maximumRows || accept(parts) != nil {
			return errors.New("manifest row refused")
		}
	}
	if err := scanner.Err(); err != nil || limited.N <= 0 || rows == 0 {
		return errors.New("manifest incomplete or oversized")
	}
	return nil
}

func parsePlanManifest(reader io.Reader) ([]planRequest, error) {
	var out []planRequest
	seenURI, seenName := map[string]bool{}, map[string]bool{}
	var total int64
	err := scanManifest(reader, 7, 1024, func(fields []string) error {
		size, err := strconv.ParseInt(fields[5], 10, 64)
		item := planRequest{URI: fields[0], Basename: fields[1], Package: fields[2], Version: fields[3], Architecture: fields[4], Bytes: size, SHA256: fields[6]}
		if err != nil || !safeURL(item.URI, false) || !archivePattern.MatchString(item.Basename) || !packagePattern.MatchString(item.Package) || !versionPattern.MatchString(item.Version) || (item.Architecture != "amd64" && item.Architecture != "all") || item.Bytes <= 0 || item.Bytes > 64*1024*1024 || !digestPattern.MatchString(item.SHA256) || seenURI[item.URI] || seenName[item.Basename] {
			return errors.New("plan identity refused")
		}
		total += item.Bytes
		if total > 256*1024*1024 {
			return errors.New("plan byte budget refused")
		}
		seenURI[item.URI], seenName[item.Basename] = true, true
		out = append(out, item)
		return nil
	})
	return out, err
}

func parseTargetManifest(reader io.Reader) ([]targetRecord, error) {
	var out []targetRecord
	seen, seenPaths, seenURIs := map[string]bool{}, map[string]bool{}, map[string]bool{}
	err := scanManifest(reader, 12, 64, func(fields []string) error {
		releasePath, err := aptInReleasePath(fields[3])
		if err != nil {
			return err
		}
		item := targetRecord{
			IndexPath: fields[0], IndexURI: fields[1], RepoURI: fields[2], BaseURI: fields[3], Release: fields[4], Component: fields[5], Architecture: fields[6],
			Trusted: fields[7], Codename: fields[8], Suite: fields[9], Origin: fields[10], Label: fields[11], InReleasePath: releasePath,
		}
		if _, err = archiveRepositoryURI(item.IndexURI, item.Release); err != nil {
			return err
		}
		identity := strings.Join(fields, "\t")
		if !safeAbsolutePath(item.IndexPath) || !safeAbsolutePath(item.InReleasePath) || !safeURL(item.IndexURI, false) || !safeURL(item.RepoURI, true) || !safeURL(item.BaseURI, true) || item.Trusted != "yes" || (item.Architecture != "amd64" && item.Architecture != "all") || !safeText(item.Release, 128) || !safeText(item.Component, 128) || !safeText(item.Codename, 128) || !safeText(item.Suite, 128) || !safeText(item.Origin, 256) || !safeText(item.Label, 256) || seen[identity] || seenPaths[item.IndexPath] || seenURIs[item.IndexURI] {
			return errors.New("target identity refused")
		}
		seen[identity], seenPaths[item.IndexPath], seenURIs[item.IndexURI] = true, true, true
		out = append(out, item)
		return nil
	})
	return out, err
}

func regularFile(path string, maximum int64) (*os.File, os.FileInfo, error) {
	link, err := os.Lstat(path)
	if err != nil || link.Mode()&os.ModeSymlink != 0 || !link.Mode().IsRegular() || link.Size() <= 0 || link.Size() > maximum {
		return nil, nil, errors.New("origin input refused")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, nil, errors.New("origin input open refused")
	}
	info, err := file.Stat()
	if err != nil || !os.SameFile(link, info) || !info.Mode().IsRegular() || info.Size() != link.Size() {
		file.Close()
		return nil, nil, errors.New("origin input replacement refused")
	}
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok || stat.Nlink != 1 {
		file.Close()
		return nil, nil, errors.New("linked origin input refused")
	}
	return file, info, nil
}

func digestFile(path string, maximum int64) (string, int64, error) {
	file, info, err := regularFile(path, maximum)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	digest, err := digestOpenFile(file, info)
	return digest, info.Size(), err
}

func digestOpenFile(file *os.File, info os.FileInfo) (string, error) {
	h := sha256.New()
	written, err := io.Copy(h, file)
	if err != nil || written != info.Size() {
		return "", errors.New("origin input read refused")
	}
	return hex.EncodeToString(h.Sum(nil)), nil
}

func parsePackageIndex(path string, visit func(packageRecord) error) (string, int64, error) {
	file, info, err := regularFile(path, maximumIndexBytes)
	if err != nil {
		return "", 0, err
	}
	defer file.Close()
	digest, err := digestOpenFile(file, info)
	if err != nil {
		return "", 0, err
	}
	if _, err = file.Seek(0, io.SeekStart); err != nil {
		return "", 0, errors.New("package index rewind refused")
	}
	reader := io.Reader(file)
	var command *exec.Cmd
	commandFinished := true
	if !strings.HasSuffix(path, "_Packages") {
		extension := filepath.Ext(path)
		if !strings.HasSuffix(strings.TrimSuffix(path, extension), "_Packages") || !map[string]bool{".bz2": true, ".gz": true, ".lz4": true, ".xz": true, ".zst": true}[extension] {
			return "", 0, errors.New("package index encoding refused")
		}
		command = exec.Command(aptHelperPath, "cat-file", path)
		stdout, pipeErr := command.StdoutPipe()
		if pipeErr != nil || command.Start() != nil {
			return "", 0, errors.New("package index decoder refused")
		}
		reader, commandFinished = stdout, false
		defer func() {
			if !commandFinished {
				_ = command.Process.Kill()
				_ = command.Wait()
			}
		}()
	}
	limited := &io.LimitedReader{R: reader, N: maximumExpandedBytes + 1}
	scanner := bufio.NewScanner(limited)
	scanner.Buffer(make([]byte, 4096), maximumLineBytes)
	fields := map[string]string{}
	stanzas := 0
	continuationAllowed := false
	finish := func() error {
		if len(fields) == 0 {
			continuationAllowed = false
			return nil
		}
		stanzas++
		if stanzas > 500000 {
			return errors.New("package stanza budget refused")
		}
		for _, key := range []string{"Package", "Version", "Architecture", "Filename", "Size", "SHA256"} {
			if fields[key] == "" {
				return errors.New("incomplete package stanza")
			}
		}
		size, err := strconv.ParseInt(fields["Size"], 10, 64)
		filename := fields["Filename"]
		item := packageRecord{Package: fields["Package"], Version: fields["Version"], Architecture: fields["Architecture"], Filename: filename, Bytes: size, SHA256: fields["SHA256"]}
		if err != nil || !packagePattern.MatchString(item.Package) || !versionPattern.MatchString(item.Version) || (item.Architecture != "amd64" && item.Architecture != "all") || size <= 0 || size > 8*1024*1024*1024 || !digestPattern.MatchString(item.SHA256) || !pathPattern.MatchString(filename) || filepath.IsAbs(filename) || filepath.Clean(filename) != filename || strings.HasPrefix(filename, "../") {
			return errors.New("package stanza identity refused")
		}
		if err = visit(item); err != nil {
			return err
		}
		fields = map[string]string{}
		continuationAllowed = false
		return nil
	}
	for scanner.Scan() {
		line := scanner.Text()
		if line == "" {
			if err = finish(); err != nil {
				return "", 0, err
			}
			continue
		}
		if line[0] == ' ' || line[0] == '\t' {
			if !continuationAllowed {
				return "", 0, errors.New("orphaned package continuation")
			}
			continue
		}
		key, value, ok := strings.Cut(line, ":")
		if !ok || !fieldPattern.MatchString(key) {
			return "", 0, errors.New("malformed package field")
		}
		continuationAllowed = true
		value = strings.TrimLeft(value, " \t")
		switch key {
		case "Package", "Version", "Architecture", "Filename", "Size", "SHA256":
			if fields[key] != "" || !safeText(value, maximumLineBytes) {
				return "", 0, errors.New("duplicate package field")
			}
			fields[key] = value
		}
	}
	if err = scanner.Err(); err != nil || limited.N <= 0 {
		return "", 0, errors.New("package index read refused")
	}
	if err = finish(); err != nil {
		return "", 0, err
	}
	if command != nil {
		err = command.Wait()
		commandFinished = true
		if err != nil {
			return "", 0, errors.New("package index decoder incomplete")
		}
	} else {
		position, seekErr := file.Seek(0, io.SeekCurrent)
		if seekErr != nil || position != info.Size() {
			return "", 0, errors.New("package index incomplete")
		}
	}
	current, err := os.Lstat(path)
	if err != nil {
		return "", 0, errors.New("package index replacement refused")
	}
	currentStat, currentOK := current.Sys().(*syscall.Stat_t)
	if !current.Mode().IsRegular() || !os.SameFile(info, current) || current.Size() != info.Size() || !currentOK || currentStat.Nlink != 1 || stanzas == 0 {
		return "", 0, errors.New("package index incomplete")
	}
	return digest, info.Size(), nil
}

func resolveEvidence(requests []planRequest, targets []targetRecord) ([]originRecord, []targetEvidence, error) {
	if len(requests) == 0 || len(requests) > 1024 || len(targets) == 0 || len(targets) > 64 {
		return nil, nil, errors.New("origin input count refused")
	}
	byURI := make(map[string]int, len(requests))
	for i, request := range requests {
		if _, duplicate := byURI[request.URI]; duplicate {
			return nil, nil, errors.New("duplicate archive request")
		}
		byURI[request.URI] = i
	}
	matches := make([][]originRecord, len(requests))
	conflicts := make([]bool, len(requests))
	var evidence []targetEvidence
	for _, target := range targets {
		if target.Trusted != "yes" {
			return nil, nil, errors.New("untrusted package target")
		}
		archiveRepository, err := archiveRepositoryURI(target.IndexURI, target.Release)
		if err != nil {
			return nil, nil, err
		}
		releaseHash, releaseBytes, err := digestFile(target.InReleasePath, maximumReleaseBytes)
		if err != nil {
			return nil, nil, err
		}
		var targetMatches []struct {
			index int
			item  packageRecord
		}
		indexHash, indexBytes, err := parsePackageIndex(target.IndexPath, func(item packageRecord) error {
			archiveURI := aptArchiveURI(archiveRepository, item.Filename)
			i, exists := byURI[archiveURI]
			if !exists {
				return nil
			}
			request := requests[i]
			if item.Package != request.Package || item.Version != request.Version || item.Architecture != request.Architecture || item.Bytes != request.Bytes || item.SHA256 != request.SHA256 {
				conflicts[i] = true
				return nil
			}
			targetMatches = append(targetMatches, struct {
				index int
				item  packageRecord
			}{i, item})
			return nil
		})
		if err != nil {
			return nil, nil, err
		}
		evidence = append(evidence, targetEvidence{targetRecord: target, IndexSHA256: indexHash, IndexBytes: indexBytes, InReleaseSHA256: releaseHash, InReleaseBytes: releaseBytes})
		for _, match := range targetMatches {
			request := requests[match.index]
			matches[match.index] = append(matches[match.index], originRecord{
				planRequest: request, PackageFilename: match.item.Filename,
				RepositoryURI: target.RepoURI, BaseURI: target.BaseURI, Release: target.Release, Component: target.Component, TargetArch: target.Architecture, Trusted: target.Trusted,
				Origin: target.Origin, Label: target.Label, Codename: target.Codename, Suite: target.Suite,
				IndexURI: target.IndexURI, IndexPath: target.IndexPath, IndexSHA256: indexHash, IndexBytes: indexBytes,
				InReleasePath: target.InReleasePath, InReleaseSHA256: releaseHash, InReleaseBytes: releaseBytes,
			})
		}
	}
	var out []originRecord
	for i := range requests {
		if conflicts[i] || len(matches[i]) != 1 {
			return nil, nil, errors.New("archive origin missing, conflicting or ambiguous")
		}
		out = append(out, matches[i][0])
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Basename < out[j].Basename })
	sort.Slice(evidence, func(i, j int) bool { return evidence[i].IndexPath < evidence[j].IndexPath })
	return out, evidence, nil
}

func resolveOrigins(requests []planRequest, targets []targetRecord) ([]originRecord, error) {
	records, _, err := resolveEvidence(requests, targets)
	return records, err
}

func writeEvidence(records []originRecord, targets []targetEvidence, writer io.Writer) error {
	buffer := bufio.NewWriter(writer)
	for _, item := range targets {
		_, err := fmt.Fprintf(buffer, "target\t%s\t%s\t%d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\n",
			item.IndexURI, item.IndexPath, item.IndexBytes, item.IndexSHA256, item.RepoURI, item.BaseURI, item.Release, item.Component,
			item.Architecture, item.Trusted, item.Origin, item.Label, item.Codename, item.Suite, item.InReleasePath, item.InReleaseBytes, item.InReleaseSHA256)
		if err != nil {
			return err
		}
	}
	for _, item := range records {
		_, err := fmt.Fprintf(buffer, "origin\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%s\t%s\t%d\t%s\n",
			item.Basename, item.Package, item.Version, item.Architecture, item.PackageFilename,
			item.RepositoryURI, item.BaseURI, item.Release, item.Component, item.TargetArch, item.Trusted, item.Origin, item.Label, item.Codename, item.Suite,
			item.IndexURI, item.IndexPath, item.IndexBytes, item.IndexSHA256, item.InReleasePath, item.InReleaseBytes, item.InReleaseSHA256)
		if err != nil {
			return err
		}
	}
	return buffer.Flush()
}

func run(args []string, output io.Writer) error {
	if len(args) != 2 {
		return errors.New("usage: trusted-runtime-origin <archive-plan.tsv> <targets.tsv>")
	}
	planFile, err := os.Open(args[0])
	if err != nil {
		return err
	}
	defer planFile.Close()
	requests, err := parsePlanManifest(planFile)
	if err != nil {
		return err
	}
	targetFile, err := os.Open(args[1])
	if err != nil {
		return err
	}
	defer targetFile.Close()
	targets, err := parseTargetManifest(targetFile)
	if err != nil {
		return err
	}
	records, evidence, err := resolveEvidence(requests, targets)
	if err != nil {
		return err
	}
	return writeEvidence(records, evidence, output)
}

func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
