package nakamaruntime

import (
	"context"
	"crypto/rand"
	"crypto/rsa"
	"errors"
	"strings"
	"testing"

	agonesfake "agones.dev/agones/pkg/client/clientset/versioned/fake"
	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

func TestStartupFailureClosesDependenciesAndCannotServe(t *testing.T) {
	key, err := rsa.GenerateKey(rand.Reader, 3072)
	if err != nil {
		t.Fatal(err)
	}
	for _, stage := range []string{"connect", "compose", "rpc", "shutdown"} {
		t.Run(stage, func(t *testing.T) {
			r := &registration{}
			storage := &moduleStorage{Fake: nakamastoragetest.New()}
			closed := 0
			deps := dependencies{allocator: allocatorFunction{}, resources: agonesfake.NewSimpleClientset().AgonesV1().GameServers("world-at-ruin"), keys: []*rsa.PrivateKey{key}, close: func() { closed++ }}
			sentinel := errors.New("private-credential-path")
			switch stage {
			case "compose":
				deps.keys = nil
			case "rpc":
				r.rpcErr = sentinel
			case "shutdown":
				r.shutdownErr = sentinel
			}
			err := initialize(environmentContext(validEnvironment()), storage, r, func(config) (dependencies, error) {
				if stage == "connect" {
					return dependencies{}, sentinel
				}
				return deps, nil
			})
			if err == nil || strings.Contains(err.Error(), "private-credential-path") {
				t.Fatal("startup failure was lost or leaked")
			}
			wantClosed := 1
			if stage == "connect" {
				wantClosed = 0
			}
			if closed != wantClosed {
				t.Fatal("failed startup leaked an acquired transport")
			}
			if r.rpc != nil {
				result, err := r.rpc(signedContext(), nil, nil, storage, `{}`)
				if result != "" || err == nil {
					t.Fatal("failed initialization left a serving RPC")
				}
			}
			if len(storage.Objects()) != 0 {
				t.Fatal("failed initialization wrote a lease")
			}
		})
	}
}

func TestPublicEntrypointDisabledDoesNotRequireDeployment(t *testing.T) {
	if err := Initialize(context.Background(), nil, nil); err != nil {
		t.Fatal(err)
	}
}
