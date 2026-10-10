package main

import (
	"context"
	"crypto/sha256"
	"debug/buildinfo"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"time"
)

const toolchain = "go1.27.2"

type bundleEvidence struct {
	Schema         int               `json:"schema"`
	GoVersion      string            `json:"go_version"`
	OS             string            `json:"os"`
	Architecture   string            `json:"architecture"`
	Nakama         string            `json:"nakama"`
	RuntimeAPI     string            `json:"runtime_api"`
	GraphSHA256    map[string]string `json:"graph_sha256"`
	ArtifactSHA256 map[string]string `json:"artifact_sha256"`
}

// build uses one immutable graph and identical shared-package compiler settings.
func build(ctx context.Context, source, output string, out io.Writer) error {
	source, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	output, err = filepath.Abs(output)
	if err != nil {
		return err
	}
	graph := map[string][]byte{}
	for _, name := range []string{"nakama-runtime/go.mod", "nakama-runtime/go.sum"} {
		graph[name], err = os.ReadFile(filepath.Join(source, name))
		if err != nil {
			return errors.New("native Nakama build locked graph unavailable")
		}
	}
	ctx, cancel := context.WithTimeout(ctx, 15*time.Minute)
	defer cancel()
	env := nativeEnvironment(os.Environ())
	run := func(args ...string) ([]byte, error) {
		cmd := exec.CommandContext(ctx, "go", args...)
		cmd.Dir, cmd.Env = source, env
		bytes, e := cmd.CombinedOutput()
		if e != nil {
			_, _ = out.Write(bytes)
			return nil, fmt.Errorf("native Nakama build command failed: %w", e)
		}
		return bytes, nil
	}
	version, err := run("version")
	if err != nil {
		return err
	}
	if strings.Fields(string(version))[2] != toolchain {
		return errors.New("native Nakama build requires Go 1.27.2")
	}
	for _, dependency := range []struct{ path, version string }{
		{"github.com/heroiclabs/nakama/v3", "v3.40.0"},
		{"github.com/heroiclabs/nakama-common", "v1.47.0"},
	} {
		selected, e := run("list", "-mod=readonly", "-modfile=nakama-runtime/go.mod", "-m", "-json", dependency.path)
		if e != nil {
			return e
		}
		var module struct {
			Path, Version string
			Replace       *json.RawMessage
		}
		if json.Unmarshal(selected, &module) != nil || module.Path != dependency.path || module.Version != dependency.version || module.Replace != nil {
			return errors.New("native Nakama build requires the compatible locked runtime graph")
		}
	}
	if err := os.Mkdir(output, 0750); err != nil {
		return errors.New("native Nakama build output must be absent")
	}
	complete := false
	defer func() {
		if !complete {
			_ = os.RemoveAll(output)
		}
	}()
	if err := os.Mkdir(filepath.Join(output, "modules"), 0750); err != nil {
		return err
	}
	common := []string{"build", "-mod=readonly", "-modfile=nakama-runtime/go.mod", "-trimpath", "-buildvcs=false"}
	binary := append(append([]string{}, common...), "-ldflags=-X main.version=3.40.0 -X main.commitID=war-native-trial", "-o", filepath.Join(output, "nakama"), "github.com/heroiclabs/nakama/v3")
	if _, err := run(binary...); err != nil {
		return err
	}
	plugin := append(append([]string{}, common...), "-tags=war_native_trial", "-buildmode=plugin", "-o", filepath.Join(output, "modules", "world_at_ruin.so"), "./cmd/nakama")
	if _, err := run(plugin...); err != nil {
		return err
	}
	evidence := bundleEvidence{Schema: 1, GoVersion: toolchain, OS: runtime.GOOS, Architecture: runtime.GOARCH, Nakama: "v3.40.0", RuntimeAPI: "v1.47.0", GraphSHA256: map[string]string{}, ArtifactSHA256: map[string]string{}}
	for name, before := range graph {
		after, e := os.ReadFile(filepath.Join(source, name))
		if e != nil || string(before) != string(after) {
			return errors.New("native Nakama build changed the locked graph")
		}
		sum := sha256.Sum256(before)
		evidence.GraphSHA256[name] = hex.EncodeToString(sum[:])
	}
	// Both artifacts must actually contain the same toolchain and runtime API.
	for _, name := range []string{"nakama", "modules/world_at_ruin.so"} {
		info, e := buildinfo.ReadFile(filepath.Join(output, name))
		if e != nil || info.GoVersion != toolchain {
			return errors.New("native Nakama build artifact toolchain mismatch")
		}
		matched := false
		for _, dependency := range info.Deps {
			if dependency.Path == "github.com/heroiclabs/nakama-common" && dependency.Version == "v1.47.0" && dependency.Replace == nil {
				matched = true
			}
		}
		if !matched {
			return errors.New("native Nakama build artifact runtime graph mismatch")
		}
		bytes, e := os.ReadFile(filepath.Join(output, name))
		if e != nil {
			return e
		}
		sum := sha256.Sum256(bytes)
		evidence.ArtifactSHA256[name] = hex.EncodeToString(sum[:])
	}
	bytes, err := json.MarshalIndent(evidence, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(filepath.Join(output, "bundle.json"), append(bytes, '\n'), 0640); err != nil {
		return err
	}
	complete = true
	_, err = fmt.Fprintf(out, "Native trial bundle built: %s/%s; Nakama %s, runtime API %s\n", runtime.GOOS, runtime.GOARCH, evidence.Nakama, evidence.RuntimeAPI)
	return err
}

// nativeEnvironment prevents cross compilation and ambient flag/workspace drift.
func nativeEnvironment(in []string) []string {
	rejected := map[string]bool{"GOFLAGS": true, "GOWORK": true, "GOTOOLCHAIN": true, "CGO_ENABLED": true, "GOOS": true, "GOARCH": true, "GOEXPERIMENT": true}
	out := make([]string, 0, len(in)+6)
	for _, setting := range in {
		key, _, _ := strings.Cut(setting, "=")
		if !rejected[key] {
			out = append(out, setting)
		}
	}
	return append(out, "GOFLAGS=", "GOWORK=off", "GOTOOLCHAIN=local", "CGO_ENABLED=1", "GOOS="+runtime.GOOS, "GOARCH="+runtime.GOARCH, "GOEXPERIMENT=")
}
