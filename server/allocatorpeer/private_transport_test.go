package allocatorpeer

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"errors"
	"io"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/nettest"
)

type privateCandidate func(context.Context) (net.Listener, error)

var errPrivateTransport = errors.New("native allocator transport prerequisite unavailable: complete bidirectional private IPv4 exchange required")

// Every candidate is owned by this setup, proven before TLS, and either retained
// still-bound or closed. A failed cleanup is never permission to try another.
func selectPrivateTransport(ctx context.Context, candidates []privateCandidate) (net.Listener, error) {
	ctx, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	for _, candidate := range candidates {
		if ctx.Err() != nil {
			break
		}
		attempt, stop := context.WithTimeout(ctx, 300*time.Millisecond)
		listener, err := candidate(attempt)
		if err == nil && listener != nil {
			err = provePrivateTransport(attempt, listener)
		}
		stop()
		if err == nil && listener != nil && ctx.Err() == nil {
			return listener, nil
		}
		if listener != nil {
			if closeErr := listener.Close(); closeErr != nil && !errors.Is(closeErr, net.ErrClosed) {
				return nil, errPrivateTransport
			}
		}
	}
	return nil, errPrivateTransport
}

// provePrivateTransport observes complete writes and matching complete reads in
// both directions, then joins its sole accept worker before returning.
func provePrivateTransport(ctx context.Context, listener net.Listener) (err error) {
	deadline, bounded := ctx.Deadline()
	if !bounded || ctx.Err() != nil {
		return errPrivateTransport
	}
	challenge := make([]byte, 32)
	if _, err := rand.Read(challenge); err != nil {
		return errPrivateTransport
	}
	answer := sha256.Sum256(challenge)
	retireListener := closeOnProbeCancellation(ctx, listener)
	defer func() {
		retireListener()
		if ctx.Err() != nil {
			err = errPrivateTransport
		}
	}()
	done := make(chan error, 1)
	go func() {
		done <- func() (err error) {
			conn, err := listener.Accept()
			if err != nil {
				return err
			}
			retire := closeOnProbeCancellation(ctx, conn)
			defer func() { retire(); err = errors.Join(err, conn.Close()) }()
			if err := conn.SetDeadline(deadline); err != nil {
				return err
			}
			got := make([]byte, len(challenge))
			if _, err := io.ReadFull(conn, got); err != nil {
				return err
			}
			if !bytes.Equal(got, challenge) {
				return errPrivateTransport
			}
			n, err := conn.Write(answer[:])
			if err == nil && n != len(answer) {
				return io.ErrShortWrite
			}
			return err
		}()
	}()
	conn, dialErr := (&net.Dialer{}).DialContext(ctx, "tcp", listener.Addr().String())
	if dialErr != nil {
		_ = listener.Close()
		<-done
		return errPrivateTransport
	}
	retireClient := closeOnProbeCancellation(ctx, conn)
	exchangeErr := func() error {
		if err := conn.SetDeadline(deadline); err != nil {
			return err
		}
		if n, err := conn.Write(challenge); err != nil || n != len(challenge) {
			return errPrivateTransport
		}
		got := make([]byte, len(answer))
		if _, err := io.ReadFull(conn, got); err != nil {
			return err
		}
		if !bytes.Equal(got, answer[:]) {
			return errPrivateTransport
		}
		return nil
	}()
	retireClient()
	closeErr := conn.Close()
	if exchangeErr != nil {
		_ = listener.Close()
	}
	serverErr := <-done
	if exchangeErr != nil || closeErr != nil || serverErr != nil {
		return errPrivateTransport
	}
	return nil
}

// A cancel callback is retired or joined, never left able to close a retained
// listener after successful selection has handed it to the native TLS fixture.
func closeOnProbeCancellation(ctx context.Context, closer io.Closer) func() {
	done := make(chan struct{})
	stop := context.AfterFunc(ctx, func() { _ = closer.Close(); close(done) })
	return func() {
		if !stop() {
			<-done
		}
	}
}

// Binding and dialing the first candidate must not hide missing return bytes.
func TestPrivateTransportSelectionRequiresCompleteExchange(t *testing.T) {
	first := &faultyProbeListener{Listener: nettest.Loopback(t), mode: "silent"}
	second := nettest.Loopback(t)
	ctx, cancel := context.WithTimeout(t.Context(), time.Second)
	defer cancel()
	got, err := selectPrivateTransport(ctx, []privateCandidate{
		func(context.Context) (net.Listener, error) { return first, nil },
		func(context.Context) (net.Listener, error) { return second, nil },
	})
	if err != nil || got != second || !first.closed.Load() {
		t.Fatal("bind-only candidate prevented usable transport selection")
	}
	// The proven listener remains reserved for the subsequent real TLS server.
	if conn, err := (&net.Dialer{Timeout: time.Second}).DialContext(t.Context(), "tcp", second.Addr().String()); err != nil {
		t.Fatal("successful probe retired the selected listener")
	} else {
		_ = conn.Close()
	}
}

