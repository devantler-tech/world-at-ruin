// Package trial exercises the inactive capability against real Kubernetes
// storage. No Agones controller, node, Fleet allocator or production client runs.
package trial

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"sync"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	typed "agones.dev/agones/pkg/client/clientset/versioned/typed/agones/v1"
	"github.com/devantler-tech/world-at-ruin/server/agones"
	"github.com/devantler-tech/world-at-ruin/server/internal/gameservercommit"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"sigs.k8s.io/controller-runtime/pkg/envtest"
)

var control *rest.Config

func TestConcurrentCommitAndFenceCopies(t *testing.T) {
	api, obj := resource(t)
	cfg, h := proxy(t)
	g := prepare(t, client(t, cfg, obj.Namespace))
	first := make(chan error, 1)
	go func() { first <- g.Commit(context.Background()) }()
	reached(t, h)
	var wg sync.WaitGroup
	results := make(chan error, 16)
	for range 16 {
		copied := g
		wg.Go(func() { results <- copied.Commit(context.Background()) })
	}
	wg.Wait()
	close(results)
	for err := range results {
		if !errors.Is(err, gameservercommit.ErrClosed) {
			t.Fatalf("concurrent admission: %v", err)
		}
	}
	receipts := make(chan gameservercommit.Receipt, 4)
	fences := make(chan error, 4)
	for range 4 {
		copied := g
		wg.Go(func() { r, err := copied.Fence(context.Background()); receipts <- r; fences <- err })
	}
	wg.Wait()
	close(receipts)
	close(fences)
	accepted := 0
	for r := range receipts {
		if got, err := g.Accept(r); err == nil {
			accepted++
			if got.Outcome != gameservercommit.Uncommitted {
				t.Fatal("wrong concurrent outcome")
			}
		}
	}
	if accepted != 1 {
		t.Fatalf("accepted receipts=%d", accepted)
	}
	for err := range fences {
		if err != nil && !errors.Is(err, gameservercommit.ErrClosed) {
			t.Fatalf("concurrent fence: %v", err)
		}
	}
	barrier := read(t, api)
	h.unblock()
	storedStatus(t, h, 409)
	if err := <-first; !errors.Is(err, gameservercommit.ErrConflict) {
		t.Fatalf("held concurrent commit: %v", err)
	}
	if after := read(t, api); after.ResourceVersion != barrier.ResourceVersion {
		t.Fatal("concurrent calls changed accepted barrier")
	}
}

func TestMain(m *testing.M) {
	if os.Getenv("KUBEBUILDER_ASSETS") == "" || os.Getenv("WAR_GAMESERVER_CRD") == "" {
		fmt.Fprintln(os.Stderr, "real GameServer trial requires pinned control-plane assets and rendered Agones CRD")
		os.Exit(1)
	}
	environment := localEnvironment(os.Getenv("KUBEBUILDER_ASSETS"), os.Getenv("WAR_GAMESERVER_CRD"))
	stateDir, err := os.MkdirTemp(environment.BinaryAssetsDirectory, "trial-state-")
	if err != nil {
		fmt.Fprintln(os.Stderr, "private trial state is unavailable")
		os.Exit(1)
	}
	environment.ControlPlane.GetAPIServer().CertDir = filepath.Join(stateDir, "certs")
	environment.ControlPlane.Etcd.DataDir = filepath.Join(stateDir, "etcd")
	for _, path := range []string{environment.ControlPlane.GetAPIServer().CertDir, environment.ControlPlane.Etcd.DataDir} {
		if err = os.MkdirAll(path, 0700); err != nil {
			_ = os.RemoveAll(stateDir)
			os.Exit(1)
		}
	}
	control, err = environment.Start()
	if err != nil {
		fmt.Fprintln(os.Stderr, "real control plane failed to start")
		_ = environment.Stop()
		_ = os.RemoveAll(stateDir)
		os.Exit(1)
	}
	status := m.Run()
	if err = environment.Stop(); err != nil {
		fmt.Fprintln(os.Stderr, "real control plane failed to stop")
		status = 1
	}
	if err = os.RemoveAll(stateDir); err != nil {
		fmt.Fprintln(os.Stderr, "private trial state cleanup failed")
		status = 1
	}
	os.Exit(status)
}

func localEnvironment(assets, crd string) *envtest.Environment {
	useExisting := false
	e := &envtest.Environment{UseExistingCluster: &useExisting, BinaryAssetsDirectory: assets, CRDDirectoryPaths: []string{crd}, ErrorIfCRDPathMissing: true, ControlPlaneStartTimeout: 45 * time.Second, ControlPlaneStopTimeout: 15 * time.Second}
	// Explicit paths bypass envtest's higher-priority TEST_ASSET_* overrides.
	e.ControlPlane.GetAPIServer().Path = filepath.Join(assets, "kube-apiserver")
	e.ControlPlane.Etcd = &envtest.Etcd{Path: filepath.Join(assets, "etcd")}
	e.ControlPlane.KubectlPath = filepath.Join(assets, "kubectl")
	return e
}

