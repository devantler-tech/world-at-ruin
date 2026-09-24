package main

import (
	"context"
	"net/http"
	"strings"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/zonesock"
)

// TestListenDrainsBeforeAgonesShutdown exercises the actual serving function
// without process exit masking leaked sockets or incorrect shutdown ordering.
func TestListenDrainsBeforeAgonesShutdown(t *testing.T) {
	f, err := agonestest.Start(nil)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Stop()
	t.Setenv("AGONES_SDK_GRPC_HOST", "127.0.0.1")
	t.Setenv("AGONES_SDK_GRPC_PORT", f.PortString())
	t.Setenv("WAR_ZONE_ADMISSION_SECRET", strings.Repeat("ab", 32))
	secret := make([]byte, 32)
	for i := range secret {
		secret[i] = 0xab
	}
	token, err := zonesock.MintToken(secret, "allocation-a", 1, time.Now().Add(time.Minute))
	if err != nil {
		t.Fatal(err)
	}
	addr := "127.0.0.1:" + closedPort(t)
	options := &websocket.DialOptions{HTTPHeader: http.Header{"Authorization": {"Bearer " + token}}}
	observed := make(chan error, 1)
	f.SetShutdownHook(func() {
		ctx, cancel := context.WithTimeout(context.Background(), time.Second)
		defer cancel()
		client, response, err := websocket.Dial(ctx, "ws://"+addr+"/zone", options)
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		if client != nil {
			_ = client.CloseNow()
		}
		observed <- err
	})
	world := sim.NewDemoWorld()
	done := make(chan error, 1)
	go func() {
		done <- runListen(world, addr, "", "", "WAR_ZONE_ADMISSION_SECRET", "allocation-a", true, 12000, 500*time.Millisecond, true, 50*time.Millisecond, "")
	}()
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	var client *websocket.Conn
	for ctx.Err() == nil {
		var response *http.Response
		client, response, err = websocket.Dial(ctx, "ws://"+addr+"/zone", options)
		if response != nil && response.Body != nil {
			_ = response.Body.Close()
		}
		if err == nil {
			break
		}
		time.Sleep(5 * time.Millisecond)
	}
	if err != nil {
		t.Fatal(err)
	}
	defer func() { _ = client.CloseNow() }()
	if _, _, err := client.Read(ctx); err != nil {
		t.Fatal(err)
	}
	if err := <-done; err != nil {
		t.Fatal(err)
	}
	if err := <-observed; err == nil {
		t.Error("Agones Shutdown preceded terminal socket admission")
	}
	if world.Get(1).InterestRadius != 0 {
		t.Error("serving exit left an observer attached")
	}
}
