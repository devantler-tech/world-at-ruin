package main

import (
	"context"
	"path/filepath"
	"testing"

	"github.com/heroiclabs/nakama-common/runtime"
)

type snapshotLog struct {
	runtime.Logger
	lines []string
}

func (l *snapshotLog) Info(format string, args ...interface{}) {
	if len(args) != 0 {
		panic("snapshot diagnostic must contain no runtime values")
	}
	l.lines = append(l.lines, format)
}

// Snapshot evidence is narrower than successful native initialization: the
// selected credential is observed even when later configuration refuses.
func TestIssuedEntrySnapshotObservation(t *testing.T) {
	for _, mode := range []string{"selected", "disabled", "unknown", "configuration", "unavailable", "wrong-identity"} {
		t.Run(mode, func(t *testing.T) {
			issuer, socket := startClaimsIssuer(t, fixtureSVID(t))
			env := claimsEnv(socket)
			switch mode {
			case "disabled":
				env["WAR_ISSUED_CLAIMS_ENABLED"] = "false"
			case "unknown":
				env["WAR_ISSUED_CLAIMS_ENABLED"] = "yes"
			case "configuration":
				env["WAR_ISSUED_CLAIMS_SERVER_DNS"] = "127.0.0.1"
			case "unavailable":
				env["WAR_ISSUED_CLAIMS_SOCKET"] = filepath.Join(filepath.Dir(socket), "missing.sock")
			case "wrong-identity":
				env["WAR_ISSUED_CLAIMS_SERVER_URI"] += "-other"
			}
			logger := &snapshotLog{}
			ctx := claimsRuntimeContext{Context: context.Background(), env: env}
			if err := InitModule(ctx, logger, nil, nil, nil); err == nil {
				t.Fatal("incomplete runtime dependencies unexpectedly initialized")
			}
			want := 0
			if mode == "selected" {
				want = 1
			}
			if len(logger.lines) != want || want == 1 && (logger.lines[0] != "ISSUED CLAIMS SNAPSHOT FETCHED" || issuer.requests.Load() != 1) {
				t.Fatalf("snapshot observation does not match actual selection: %v", logger.lines)
			}
		})
	}
}