func TestLocalEnvironmentCannotSelectExistingCluster(t *testing.T) {
	t.Setenv("USE_EXISTING_CLUSTER", "true")
	t.Setenv("KUBECONFIG", filepath.Join(t.TempDir(), "missing"))
	for _, name := range []string{"TEST_ASSET_KUBE_APISERVER", "TEST_ASSET_ETCD", "TEST_ASSET_KUBECTL"} {
		t.Setenv(name, "/must-never-execute")
	}
	assets := t.TempDir()
	e := localEnvironment(assets, "fixture.yaml")
	if e.UseExistingCluster == nil || *e.UseExistingCluster || e.DownloadBinaryAssets || e.Config != nil {
		t.Fatal("ambient cluster or binary selection is available")
	}
	if e.ControlPlane.GetAPIServer().Path != filepath.Join(assets, "kube-apiserver") || e.ControlPlane.Etcd.Path != filepath.Join(assets, "etcd") || e.ControlPlane.KubectlPath != filepath.Join(assets, "kubectl") {
		t.Fatal("explicit asset paths changed")
	}
}

func resource(t *testing.T) (typed.GameServerInterface, *agonesv1.GameServer) {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	core, err := kubernetes.NewForConfig(control)
	if err != nil {
		t.Fatal(err)
	}
	ns, err := core.CoreV1().Namespaces().Create(ctx, &corev1.Namespace{ObjectMeta: metav1.ObjectMeta{GenerateName: "commit-trial-"}}, metav1.CreateOptions{})
	if err != nil {
		t.Fatal(err)
	}
	namespace := ns.Name
	api, err := typed.NewForConfig(control)
	if err != nil {
		t.Fatal(err)
	}
	scoped := api.GameServers(namespace)
	obj, err := scoped.Create(ctx, &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{Name: "zone", Labels: map[string]string{agones.FleetLabel: "fleet"}},
		Spec:       agonesv1.GameServerSpec{Template: corev1.PodTemplateSpec{Spec: corev1.PodSpec{Containers: []corev1.Container{{Name: "zone", Image: "registry.invalid/fixture:local"}}}}},
		Status:     agonesv1.GameServerStatus{State: agonesv1.GameServerStateReady},
	}, metav1.CreateOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if obj.UID == "" || obj.ResourceVersion == "" || obj.Status.State != agonesv1.GameServerStateReady {
		t.Fatal("actual API did not retain a Ready identity")
	}
	return scoped, obj
}

func client(t *testing.T, cfg *rest.Config, namespace string) *gameservercommit.Client {
	t.Helper()
	c, err := gameservercommit.New(gameservercommit.Config{Enabled: true, REST: cfg, Namespace: namespace, Fleet: "fleet"})
	if err != nil {
		t.Fatal(err)
	}
	return c
}
func prepare(t *testing.T, c *gameservercommit.Client) gameservercommit.Grant {
	t.Helper()
	g, err := c.Prepare(context.Background(), "zone", "attempt-1")
	if err != nil {
		t.Fatal(err)
	}
	return g
}
func observation(t *testing.T, g gameservercommit.Grant, want gameservercommit.Outcome) {
	t.Helper()
	r, err := g.Fence(context.Background())
	if err != nil {
		t.Fatal(err)
	}
	got, err := g.Accept(r)
	if err != nil || got.Outcome != want || got.SourceVersion == got.BarrierVersion {
		t.Fatalf("barrier receipt: %#v %v", got, err)
	}
}
func read(t *testing.T, api typed.GameServerInterface) *agonesv1.GameServer {
	t.Helper()
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	obj, err := api.Get(ctx, "zone", metav1.GetOptions{})
	if err != nil {
		t.Fatal(err)
	}
	return obj
}

// heldRequest has already reached an HTTP server. The server deliberately
// ignores caller cancellation while retaining its own bounded lifetime. Barrier
// traffic proceeds over independent API connections; no storage fake is used.
type heldRequest struct {
	started chan struct{}
	release chan struct{}
	status  chan int
	once    sync.Once
}

func (h *heldRequest) unblock() { h.once.Do(func() { close(h.release) }) }

// proxy holds the single-zone allocation request using the same native-storage
// forwarding and cleanup behavior as the multi-object generation controls.
func proxy(t *testing.T) (*rest.Config, *heldRequest) {
	t.Helper()
	cfg, held := proxyMany(t, "zone")
	return cfg, held["zone"]
}

