package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"strconv"
	"time"
)

// main retains only the read-only historical overlap diagnostic.
func main() {
	env := map[string]string{"TRUSTED_GATE_APP_ID": os.Getenv("TRUSTED_GATE_APP_ID"), "GITHUB_TOKEN": os.Getenv("GITHUB_TOKEN")}
	client := &Client{BaseURL: "https://api.github.com", Token: env["GITHUB_TOKEN"], HTTP: &http.Client{Timeout: 30 * time.Second}}
	if err := execute(os.Args[1:], env, client, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "trusted-gate: NOT READY:", err)
		os.Exit(1)
	}
}

func execute(args []string, env map[string]string, client *Client, out io.Writer) error {
	if len(args) == 0 || args[0] != "inspect" {
		return errors.New("only inspect is supported; the resolve and publish commands are retired")
	}
	if env["GITHUB_TOKEN"] == "" {
		return errors.New("an explicitly scoped read token is required")
	}
	flags := flag.NewFlagSet("inspect", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	appID := flags.Int64("app-id", 0, "historical publisher App ID")
	if err := flags.Parse(args[1:]); err != nil || flags.NArg() != 0 {
		return errors.New("invalid arguments")
	}
	if *appID == 0 {
		var err error
		*appID, err = strconv.ParseInt(env["TRUSTED_GATE_APP_ID"], 10, 64)
		if err != nil {
			return errors.New("historical publisher App ID is missing")
		}
	}
	if !publisherAppID(*appID) {
		return errors.New("a historical non-Actions publisher App ID is required")
	}
	if client == nil {
		return errors.New("API client missing")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 90*time.Second)
	defer cancel()
	if err := client.Inspect(ctx, *appID); err != nil {
		return err
	}
	_, err := fmt.Fprintln(out, "protection_overlap_verified=true\nactivation_ready=unknown")
	return err
}
