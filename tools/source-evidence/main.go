// Source evidence seals successful native captures and joins only complete,
// source/run/attempt-bound artifacts. It does not render or judge game pixels.
package main

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"slices"
	"strings"
)

type evidenceContext struct {
	Version     int    `json:"version"`
	Integration string `json:"integration"`
	Base        string `json:"base"`
	Run         string `json:"run"`
	Attempt     string `json:"attempt"`
	FirstRun    bool   `json:"first_run"`
	GPUGated    bool   `json:"gpu_gated"`
}

type evidenceFile struct {
	Path   string `json:"path"`
	Size   int64  `json:"size"`
	SHA256 string `json:"sha256"`
}

type evidenceManifest struct {
	Context evidenceContext `json:"context"`
	Group   string          `json:"group"`
	Success bool            `json:"success"`
	Files   []evidenceFile  `json:"files"`
}

var activityDirs = []string{"light-response", "replication", "mob-chase", "breath", "walk", "run", "gait-transition", "gait-drive"}
var sourceSHA = regexp.MustCompile(`^[0-9a-f]{40}$`)
var positiveID = regexp.MustCompile(`^[1-9][0-9]*$`)
var evidenceName = regexp.MustCompile(`^[A-Za-z0-9][A-Za-z0-9_.-]*\.(png|txt|log)$`)

func contextFromEnv() (evidenceContext, error) {
	c := evidenceContext{Version: 1, Integration: os.Getenv("GITHUB_SHA"), Base: os.Getenv("BASE_SHA"), Run: os.Getenv("GITHUB_RUN_ID"), Attempt: os.Getenv("GITHUB_RUN_ATTEMPT")}
	if !sourceSHA.MatchString(c.Integration) || !sourceSHA.MatchString(c.Base) || !positiveID.MatchString(c.Run) || !positiveID.MatchString(c.Attempt) {
		return c, errors.New("missing or malformed evidence source context")
	}
	for key, dest := range map[string]*bool{"FIRST_RUN": &c.FirstRun, "GPU_GATED": &c.GPUGated} {
		switch os.Getenv(key) {
		case "true":
			*dest = true
		case "false":
			*dest = false
		default:
			return c, fmt.Errorf("unknown %s decision", key)
		}
	}
	return c, nil
}

func allowed(group, path string) bool {
	parts := strings.Split(path, "/")
	if len(parts) > 2 || !evidenceName.MatchString(parts[len(parts)-1]) {
		return false
	}
	if len(parts) == 1 {
		return group != "activity" && (strings.HasSuffix(path, ".png") || strings.HasSuffix(path, ".txt"))
	}
	if parts[0] == "logs" {
		switch group {
		case "world":
			return parts[1] == "capture.log"
		case "activity":
			return parts[1] == "capture-replication.log" || parts[1] == "capture-mob-chase.log"
		case "base":
			return parts[1] == "base-capture.log" || parts[1] == "base-first-run.log"
		}
	}
	if !strings.HasSuffix(path, ".png") && !strings.HasSuffix(path, ".txt") {
		return false
	}
	if group == "world" {
		return parts[0] == "opt-in-previews"
	}
	if group == "activity" {
		for _, dir := range activityDirs {
			if parts[0] == dir {
				return true
			}
		}
	}
	return false
}