// proxyMany holds each named allocation PUT independently and forwards released
// requests to native storage, even when the original caller has canceled.
func proxyMany(t *testing.T, names ...string) (*rest.Config, map[string]*heldRequest) {
	t.Helper()
	target, err := url.Parse(control.Host)
	if err != nil {
		t.Fatal(err)
	}
	tlsConfig, err := rest.TLSConfigFor(control)
	if err != nil {
		t.Fatal(err)
	}
	independent := &http.Transport{TLSClientConfig: tlsConfig, DisableKeepAlives: true}
	t.Cleanup(independent.CloseIdleConnections)
	requests := make(map[string]*heldRequest, len(names))
	for _, name := range names {
		h := &heldRequest{started: make(chan struct{}), release: make(chan struct{}), status: make(chan int, 1)}
		requests[name] = h
	}
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body []byte
		if r.Body != nil {
			var readErr error
			body, readErr = io.ReadAll(io.LimitReader(r.Body, 4<<20))
			if readErr != nil {
				w.WriteHeader(500)
				return
			}
		}
		var obj agonesv1.GameServer
		var h *heldRequest
		if r.Method == http.MethodPut && json.Unmarshal(body, &obj) == nil && obj.Status.State == agonesv1.GameServerStateAllocated && obj.Annotations[gameservercommit.BarrierAnnotation] == "" {
			h = requests[obj.Name]
		}
		held := h != nil
		if held {
			close(h.started)
			select {
			case <-h.release:
			case <-time.After(10 * time.Second):
				w.WriteHeader(504)
				return
			}
		}
		ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		forwarded := r.Clone(ctx)
		forwarded.URL.Scheme = target.Scheme
		forwarded.URL.Host = target.Host
		forwarded.Host = target.Host
		forwarded.RequestURI = ""
		forwarded.Body = io.NopCloser(bytes.NewReader(body))
		forwarded.ContentLength = int64(len(body))
		response, callErr := independent.RoundTrip(forwarded)
		if callErr != nil {
			w.WriteHeader(502)
			if held {
				h.status <- 502
			}
			return
		}
		defer func() { _ = response.Body.Close() }()
		for key, values := range response.Header {
			w.Header()[key] = append([]string(nil), values...)
		}
		w.WriteHeader(response.StatusCode)
		_, _ = io.Copy(w, response.Body)
		if held {
			h.status <- response.StatusCode
		}
	}))
	t.Cleanup(server.Close)
	// Release held handlers before closing their server, including a failed test.
	for _, h := range requests {
		t.Cleanup(h.unblock)
	}
	cfg := rest.CopyConfig(control)
	cfg.Host = server.URL
	cfg.TLSClientConfig = rest.TLSClientConfig{}
	return cfg, requests
}
func reached(t *testing.T, h *heldRequest) {
	t.Helper()
	select {
	case <-h.started:
	case <-time.After(5 * time.Second):
		t.Fatal("allocation never reached HTTP proxy")
	}
}
func storedStatus(t *testing.T, h *heldRequest, want int) {
	t.Helper()
	select {
	case got := <-h.status:
		if got != want {
			t.Fatalf("storage response=%d want%d", got, want)
		}
	case <-time.After(7 * time.Second):
		t.Fatal("storage response missing")
	}
}

func TestUnfencedLateWriteCommits(t *testing.T) {
	api, obj := resource(t)
	cfg, h := proxy(t)
	g := prepare(t, client(t, cfg, obj.Namespace))
	done := make(chan error, 1)
	go func() { done <- g.Commit(context.Background()) }()
	reached(t, h)
	h.unblock()
	storedStatus(t, h, 200)
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if read(t, api).Status.State != agonesv1.GameServerStateAllocated {
		t.Fatal("positive control did not allocate")
	}
}

func TestBarrierRejectsHeldMutation(t *testing.T) {
	api, obj := resource(t)
	cfg, h := proxy(t)
	g := prepare(t, client(t, cfg, obj.Namespace))
	done := make(chan error, 1)
	go func() { done <- g.Commit(context.Background()) }()
	reached(t, h)
	observation(t, g, gameservercommit.Uncommitted)
	barrier := read(t, api)
	if barrier.ResourceVersion == obj.ResourceVersion || barrier.Annotations[gameservercommit.BarrierAnnotation] == "" {
		t.Fatal("barrier did not reach storage")
	}
	h.unblock()
	storedStatus(t, h, 409)
	if err := <-done; !errors.Is(err, gameservercommit.ErrConflict) {
		t.Fatalf("held mutation not refused: %v", err)
	}
	after := read(t, api)
	if after.ResourceVersion != barrier.ResourceVersion || after.Status.State != agonesv1.GameServerStateReady {
		t.Fatal("late mutation changed storage after accepted barrier")
	}
}