type faultyProbeListener struct {
	net.Listener
	mode   string
	closed atomic.Bool
	writes atomic.Int32
}
type faultyProbeConnection struct {
	net.Conn
	owner  *faultyProbeListener
	once   sync.Once
	closed chan struct{}
}

func (l *faultyProbeListener) Accept() (net.Conn, error) {
	conn, err := l.Listener.Accept()
	if err != nil {
		return nil, err
	}
	return &faultyProbeConnection{Conn: conn, owner: l, closed: make(chan struct{})}, nil
}
func (l *faultyProbeListener) Close() error {
	l.closed.Store(true)
	err := l.Listener.Close()
	if l.mode == "listener-close-error" {
		return errors.New("private fixture cleanup failure")
	}
	return err
}
func (c *faultyProbeConnection) Close() error {
	c.once.Do(func() { close(c.closed) })
	err := c.Conn.Close()
	if c.owner.mode == "close-error" {
		return errors.New("private fixture cleanup failure")
	}
	return err
}
func (c *faultyProbeConnection) Write(p []byte) (int, error) {
	c.owner.writes.Add(1)
	defer c.owner.writes.Add(-1)
	switch c.owner.mode {
	case "silent":
		return len(p), nil
	case "wrong", "listener-close-error":
		data := bytes.Clone(p)
		data[0] ^= 1
		return c.Conn.Write(data)
	case "truncated":
		_, err := c.Conn.Write(p[:8])
		return len(p), err
	case "short":
		return c.Conn.Write(p[:8])
	case "stall":
		<-c.closed
		return 0, net.ErrClosed
	default:
		return c.Conn.Write(p)
	}
}

func TestPrivateTransportRefusesIncompleteOrUnretiredExchange(t *testing.T) {
	for _, mode := range []string{"wrong", "truncated", "short", "close-error", "stall"} {
		t.Run(mode, func(t *testing.T) {
			listener := &faultyProbeListener{Listener: nettest.Loopback(t), mode: mode}
			ctx, cancel := context.WithTimeout(t.Context(), 100*time.Millisecond)
			defer cancel()
			got, err := selectPrivateTransport(ctx, []privateCandidate{func(context.Context) (net.Listener, error) { return listener, nil }})
			if got != nil || !errors.Is(err, errPrivateTransport) || !listener.closed.Load() || listener.writes.Load() != 0 {
				t.Fatal("incomplete exchange or active accept worker was accepted")
			}
			if strings.Contains(err.Error(), listener.Addr().String()) {
				t.Fatal("prerequisite error exposed private endpoint")
			}
		})
	}
}

type heldAcceptListener struct {
	net.Listener
	once   sync.Once
	closed chan struct{}
	joined atomic.Bool
}

func (l *heldAcceptListener) Accept() (net.Conn, error) {
	<-l.closed
	l.joined.Store(true)
	return nil, net.ErrClosed
}
func (l *heldAcceptListener) Close() error {
	l.once.Do(func() { close(l.closed) })
	return l.Listener.Close()
}

func TestPrivateTransportCancellationJoinsAccept(t *testing.T) {
	listener := &heldAcceptListener{Listener: nettest.Loopback(t), closed: make(chan struct{})}
	ctx, cancel := context.WithTimeout(t.Context(), 30*time.Millisecond)
	defer cancel()
	got, err := selectPrivateTransport(ctx, []privateCandidate{func(context.Context) (net.Listener, error) { return listener, nil }})
	if got != nil || !errors.Is(err, errPrivateTransport) || !listener.joined.Load() {
		t.Fatal("canceled setup retained an accept worker")
	}
}

func TestPrivateTransportAbsenceAndCanceledSetup(t *testing.T) {
	for _, canceled := range []bool{false, true} {
		ctx, cancel := context.WithCancel(t.Context())
		if canceled {
			cancel()
		}
		calls := 0
		got, err := selectPrivateTransport(ctx, []privateCandidate{func(context.Context) (net.Listener, error) {
			calls++
			return nil, errors.New("private fixture bind failure")
		}})
		cancel()
		wantCalls := 1
		if canceled {
			wantCalls = 0
		}
		if got != nil || !errors.Is(err, errPrivateTransport) || calls != wantCalls {
			t.Fatal("unavailable or canceled setup reported transport support")
		}
	}
	if got, err := selectPrivateTransport(t.Context(), nil); got != nil || !errors.Is(err, errPrivateTransport) {
		t.Fatal("absent candidates reported support")
	}
}

func TestPrivateTransportUnknownCleanupStopsSelection(t *testing.T) {
	listener := &faultyProbeListener{Listener: nettest.Loopback(t), mode: "listener-close-error"}
	later := false
	got, err := selectPrivateTransport(t.Context(), []privateCandidate{
		func(context.Context) (net.Listener, error) { return listener, nil },
		func(context.Context) (net.Listener, error) { later = true; return nettest.Loopback(t), nil },
	})
	if got != nil || !errors.Is(err, errPrivateTransport) || later || !listener.closed.Load() {
		t.Fatal("unknown cleanup permitted another listener")
	}
}
