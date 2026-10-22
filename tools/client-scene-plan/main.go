// Command client-scene-plan binds the complete ordinary scene set to one CI
// integration and attempt. Receipts have a single canonical encoding: the
// reducer compares against independently reconstructed expected bytes.
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
	"strings"
)

const shardCount = 3
const maxReceiptBytes = 1 << 20

var shaPattern = regexp.MustCompile("^[0-9a-f]{40}$")
var numberPattern = regexp.MustCompile("^[1-9][0-9]{0,19}$")
var scenePattern = regexp.MustCompile("^[A-Za-z0-9_][A-Za-z0-9_-]*_test$")
var dedicated = []string{"save_fixture_guard_test", "creature_factory_test", "save_vault_guard_test",
	"boot_recovery_guard_test", "vault_restore_boot_test", "ability_registry_test"}

type scenePlan struct {
	SHA, Run, Attempt, Digest string
	Shard                     int
	Scenes                    []string
}

type sceneReceipt struct {
	Schema   int      `json:"schema"`
	SHA      string   `json:"sha"`
	Run      string   `json:"run"`
	Attempt  string   `json:"attempt"`
	Shard    int      `json:"shard"`
	Digest   string   `json:"plan"`
	Scenes   []string `json:"scenes"`
	Complete bool     `json:"complete"`
}

type sceneInput struct{ Name, Digest string }

func gitRead(root string, args ...string) ([]byte, error) {
	return exec.Command("git", append([]string{"-C", root, "--no-optional-locks"}, args...)...).Output()
}

func hash(data []byte) string {
	sum := sha256.Sum256(data)
	return hex.EncodeToString(sum[:])
}

func regularBytes(path string, limit int64) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.New("missing, nonregular or oversized proof input")
	}
	file, err := os.Open(path)
	if err != nil {
		return nil, errors.New("proof input could not be opened")
	}
	defer file.Close()
	actual, err := file.Stat()
	if err != nil || !os.SameFile(info, actual) {
		return nil, errors.New("proof input changed while opening")
	}
	data, err := io.ReadAll(io.LimitReader(file, limit+1))
	if err != nil || int64(len(data)) > limit {
		return nil, errors.New("proof input could not be completely read")
	}
	return data, nil
}

func buildPlan(root, sha, run, attempt string, shard int) (scenePlan, error) {
	p := scenePlan{SHA: sha, Run: run, Attempt: attempt, Shard: shard}
	if !shaPattern.MatchString(sha) || !numberPattern.MatchString(run) ||
		!numberPattern.MatchString(attempt) || shard < 0 || shard >= shardCount {
		return p, errors.New("invalid integration, run, attempt or shard")
	}
	head, err := gitRead(root, "rev-parse", "--verify", "HEAD")
	if err != nil || strings.TrimSpace(string(head)) != sha {
		return p, errors.New("checkout is not the tested integration")
	}
	if _, err := gitRead(root, "diff", "--quiet", "--no-ext-diff", "HEAD", "--", "client"); err != nil {
		return p, errors.New("tracked client inputs changed after checkout")
	}
	for _, dir := range []string{"client", "client/tests"} {
		info, err := os.Lstat(filepath.Join(root, dir))
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return p, errors.New("scene directory is not a real directory")
		}
	}
	skip := []byte{}
	skipPath := filepath.Join(root, "client/tests/ci-skip.txt")
	if _, err := os.Lstat(skipPath); err == nil {
		skip, err = regularBytes(skipPath, maxReceiptBytes)
		if err != nil {
			return p, err
		}
		// An untracked skip file is not part of this integration's plan.
		tracked, err := gitRead(root, "ls-files", "--error-unmatch", "--", "client/tests/ci-skip.txt")
		if err != nil || strings.TrimSpace(string(tracked)) != "client/tests/ci-skip.txt" {
			return p, errors.New("skip input is not tracked")
		}
	} else if !os.IsNotExist(err) {
		return p, errors.New("skip input could not be inspected")
	}
	skipped := map[string]bool{}
	for _, line := range strings.Split(string(skip), "\n") {
		trimmed := strings.TrimSpace(line)
		if trimmed != "" && !strings.HasPrefix(trimmed, "#") {
			skipped[line] = true
		}
	}
	tracked, err := gitRead(root, "ls-files", "-z", "--", ":(glob)client/tests/*_test.tscn")
	if err != nil {
		return p, errors.New("tracked scene inventory is unavailable")
	}
	paths := strings.Split(strings.TrimSuffix(string(tracked), "\x00"), "\x00")
	sort.Strings(paths)
	indexed := map[string]bool{}
	for _, path := range paths {
		indexed[filepath.Base(path)] = true
	}
	physical, err := os.ReadDir(filepath.Join(root, "client/tests"))
	if err != nil {
		return p, errors.New("scene directory inventory is unavailable")
	}
	for _, entry := range physical {
		if strings.HasSuffix(entry.Name(), "_test.tscn") && !indexed[entry.Name()] {
			return p, errors.New("an untracked scene would be omitted from the plan")
		}
	}
	guards := map[string]bool{}
	for _, name := range dedicated {
		guards[name] = true
	}
	foundGuards := map[string]bool{}
	all := []sceneInput{}
	selected := []string{}
	for _, path := range paths {
		if path == "" {
			continue
		}
		name := strings.TrimSuffix(filepath.Base(path), ".tscn")
		if filepath.ToSlash(filepath.Dir(path)) != "client/tests" || !scenePattern.MatchString(name) {
			return p, errors.New("tracked scene has an unsupported name")
		}
		data, err := regularBytes(filepath.Join(root, path), 8<<20)
		if err != nil {
			return p, err
		}
		all = append(all, sceneInput{Name: name, Digest: hash(data)})
		if guards[name] {
			foundGuards[name] = true
			continue
		}
		if !skipped[name] {
			selected = append(selected, name)
		}
	}
	if len(foundGuards) != len(dedicated) {
		return p, errors.New("a mandatory dedicated guard is missing")
	}
	if len(selected) < shardCount {
		return p, errors.New("scene inventory cannot populate all fixed workers")
	}
	input, err := json.Marshal(struct {
		SHA, Run, Attempt, Skip string
		Inputs                  []sceneInput
	}{sha, run, attempt, hash(skip), all})
	if err != nil {
		return p, errors.New("scene plan encoding failed")
	}
	p.Digest = hash(input)
	for index, name := range selected {
		if index%shardCount == shard {
			p.Scenes = append(p.Scenes, name)
		}
	}
	return p, nil
}