func snapshot(group, root string) ([]evidenceFile, error) {
	info, err := os.Lstat(root)
	if err != nil {
		return nil, err
	}
	if !info.IsDir() {
		return nil, errors.New("evidence root is not a physical directory")
	}
	files := make([]evidenceFile, 0)
	err = filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) (retErr error) {
		if walkErr != nil {
			return walkErr
		}
		if path == root {
			return nil
		}
		rel, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		rel = filepath.ToSlash(rel)
		if entry.Type()&os.ModeSymlink != 0 {
			return fmt.Errorf("linked evidence: %s", rel)
		}
		if entry.IsDir() {
			return nil
		}
		if rel == "evidence.json" {
			return nil
		}
		if !entry.Type().IsRegular() || !allowed(group, rel) {
			return fmt.Errorf("unexpected evidence path: %s", rel)
		}
		file, err := os.Open(path)
		if err != nil {
			return err
		}
		defer func() { retErr = errors.Join(retErr, file.Close()) }()
		before, err := file.Stat()
		if err != nil {
			return err
		}
		// An empty registry is valid when every preview has shipped default-on.
		// Captions, logs and images never receive this exception.
		emptyRegistry := group == "world" && rel == "opt-in-previews/enabled-flags.txt"
		if !before.Mode().IsRegular() || (before.Size() == 0 && !emptyRegistry) {
			return fmt.Errorf("empty or nonregular evidence: %s", rel)
		}
		hash := sha256.New()
		n, err := io.Copy(hash, file)
		if err != nil {
			return err
		}
		after, err := file.Stat()
		if err != nil {
			return err
		}
		if n != before.Size() || n != after.Size() || !before.ModTime().Equal(after.ModTime()) {
			return fmt.Errorf("evidence changed while reading: %s", rel)
		}
		if strings.HasSuffix(rel, ".png") && n <= 10240 {
			return fmt.Errorf("trivial PNG: %s", rel)
		}
		files = append(files, evidenceFile{Path: rel, Size: n, SHA256: hex.EncodeToString(hash.Sum(nil))})
		return nil
	})
	return files, err
}

func complete(ctx evidenceContext, group string, success bool, files []evidenceFile) error {
	if group != "world" && group != "activity" && group != "base" {
		return errors.New("unknown evidence group")
	}
	if !success {
		if group == "base" {
			return nil
		}
		return errors.New("head capture was not successful")
	}
	paths := map[string]bool{}
	pngs := map[string]int{}
	firstRun := false
	for _, file := range files {
		paths[file.Path] = true
	}
	for _, file := range files {
		if strings.HasSuffix(file.Path, ".png") {
			if !paths[strings.TrimSuffix(file.Path, ".png")+".txt"] {
				return fmt.Errorf("missing caption for %s", file.Path)
			}
			dir := filepath.ToSlash(filepath.Dir(file.Path))
			pngs[dir]++
			if dir == "." && strings.HasPrefix(file.Path, "first_run") {
				firstRun = true
			}
		}
	}
	required := []string{"."}
	logs := []string{"logs/base-capture.log"}
	if group == "world" {
		required = append(required, "opt-in-previews")
		logs = []string{"logs/capture.log"}
		for _, dir := range []string{"", "opt-in-previews/"} {
			for _, view := range []string{"sunward", "crossfield", "shrine", "bonepale", "cinderreach", "cave-chamber", "cave-walkout", "cave-mouth"} {
				if !paths[dir+view+".png"] {
					return fmt.Errorf("missing committed world vantage: %s%s", dir, view)
				}
			}
		}
	}
	if group == "activity" {
		required = activityDirs
		logs = []string{"logs/capture-replication.log", "logs/capture-mob-chase.log"}
	}
	for _, dir := range required {
		if pngs[dir] == 0 {
			return fmt.Errorf("missing complete %s scenario", dir)
		}
	}
	for _, log := range logs {
		if !paths[log] {
			return fmt.Errorf("missing %s", log)
		}
	}
	if ctx.FirstRun && group == "world" && !firstRun {
		return errors.New("selected first-run capture missing")
	}
	return nil
}

func manifestBytes(m evidenceManifest) ([]byte, error) {
	b, err := json.MarshalIndent(m, "", "  ")
	return append(b, '\n'), err
}

func seal(ctx evidenceContext, group, root string, success bool) error {
	if _, err := os.Lstat(filepath.Join(root, "evidence.json")); !os.IsNotExist(err) {
		return errors.New("evidence already sealed or unreadable")
	}
	files, err := snapshot(group, root)
	if err != nil {
		return err
	}
	if err := complete(ctx, group, success, files); err != nil {
		return err
	}
	b, err := manifestBytes(evidenceManifest{Context: ctx, Group: group, Success: success, Files: files})
	if err != nil {
		return err
	}
	file, err := os.OpenFile(filepath.Join(root, "evidence.json"), os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0644)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(b)
	closeErr := file.Close()
	return errors.Join(writeErr, closeErr)
}

