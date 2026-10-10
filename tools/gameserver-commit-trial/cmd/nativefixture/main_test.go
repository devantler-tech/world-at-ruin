package main

import (
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestStartupDiagnosticKeepsBoundedLatestFailure(t *testing.T) {
	d := &diagnosticTail{}
	large := strings.Repeat("old", 16<<10)
	if n, err := d.Write([]byte(large)); n != len(large) || err != nil {
		t.Fatal("diagnostic writer interrupted child output")
	}
	_, _ = d.Write([]byte("new startup failure"))
	if value := d.String(); len(value) != 8<<10 || !strings.HasSuffix(value, "new startup failure") {
		t.Fatal("startup diagnostic lost latest cause or exceeded bound")
	}
}

func TestRetirementPreservesLiveStateUntilStopSucceeds(t *testing.T) {
	state := filepath.Join(t.TempDir(), "private")
	if err := os.Mkdir(state, 0700); err != nil {
		t.Fatal(err)
	}
	failure := errors.New("stop not established")
	if err := retire(state, func() error { return failure }); !errors.Is(err, failure) {
		t.Fatal("failed retirement lost its error")
	}
	if info, err := os.Stat(state); err != nil || !info.IsDir() {
		t.Fatal("failed retirement removed potentially live state")
	}
	if err := retire(state, func() error {
		if _, err := os.Stat(state); err != nil {
			t.Fatal("state removed before stopping child")
		}
		return nil
	}); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(state); !os.IsNotExist(err) {
		t.Fatal("confirmed retirement retained private state")
	}
}

func TestFixtureIgnoresAmbientClusterAndBinaryOverrides(t *testing.T) {
	t.Setenv("USE_EXISTING_CLUSTER", "true")
	t.Setenv("TEST_ASSET_KUBE_APISERVER", "/unowned/api")
	t.Setenv("TEST_ASSET_ETCD", "/unowned/etcd")
	t.Setenv("TEST_ASSET_KUBECTL", "/unowned/kubectl")
	e := environment("/owned/assets", "/owned/gameserver.yaml", "/owned/private")
	if e.UseExistingCluster == nil || *e.UseExistingCluster || e.ControlPlane.GetAPIServer().Path != "/owned/assets/kube-apiserver" || e.ControlPlane.Etcd.Path != "/owned/assets/etcd" || e.ControlPlane.KubectlPath != "/owned/assets/kubectl" || e.ControlPlane.Etcd.DataDir != filepath.Join("/owned/private", "etcd") {
		t.Fatal("ambient state replaced owned control plane")
	}
}

func TestFixtureRejectsMissingExplicitInputs(t *testing.T) {
	if err := run("", "", ""); err == nil {
		t.Fatal("default invocation started a control plane")
	}
}
