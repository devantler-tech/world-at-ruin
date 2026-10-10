// nativefixture owns a disposable API server/etcd pair, never an existing cluster.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"

	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

type manifest struct {
	Host          string
	CA, Cert, Key []byte
}

// Only disposable component diagnostics enter this bounded tail. Credentials
// and the manifest are never logged.
type diagnosticTail struct {
	mu    sync.Mutex
	value []byte
}

func (d *diagnosticTail) Write(p []byte) (int, error) {
	d.mu.Lock()
	defer d.mu.Unlock()
	const limit = 8 << 10
	n := len(p)
	if n >= limit {
		d.value = append(d.value[:0], p[n-limit:]...)
	} else {
		if len(d.value)+n > limit {
			d.value = d.value[len(d.value)+n-limit:]
		}
		d.value = append(d.value, p...)
	}
	return n, nil
}

func (d *diagnosticTail) String() string {
	d.mu.Lock()
	defer d.mu.Unlock()
	return string(d.value)
}

func environment(assets, crd, state string) *envtest.Environment {
	useExisting := false
	e := &envtest.Environment{UseExistingCluster: &useExisting, BinaryAssetsDirectory: assets,
		CRDDirectoryPaths: []string{crd}, ErrorIfCRDPathMissing: true,
		ControlPlaneStartTimeout: 45 * time.Second, ControlPlaneStopTimeout: 15 * time.Second}
	e.ControlPlane.GetAPIServer().Path = filepath.Join(assets, "kube-apiserver")
	e.ControlPlane.GetAPIServer().CertDir = filepath.Join(state, "certs")
	e.ControlPlane.Etcd = &envtest.Etcd{Path: filepath.Join(assets, "etcd"), DataDir: filepath.Join(state, "etcd")}
	e.ControlPlane.KubectlPath = filepath.Join(assets, "kubectl")
	return e
}

func retire(state string, stop func() error) error {
	// Keep private state when retirement cannot be established: it may still
	// belong to a live child. Stop must finish before removal begins.
	if err := stop(); err != nil {
		return err
	}
	return os.RemoveAll(state)
}

func run(assets, crd, output string) (err error) {
	if !filepath.IsAbs(assets) || !filepath.IsAbs(crd) || !filepath.IsAbs(output) {
		return errors.New("absolute fixture inputs required")
	}
	state, err := os.MkdirTemp("", "war-native-controlplane-")
	if err != nil {
		return errors.New("private state unavailable")
	}
	e := environment(assets, crd, state)
	diagnostics := &diagnosticTail{}
	e.ControlPlane.GetAPIServer().Out, e.ControlPlane.GetAPIServer().Err = diagnostics, diagnostics
	e.ControlPlane.Etcd.Out, e.ControlPlane.Etcd.Err = diagnostics, diagnostics
	defer func() {
		err = errors.Join(err, retire(state, e.Stop))
	}()
	for _, p := range []string{e.ControlPlane.GetAPIServer().CertDir, e.ControlPlane.Etcd.DataDir} {
		if err = os.MkdirAll(p, 0700); err != nil {
			return errors.New("private state unavailable")
		}
	}
	cfg, err := e.Start()
	if err != nil {
		return fmt.Errorf("owned control plane did not start: %w\n%s", err, diagnostics.String())
	}
	value, err := json.Marshal(manifest{cfg.Host, cfg.CAData, cfg.CertData, cfg.KeyData})
	if err != nil {
		return errors.New("private manifest encoding failed")
	}
	file, err := os.OpenFile(output, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return errors.New("private manifest unavailable")
	}
	_, writeErr := file.Write(value)
	err = errors.Join(writeErr, file.Close())
	if err != nil {
		return errors.New("private manifest incomplete")
	}
	done := make(chan struct{})
	go func() { _, _ = io.Copy(io.Discard, os.Stdin); close(done) }()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGTERM, syscall.SIGINT)
	defer signal.Stop(stop)
	select {
	case <-done:
	case <-stop:
	case <-time.After(4 * time.Minute):
		return errors.New("fixture lifetime exceeded")
	}
	return nil
}

func main() {
	assets := flag.String("assets", "", "explicit pinned binary directory")
	crd := flag.String("crd", "", "explicit rendered CRD")
	output := flag.String("output", "", "new private manifest")
	flag.Parse()
	if err := run(*assets, *crd, *output); err != nil {
		fmt.Fprintf(os.Stderr, "owned native control-plane fixture failed: %v\n", err)
		os.Exit(1)
	}
}