func sealPlan(p scenePlan, completed []byte) (sceneReceipt, error) {
	if len(p.Scenes) == 0 || !bytes.Equal(completed, []byte(strings.Join(p.Scenes, "\n")+"\n")) {
		return sceneReceipt{}, errors.New("successful-scene journal is not the complete ordered shard")
	}
	return sceneReceipt{1, p.SHA, p.Run, p.Attempt, p.Shard, p.Digest, p.Scenes, true}, nil
}

func artifactName(p scenePlan) string {
	return fmt.Sprintf("client-scenes-%d-%s-%s-%s", p.Shard, p.SHA, p.Run, p.Attempt)
}

func verifyReceipts(root, sha, run, attempt, dir string) (int, error) {
	info, err := os.Lstat(dir)
	if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return 0, errors.New("receipt directory is missing or aliased")
	}
	entries, err := os.ReadDir(dir)
	if err != nil || len(entries) != shardCount {
		return 0, errors.New("expected exactly three worker artifacts")
	}
	count := 0
	for shard := 0; shard < shardCount; shard++ {
		p, err := buildPlan(root, sha, run, attempt, shard)
		if err != nil {
			return 0, err
		}
		sub := filepath.Join(dir, artifactName(p))
		info, err := os.Lstat(sub)
		if err != nil || !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
			return 0, errors.New("worker artifact identity is missing or aliased")
		}
		files, err := os.ReadDir(sub)
		if err != nil || len(files) != 1 || files[0].Name() != "receipt.json" {
			return 0, errors.New("worker artifact must contain only its receipt")
		}
		actual, err := regularBytes(filepath.Join(sub, "receipt.json"), maxReceiptBytes)
		if err != nil {
			return 0, err
		}
		expected, err := sealPlan(p, []byte(strings.Join(p.Scenes, "\n")+"\n"))
		if err != nil {
			return 0, err
		}
		encoded, err := json.Marshal(expected)
		if err != nil || !bytes.Equal(bytes.TrimSpace(actual), encoded) {
			return 0, errors.New("worker receipt is incomplete, noncanonical or bound to another plan")
		}
		count += len(p.Scenes)
	}
	return count, nil
}

func execute(root string, args []string, out io.Writer) error {
	if len(args) < 1 {
		return errors.New("expected list, seal or verify")
	}
	if args[0] == "verify" && len(args) == 5 {
		count, err := verifyReceipts(root, args[1], args[2], args[3], args[4])
		if err != nil {
			return err
		}
		_, err = fmt.Fprintf(out, "CLIENT SCENES PASS: %d scenes at %s\n", count, args[1])
		return err
	}
	if (args[0] != "list" || len(args) != 5) && (args[0] != "seal" || len(args) != 6) {
		return errors.New("invalid scene-proof invocation")
	}
	if args[4] != "0" && args[4] != "1" && args[4] != "2" {
		return errors.New("invalid fixed shard")
	}
	shard := int(args[4][0] - '0')
	p, err := buildPlan(root, args[1], args[2], args[3], shard)
	if err != nil {
		return err
	}
	if args[0] == "list" {
		_, err := io.WriteString(out, strings.Join(p.Scenes, "\n")+"\n")
		return err
	}
	temp := os.Getenv("RUNNER_TEMP")
	state := filepath.Join(temp, fmt.Sprintf("war-client-scenes-%d", shard))
	if !filepath.IsAbs(temp) || filepath.Clean(temp) == string(filepath.Separator) || os.Getenv("XDG_DATA_HOME") != state {
		return errors.New("worker private-state identity is invalid")
	}
	if _, err := os.Lstat(state); !os.IsNotExist(err) {
		return errors.New("worker private state has not been cleaned")
	}
	completed, err := regularBytes(args[5], maxReceiptBytes)
	if err != nil {
		return err
	}
	receipt, err := sealPlan(p, completed)
	if err != nil {
		return err
	}
	return json.NewEncoder(out).Encode(receipt)
}

func main() {
	root, err := os.Getwd()
	if err == nil {
		err = execute(root, os.Args[1:], os.Stdout)
	}
	if err != nil {
		fmt.Fprintln(os.Stderr, "::error::client scene proof:", err)
		os.Exit(1)
	}
}