func verify(ctx evidenceContext, group, root string) (evidenceManifest, error) {
	var m evidenceManifest
	path := filepath.Join(root, "evidence.json")
	info, err := os.Lstat(path)
	if err != nil {
		return m, err
	}
	if !info.Mode().IsRegular() || info.Size() > 8<<20 {
		return m, errors.New("invalid manifest file")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return m, err
	}
	if err := json.Unmarshal(b, &m); err != nil {
		return m, err
	}
	canonical, err := manifestBytes(m)
	if err != nil {
		return m, err
	}
	if !bytes.Equal(b, canonical) || m.Context != ctx || m.Group != group {
		return m, errors.New("noncanonical or mismatched evidence source")
	}
	actual, err := snapshot(group, root)
	if err != nil {
		return m, err
	}
	if !slices.Equal(actual, m.Files) {
		return m, errors.New("incomplete or changed evidence inventory")
	}
	return m, complete(ctx, group, m.Success, m.Files)
}

func collect(ctx evidenceContext, world, activity, base, out string) (retErr error) {
	if _, err := os.Lstat(out); !os.IsNotExist(err) {
		return errors.New("output already exists or is unreadable")
	}
	groups := []struct {
		group, root string
		m           evidenceManifest
	}{{group: "world", root: world}, {group: "activity", root: activity}, {group: "base", root: base}}
	for i := range groups {
		m, err := verify(ctx, groups[i].group, groups[i].root)
		if err != nil {
			return fmt.Errorf("%s: %w", groups[i].group, err)
		}
		groups[i].m = m
	}
	tmp, err := os.MkdirTemp(filepath.Dir(out), ".source-evidence-")
	if err != nil {
		return err
	}
	defer func() { retErr = errors.Join(retErr, os.RemoveAll(tmp)) }()
	for _, group := range groups {
		if group.group == "base" && !group.m.Success {
			continue
		}
		for _, file := range group.m.Files {
			dir := "shots"
			if group.group == "base" {
				dir = "shots-base"
			}
			path := filepath.Join(dir, filepath.FromSlash(file.Path))
			if strings.HasPrefix(file.Path, "logs/") {
				path = filepath.FromSlash(file.Path)
			}
			target := filepath.Join(tmp, path)
			if err := os.MkdirAll(filepath.Dir(target), 0755); err != nil {
				return err
			}
			src, err := os.Open(filepath.Join(group.root, filepath.FromSlash(file.Path)))
			if err != nil {
				return err
			}
			dst, err := os.OpenFile(target, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0644)
			if err != nil {
				return errors.Join(err, src.Close())
			}
			hash := sha256.New()
			n, copyErr := io.Copy(io.MultiWriter(dst, hash), src)
			closeErr := errors.Join(dst.Close(), src.Close())
			if err := errors.Join(copyErr, closeErr); err != nil {
				return err
			}
			if n != file.Size || hex.EncodeToString(hash.Sum(nil)) != file.SHA256 {
				return errors.New("evidence changed during collection")
			}
		}
	}
	if err := os.WriteFile(filepath.Join(tmp, "shots", "source-evidence.txt"), []byte(fmt.Sprintf("integration: %s\nbase: %s\nrun: %s\nattempt: %s\nbase_capture_success: %t\n", ctx.Integration, ctx.Base, ctx.Run, ctx.Attempt, groups[2].m.Success)), 0644); err != nil {
		return err
	}
	return os.Rename(tmp, out)
}

func run(args []string) error {
	ctx, err := contextFromEnv()
	if err != nil {
		return err
	}
	if len(args) == 4 && args[0] == "seal" {
		if args[3] != "success" && args[3] != "failure" {
			return errors.New("unknown capture outcome")
		}
		return seal(ctx, args[1], args[2], args[3] == "success")
	}
	if len(args) == 5 && args[0] == "collect" {
		return collect(ctx, args[1], args[2], args[3], args[4])
	}
	return errors.New("usage: source-evidence seal GROUP DIR success|failure | collect WORLD ACTIVITY BASE OUTPUT")
}

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "source evidence:", err)
		os.Exit(1)
	}
}