func TestAllocatedBeforeBarrier(t *testing.T) {
	api, obj := resource(t)
	g := prepare(t, client(t, control, obj.Namespace))
	if err := g.Commit(context.Background()); err != nil {
		t.Fatal(err)
	}
	observation(t, g, gameservercommit.Allocated)
	if read(t, api).Status.State != agonesv1.GameServerStateAllocated {
		t.Fatal("barrier erased allocation")
	}
}

func TestCancellationAndDeadlineDoNotProveAbsence(t *testing.T) {
	for _, fenced := range []bool{false, true} {
		for _, deadline := range []bool{false, true} {
			t.Run(fmt.Sprintf("fenced-%t-deadline-%t", fenced, deadline), func(t *testing.T) {
				api, obj := resource(t)
				cfg, h := proxy(t)
				g := prepare(t, client(t, cfg, obj.Namespace))
				var ctx context.Context
				var cancel context.CancelFunc
				if deadline {
					ctx, cancel = context.WithTimeout(context.Background(), 150*time.Millisecond)
				} else {
					ctx, cancel = context.WithCancel(context.Background())
				}
				defer cancel()
				done := make(chan error, 1)
				go func() { done <- g.Commit(ctx) }()
				reached(t, h)
				if !deadline {
					cancel()
				}
				err := <-done
				want := context.Canceled
				if deadline {
					want = context.DeadlineExceeded
				}
				if !errors.Is(err, gameservercommit.ErrUnknown) || !errors.Is(err, want) {
					t.Fatalf("lost reply classified as absence: %v", err)
				}
				if fenced {
					observation(t, g, gameservercommit.Uncommitted)
				}
				h.unblock()
				if fenced {
					storedStatus(t, h, 409)
					if read(t, api).Status.State != agonesv1.GameServerStateReady {
						t.Fatal("fenced canceled write allocated")
					}
				} else {
					storedStatus(t, h, 200)
					if read(t, api).Status.State != agonesv1.GameServerStateAllocated {
						t.Fatal("canceled positive control did not allocate")
					}
				}
			})
		}
	}
}

func TestRecreatedUIDIsUntouched(t *testing.T) {
	api, obj := resource(t)
	cfg, h := proxy(t)
	g := prepare(t, client(t, cfg, obj.Namespace))
	done := make(chan error, 1)
	go func() { done <- g.Commit(context.Background()) }()
	reached(t, h)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	if err := api.Delete(ctx, obj.Name, metav1.DeleteOptions{Preconditions: &metav1.Preconditions{UID: &obj.UID}}); err != nil {
		t.Fatal(err)
	}
	replacement := obj.DeepCopy()
	replacement.UID = ""
	replacement.ResourceVersion = ""
	replacement.CreationTimestamp = metav1.Time{}
	replacement, err := api.Create(ctx, replacement, metav1.CreateOptions{})
	if err != nil {
		t.Fatal(err)
	}
	if replacement.UID == obj.UID {
		t.Fatal("recreation did not change UID")
	}
	receipt, err := g.Fence(ctx)
	if !errors.Is(err, gameservercommit.ErrUnknown) {
		t.Fatalf("replacement fenced: %v", err)
	}
	if _, err = g.Accept(receipt); err == nil {
		t.Fatal("replacement granted receipt")
	}
	h.unblock()
	storedStatus(t, h, 409)
	if err = <-done; !errors.Is(err, gameservercommit.ErrConflict) {
		t.Fatalf("old UID write not refused: %v", err)
	}
	after := read(t, api)
	if after.UID != replacement.UID || after.ResourceVersion != replacement.ResourceVersion || after.Annotations[gameservercommit.BarrierAnnotation] != "" {
		t.Fatal("replacement changed")
	}
}

func TestChangedHistoryIsUnknown(t *testing.T) {
	for _, committed := range []bool{false, true} {
		t.Run(fmt.Sprintf("committed-%t", committed), func(t *testing.T) {
			api, obj := resource(t)
			g := prepare(t, client(t, control, obj.Namespace))
			if committed {
				if err := g.Commit(context.Background()); err != nil {
					t.Fatal(err)
				}
			}
			current := read(t, api)
			current.Status.State = agonesv1.GameServerStateReady
			delete(current.Labels, agones.AttemptLabel)
			if current.Annotations == nil {
				current.Annotations = make(map[string]string)
			}
			current.Annotations["trial.example/unrelated"] = "changed"
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			current, err := api.Update(ctx, current, metav1.UpdateOptions{})
			if err != nil {
				t.Fatal(err)
			}
			receipt, err := g.Fence(ctx)
			if !errors.Is(err, gameservercommit.ErrUnknown) {
				t.Fatalf("history changed into absence: %v", err)
			}
			if _, err = g.Accept(receipt); err == nil {
				t.Fatal("changed history granted receipt")
			}
			after := read(t, api)
			if after.ResourceVersion != current.ResourceVersion {
				t.Fatal("uncertain history mutated")
			}
		})
	}
}
