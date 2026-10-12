//go:build war_spire_trial && linux

package spiretrial

import (
	"encoding/json"
	"errors"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"time"
)

// startWorkerHTTP centralizes the identical bounded private listeners. The
// containing worker is still independently retired and joined by the fixture.
func startWorkerHTTP(listener net.Listener, handler http.Handler) func() {
	server := &http.Server{Handler: handler, ReadHeaderTimeout: 2 * time.Second, ReadTimeout: 3 * time.Second, WriteTimeout: 3 * time.Second, IdleTimeout: 3 * time.Second, ErrorLog: log.New(io.Discard, "", 0)}
	stopped := make(chan error, 1)
	go func() { stopped <- server.Serve(listener) }()
	return func() {
		_ = server.Close()
		select {
		case <-stopped:
		case <-time.After(3 * time.Second):
		}
	}
}

// readPrivateCommand distinguishes clean controller-pipe EOF from bad commands.
// Every worker loop uses this same parsing and termination boundary.
func readPrivateCommand(input *json.Decoder) (command, bool, error) {
	var c command
	err := input.Decode(&c)
	if errors.Is(err, io.EOF) {
		return command{}, false, nil
	}
	return c, err == nil, err
}

// workerCommands owns the common readiness, decode, reply and terminal-error
// protocol. A dispatcher may mark its failure terminal after a private reply.
func workerCommands(out *json.Encoder, ready response, dispatch func(command) (response, bool)) int {
	if out.Encode(ready) != nil {
		return 1
	}
	input := json.NewDecoder(os.Stdin)
	for {
		c, more, err := readPrivateCommand(input)
		if err != nil {
			return 1
		}
		if !more {
			return 0
		}
		r, terminal := dispatch(c)
		if out.Encode(r) != nil || terminal {
			return 1
		}
	}
}
