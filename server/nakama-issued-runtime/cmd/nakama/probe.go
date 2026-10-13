package main

import (
	"context"
	"errors"
	"path/filepath"
	"strings"
	"time"

	"github.com/spiffe/go-spiffe/v2/workloadapi"
	"google.golang.org/grpc/codes"
	"google.golang.org/grpc/status"
)

// sdkProbe is a diagnostic startup veto, never an issued serving credential
// adapter. A successful fetch still grants no runtime initialization authority.
func sdkProbe(parent context.Context, env map[string]string) error {
	switch env["WAR_ISSUED_SDK_PROBE_ENABLED"] {
	case "", "false":
		return nil
	case "true":
	default:
		return errors.New("issued SDK probe enablement refused")
	}
	socket := env["WAR_ISSUED_SDK_PROBE_SOCKET"]
	if !filepath.IsAbs(socket) || filepath.Clean(socket) != socket || len(socket) > 100 || strings.ContainsAny(socket, "\x00\r\n?#") {
		return errors.New("issued SDK probe configuration refused")
	}
	ctx, cancel := context.WithTimeout(parent, 3*time.Second)
	defer cancel()
	client, err := workloadapi.New(ctx, workloadapi.WithAddr("unix://"+socket))
	if err != nil {
		return errors.New("issued SDK client construction refused")
	}
	_, requestErr := client.FetchX509Context(ctx)
	closeErr := client.Close()
	if closeErr != nil {
		return errors.New("issued SDK client cleanup unknown")
	}
	code := status.Code(requestErr)
	if code == codes.Unavailable || code == codes.DeadlineExceeded {
		return errors.New("issued SDK WorkloadAPI unavailable")
	}
	if code == codes.OK {
		return errors.New("issued SDK diagnostic grants no serving authority")
	}
	return errors.New("issued SDK WorkloadAPI request refused")
}
