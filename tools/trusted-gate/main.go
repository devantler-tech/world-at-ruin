package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"strings"
	"time"
)

const mainWorkflow = "devantler-tech/world-at-ruin/.github/workflows/repository-trusted-regressions.yaml@refs/heads/main"

func main() {
	env := map[string]string{}
	for _, key := range []string{"WAR_REPOSITORY_TRUSTED_GATE_ENABLED", "TRUSTED_GATE_APP_ID", "GITHUB_REPOSITORY", "GITHUB_WORKFLOW_REF", "GITHUB_WORKFLOW_SHA", "GITHUB_EVENT_NAME", "GITHUB_TOKEN"} {
		env[key] = os.Getenv(key)
	}
	client := &Client{BaseURL: "https://api.github.com", Token: env["GITHUB_TOKEN"], HTTP: &http.Client{Timeout: 30 * time.Second}}
	if err := execute(os.Args[1:], env, client, os.Stdout); err != nil {
		// API errors deliberately contain no credential or response-body details.
		fmt.Fprintln(os.Stderr, "trusted-gate: NOT READY:", err)
		os.Exit(1)
	}
}

func execute(args []string, env map[string]string, client *Client, out io.Writer) error {
	if len(args) == 0 {
		return errors.New("use resolve, publish or inspect")
	}
	command := args[0]
	if command != "resolve" && command != "publish" && command != "inspect" {
		return errors.New("unknown command")
	}
	if command != "inspect" {
		switch env["WAR_REPOSITORY_TRUSTED_GATE_ENABLED"] {
		case "", "false":
			_, err := fmt.Fprintln(out, "admitted=false")
			return err
		case "true":
		default:
			return errors.New("activation must be exactly true or false")
		}
		if env["GITHUB_REPOSITORY"] != "devantler-tech/world-at-ruin" || env["GITHUB_WORKFLOW_REF"] != mainWorkflow || env["GITHUB_EVENT_NAME"] != "workflow_run" || !exactSHA(env["GITHUB_WORKFLOW_SHA"]) {
			return errors.New("require the canonical main workflow-run source")
		}
	}
	if env["GITHUB_TOKEN"] == "" {
		return errors.New("an explicitly scoped token is required")
	}
	flags := flag.NewFlagSet(command, flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	runID := flags.Int64("run-id", 0, "GitHub notification run")
	outputPath := flags.String("output", "", "GitHub output file")
	rawIdentity := flags.String("identity", "", "resolved candidate identity")
	verdict := flags.String("verdict", "", "pending, failure or success")
	appID := flags.Int64("app-id", 0, "configured publisher App ID")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
		return errors.New("invalid arguments")
	}
	if command == "resolve" && (*rawIdentity != "" || *verdict != "" || *appID != 0) || command == "publish" && (*runID != 0 || *outputPath != "") || command == "inspect" && (*runID != 0 || *outputPath != "" || *rawIdentity != "" || *verdict != "") {
		return errors.New("arguments do not belong to this command")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()
	if command == "resolve" {
		if *runID <= 0 {
			return errors.New("a positive notification run ID is required")
		}
		if client == nil {
			return errors.New("API client missing")
		}
		identity, err := client.Resolve(ctx, Notification{RunID: *runID})
		if err != nil {
			return err
		}
		return writeIdentity(identity, *outputPath, out)
	}
	if *appID == 0 {
		var err error
		*appID, err = strconv.ParseInt(env["TRUSTED_GATE_APP_ID"], 10, 64)
		if err != nil {
			return errors.New("configured publisher App ID is missing")
		}
	}
	if !publisherAppID(*appID) {
		return errors.New("a configured non-Actions publisher App ID is required")
	}
	if client == nil {
		return errors.New("API client missing")
	}
	if command == "inspect" {
		if err := client.Inspect(ctx, *appID); err != nil {
			return err
		}
		_, err := fmt.Fprintln(out, "protection_overlap_verified=true\nactivation_ready=unknown")
		return err
	}
	identity, err := decodeIdentity(*rawIdentity)
	if err != nil {
		return err
	}
	if err := client.Publish(ctx, identity, *verdict, *appID); err != nil {
		return err
	}
	_, err = fmt.Fprintln(out, "published="+*verdict)
	return err
}

func exactSHA(value string) bool {
	if len(value) != 40 {
		return false
	}
	for _, c := range value {
		if c < '0' || c > '9' && c < 'a' || c > 'f' {
			return false
		}
	}
	return true
}

func decodeIdentity(raw string) (Identity, error) {
	var identity Identity
	if len(raw) == 0 || len(raw) > 4096 || !strings.HasPrefix(strings.TrimSpace(raw), "{") {
		return identity, errors.New("invalid identity document")
	}
	decoder := json.NewDecoder(strings.NewReader(raw))
	decoder.DisallowUnknownFields()
	if err := decoder.Decode(&identity); err != nil {
		return identity, errors.New("invalid identity fields")
	}
	if err := decoder.Decode(new(any)); err != io.EOF {
		return identity, errors.New("identity contains trailing data")
	}
	if identity.RunID <= 0 || !exactSHA(identity.Head) || !exactSHA(identity.Base) || !exactSHA(identity.Candidate) {
		return identity, errors.New("identity is incomplete")
	}
	return identity, nil
}

func writeIdentity(identity Identity, outputPath string, out io.Writer) error {
	data, err := json.Marshal(identity)
	if err != nil {
		return err
	}
	var lines bytes.Buffer
	fmt.Fprintf(&lines, "admitted=true\ntrusted-sha=%s\ncandidate-sha=%s\nhead-sha=%s\nrun-id=%d\nidentity-json=%s\n", identity.Base, identity.Candidate, identity.Head, identity.RunID, data)
	if outputPath == "" {
		_, err = out.Write(lines.Bytes())
		return err
	}
	file, err := os.OpenFile(outputPath, os.O_WRONLY|os.O_CREATE|os.O_APPEND, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(lines.Bytes())
	closeErr := file.Close()
	return errors.Join(writeErr, closeErr)
}
