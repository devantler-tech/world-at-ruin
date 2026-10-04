package nakamaruntime

import (
	"bytes"
	"context"
	"crypto/rsa"
	"errors"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/internal/cryptotest"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	kuberuntime "k8s.io/apimachinery/pkg/runtime"
	clienttesting "k8s.io/client-go/testing"
)

// A missing composition/start call leaves an allocated orphan invisible forever.
func TestOrphanRuntimeStartsOnlyAfterRegistration(t *testing.T) {
	key, _, _ := cryptotest.Seal(t, "world-at-ruin", "zone-one", "uid-one", bytes.Repeat([]byte{1}, 32))
	for _, stage := range []string{"enabled", "disabled", "rpc failure", "shutdown failure"} {
		t.Run(stage, func(t *testing.T) {
			storage := &moduleStorage{Fake: nakamastoragetest.New()}
			r := &registration{}
			kube := agonesfake.NewSimpleClientset()
			scanned := make(chan struct{}, 4)
			var scans atomic.Int32
			kube.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, kuberuntime.Object, error) {
				scans.Add(1)
				select {
				case scanned <- struct{}{}:
				default:
				}
				return true, &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "1"}}, nil
			})
			var closed atomic.Int32
			env := validEnvironment()
			env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
			switch stage {
			case "disabled":
				env["WAR_HANDOFF_ORPHANS_ENABLED"] = "false"
			case "rpc failure":
				r.rpcErr = errors.New("registration refused")
			case "shutdown failure":
				r.shutdownErr = errors.New("registration refused")
			}
			initCtx, cancelInit := context.WithCancel(environmentContext(env))
			defer cancelInit()
			err := initialize(initCtx, storage, r, func(config) (dependencies, error) {
				return dependencies{allocator: allocatorFunction{}, resources: kube.AgonesV1().GameServers("world-at-ruin"), keys: []*rsa.PrivateKey{key}, close: func() { closed.Add(1) }}, nil
			})
			cancelInit()
			if stage == "enabled" {
				if err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { r.shutdown(context.Background(), nil, nil, storage) })
				select {
				case <-scanned:
				case <-time.After(2 * time.Second):
					t.Fatal("enabled runtime never started its resource scan")
				}
				r.shutdown(context.Background(), nil, nil, storage)
			} else {
				if stage == "disabled" {
					if err != nil {
						t.Fatal(err)
					}
					r.shutdown(context.Background(), nil, nil, storage)
				} else if err == nil {
					t.Fatal("registration failure accepted")
				}
				if scans.Load() != 0 {
					t.Fatal("inactive or rolled-back runtime started orphan cleanup")
				}
			}
			if closed.Load() != 1 {
				t.Fatal("runtime did not retire its dependencies exactly once")
			}
		})
	}
}

// An expired hook deadline must not close a transport under a held worker.
func TestOrphanShutdownDeadlineDefersRetirementUntilWorkerReturns(t *testing.T) {
	key, _, _ := cryptotest.Seal(t, "world-at-ruin", "zone-one", "uid-one", bytes.Repeat([]byte{1}, 32))
	storage := &moduleStorage{Fake: nakamastoragetest.New()}
	kube := agonesfake.NewSimpleClientset()
	entered, release, retired := make(chan struct{}), make(chan struct{}), make(chan struct{})
	var enteredOnce, releaseOnce sync.Once
	kube.PrependReactor("list", "gameservers", func(clienttesting.Action) (bool, kuberuntime.Object, error) {
		enteredOnce.Do(func() { close(entered) })
		<-release // Deliberately slow external transport completion, even after cancellation.
		return true, &agonesv1.GameServerList{ListMeta: metav1.ListMeta{ResourceVersion: "1"}}, nil
	})
	var closed atomic.Int32
	env := validEnvironment()
	env["WAR_HANDOFF_ORPHANS_ENABLED"] = "true"
	r := &registration{}
	if err := initialize(environmentContext(env), storage, r, func(config) (dependencies, error) {
		return dependencies{allocator: allocatorFunction{}, resources: kube.AgonesV1().GameServers("world-at-ruin"), keys: []*rsa.PrivateKey{key}, close: func() { closed.Add(1); close(retired) }}, nil
	}); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { releaseOnce.Do(func() { close(release) }); r.shutdown(context.Background(), nil, nil, storage) })
	select {
	case <-entered:
	case <-time.After(time.Second):
		t.Fatal("worker never reached held transport")
	}
	shutdownCtx, cancel := context.WithCancel(context.Background())
	cancel()
	r.shutdown(shutdownCtx, nil, nil, storage)
	if closed.Load() != 0 {
		t.Fatal("hook deadline retired dependencies while the orphan worker was still running")
	}
	releaseOnce.Do(func() { close(release) })
	select {
	case <-retired:
	case <-time.After(time.Second):
		t.Fatal("returned worker never retired dependencies")
	}
	r.shutdown(context.Background(), nil, nil, storage)
	if closed.Load() != 1 {
		t.Fatal("transport retirement was not exactly once")
	}
}
