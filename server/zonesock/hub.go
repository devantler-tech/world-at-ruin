// Package zonesock is the zone server's client-facing socket: the
// WebSocket-over-TLS endpoint the transport ADR (docs/design/zone-transport.md)
// settled, carrying the versioned wire codec one message per WebSocket binary
// frame in each direction.
//
// The package implements the ADR's protection contract:
//
//   - Admission is fail-closed. An allocation-scoped bearer token is verified
//     before the WebSocket upgrade, so an unverified peer is refused before any
//     world state exists for it to receive.
//   - The per-observer send queue is bounded. On overflow the queued deltas are
//     dropped and replaced by one fresh full snapshot — the codec's resync
//     path — so a slow client costs bounded memory, never an unbounded buffer.
//   - Sockets carry write and idle deadlines. A peer that does not drain writes
//     or answer pings in time is disconnected and its observer state released.
//   - Inbound reads carry a hard size limit far below the codec's
//     server-to-client ceiling, and wire v1 defines no client-to-server kinds,
//     so any inbound data message is a protocol violation.
//
// Concurrency contract: all sim.World access stays on the caller's simulation
// goroutine. Connection goroutines only touch their own queue and socket;
// attach/detach requests are marshalled onto the sim goroutine, which runs
// them inside Hub.Tick.
package zonesock

import (
	"context"
	"errors"
	"log"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/coder/websocket"

	"github.com/devantler-tech/world-at-ruin/server/sim"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// Config parameterises a Hub. Zero values (except Verifier) fall back to the
// defaults below, so operators only name what they mean to change.
type Config struct {
	// Verifier admits connections. Required: a Hub cannot be built without
	// one, so there is no accidental open-admission mode.
	Verifier TokenVerifier
	// InterestMM is the area-of-interest radius (mm) granted to each admitted
	// observer.
	InterestMM int64
	// MaxInboundBytes is the hard read limit for a single inbound WebSocket
	// message, enforced at the socket layer — wire.Decode's entity-count caps
	// run only after a whole message is assembled, so this bound is what
	// protects memory. Client→server messages are small control traffic, so
	// the default is kilobytes, never the codec's multi-megabyte
	// server→client ceiling.
	MaxInboundBytes int64
	// SendQueue bounds the per-observer queue of encoded outbound frames.
	// Overflow triggers the drop-and-resync rule, so this is the knob that
	// trades resync frequency against per-observer memory.
	SendQueue int
	// WriteTimeout is the deadline for writing one frame to a peer.
	WriteTimeout time.Duration
	// IdleTimeout bounds peer unresponsiveness: the socket pings every
	// IdleTimeout/2 and each ping must be answered within IdleTimeout/2, so
	// an unresponsive peer is disconnected within roughly IdleTimeout.
	IdleTimeout time.Duration
}

// Defaults for every optional Config field.
const (
	DefaultInterestMM      = 12_000
	DefaultMaxInboundBytes = 4 << 10
	DefaultSendQueue       = 64
	DefaultWriteTimeout    = 10 * time.Second
	DefaultIdleTimeout     = 30 * time.Second
)

func (c Config) withDefaults() Config {
	if c.InterestMM <= 0 {
		c.InterestMM = DefaultInterestMM
	}
	if c.MaxInboundBytes <= 0 {
		c.MaxInboundBytes = DefaultMaxInboundBytes
	}
	if c.SendQueue < 1 {
		c.SendQueue = DefaultSendQueue
	}
	if c.WriteTimeout <= 0 {
		c.WriteTimeout = DefaultWriteTimeout
	}
	if c.IdleTimeout <= 0 {
		c.IdleTimeout = DefaultIdleTimeout
	}
	return c
}

// Hub owns every zone socket connection and bridges them to the simulation:
// the HTTP side admits peers and spawns their read/write goroutines, while the
// sim goroutine calls Tick once per simulation tick to attach, detach and pump
// replication frames. The conns map is owned by the sim goroutine exclusively.
type Hub struct {
	cfg Config

	mu      sync.Mutex
	pending []func(w *sim.World)

	conns map[sim.EntityID]*conn // sim-goroutine-owned

	connected atomic.Int64
}

// NewHub builds a Hub from cfg, applying defaults to unset fields. It refuses
// a missing Verifier: admission is fail-closed by construction.
func NewHub(cfg Config) (*Hub, error) {
	if cfg.Verifier == nil {
		return nil, errors.New("zonesock: Config.Verifier is required")
	}
	return &Hub{cfg: cfg.withDefaults(), conns: make(map[sim.EntityID]*conn)}, nil
}

// Connected reports how many observers are currently attached. It is safe from
// any goroutine and exists for operational visibility and tests.
func (h *Hub) Connected() int { return int(h.connected.Load()) }

// enqueue schedules f to run on the simulation goroutine during the next Tick.
func (h *Hub) enqueue(f func(w *sim.World)) {
	h.mu.Lock()
	h.pending = append(h.pending, f)
	h.mu.Unlock()
}

// Tick pumps the socket layer for one simulation tick. It must be called from
// the simulation goroutine, after World.Step: it first runs the pending
// attach/detach requests (the only path by which connection goroutines reach
// the World), then sends each attached observer its snapshot delta for this
// tick. It never blocks on a peer — a full queue takes the drop-and-resync
// path in send.
func (h *Hub) Tick(w *sim.World) {
	h.mu.Lock()
	pending := h.pending
	h.pending = nil
	h.mu.Unlock()
	for _, f := range pending {
		f(w)
	}
	for _, c := range h.conns {
		h.pump(w, c)
	}
}

// attach admits c into the replication set: it grants the observer its
// interest radius, primes a snapshot tracker, and enqueues the join snapshot
// (wire KindSnapshot). It refuses an unknown observer and a second connection
// for an already-attached one — closing happens off the sim goroutine so a
// slow close handshake can never stall the tick loop.
func (h *Hub) attach(w *sim.World, c *conn) {
	if w.Get(c.observer) == nil {
		go c.close(websocket.StatusPolicyViolation, "unknown observer")
		return
	}
	if _, taken := h.conns[c.observer]; taken {
		go c.close(websocket.StatusPolicyViolation, "observer already connected")
		return
	}
	w.SetInterestRadius(c.observer, h.cfg.InterestMM)
	join := w.Snapshot(c.observer)
	c.tracker = sim.NewSnapshotTracker(c.observer)
	c.tracker.Update(w) // prime: the join snapshot already carries this state
	b, err := wire.EncodeSnapshot(join)
	if err != nil {
		// Sim guarantees canonical snapshots, so this is an upstream
		// determinism bug — fail loudly for this peer, keep the zone alive.
		log.Printf("zonesock: encode join snapshot for observer %d: %v", c.observer, err)
		go c.close(websocket.StatusInternalError, "encode failure")
		return
	}
	h.conns[c.observer] = c
	h.connected.Add(1)
	h.send(w, c, b)
}

// detach releases c's observer state. Guarded on identity so a refused
// duplicate connection's teardown can never release the live connection's
// state.
func (h *Hub) detach(w *sim.World, c *conn) {
	if cur, ok := h.conns[c.observer]; ok && cur == c {
		delete(h.conns, c.observer)
		h.connected.Add(-1)
		w.SetInterestRadius(c.observer, 0)
	}
}

// pump sends c its delta for the current tick, skipping empty deltas so a
// still world costs no bandwidth.
func (h *Hub) pump(w *sim.World, c *conn) {
	d := c.tracker.Update(w)
	if d.Empty() {
		return
	}
	b, err := wire.EncodeSnapshotDelta(d)
	if err != nil {
		log.Printf("zonesock: encode delta for observer %d: %v", c.observer, err)
		go c.close(websocket.StatusInternalError, "encode failure")
		return
	}
	h.send(w, c, b)
}

// send enqueues one encoded frame without ever blocking the sim goroutine. On
// overflow it implements the ADR rule: drop everything queued and replace it
// with one fresh full snapshot, re-priming the tracker so every later delta is
// relative to the resync point.
func (h *Hub) send(w *sim.World, c *conn, frame []byte) {
	select {
	case c.out <- frame:
		return
	default:
	}
drain:
	for {
		select {
		case <-c.out:
		default:
			break drain
		}
	}
	resync := w.Snapshot(c.observer)
	c.tracker = sim.NewSnapshotTracker(c.observer)
	c.tracker.Update(w)
	b, err := wire.EncodeSnapshot(resync)
	if err != nil {
		log.Printf("zonesock: encode resync snapshot for observer %d: %v", c.observer, err)
		go c.close(websocket.StatusInternalError, "encode failure")
		return
	}
	select {
	case c.out <- b:
	default:
		// Unreachable in practice: only the sim goroutine enqueues, the queue
		// was just drained, and capacity is at least 1. If it ever happens the
		// next overflow resyncs again — the client converges regardless.
	}
}

// Handler returns the HTTP handler that admits and upgrades zone socket
// connections. Admission runs before the upgrade: a missing or failing token
// is refused with 401 and no WebSocket ever exists for that peer. The handler
// serves whatever path it is mounted on.
func (h *Hub) Handler() http.Handler {
	return http.HandlerFunc(func(rw http.ResponseWriter, r *http.Request) {
		token, ok := bearerToken(r.Header.Get("Authorization"))
		if !ok {
			http.Error(rw, "missing bearer token", http.StatusUnauthorized)
			return
		}
		observer, err := h.cfg.Verifier.Verify(token)
		if err != nil {
			// One generic refusal: which check failed is not the peer's
			// business.
			http.Error(rw, "admission refused", http.StatusUnauthorized)
			return
		}
		ws, err := websocket.Accept(rw, r, nil)
		if err != nil {
			return
		}
		ws.SetReadLimit(h.cfg.MaxInboundBytes)
		ctx, cancel := context.WithCancel(context.Background())
		c := &conn{
			hub:      h,
			ws:       ws,
			observer: observer,
			out:      make(chan []byte, h.cfg.SendQueue),
			ctx:      ctx,
			cancel:   cancel,
		}
		h.enqueue(func(w *sim.World) { h.attach(w, c) })
		go c.writeLoop(h.cfg)
		go c.readLoop()
	})
}

// bearerToken extracts the token from an Authorization: Bearer header.
func bearerToken(header string) (string, bool) {
	const prefix = "Bearer "
	if len(header) > len(prefix) && strings.EqualFold(header[:len(prefix)], prefix) {
		return header[len(prefix):], true
	}
	return "", false
}

// conn is one admitted peer: its socket, its bounded outbound queue, and the
// snapshot tracker the sim goroutine drives for it. The tracker is
// sim-goroutine-owned; the queue is the only cross-goroutine surface.
type conn struct {
	hub      *Hub
	ws       *websocket.Conn
	observer sim.EntityID
	out      chan []byte
	ctx      context.Context
	cancel   context.CancelFunc
	once     sync.Once
	tracker  *sim.SnapshotTracker // sim-goroutine-owned
}

// teardown severs the connection immediately, without a close handshake, and
// schedules the observer's release. Used when the peer is already gone or
// unresponsive.
func (c *conn) teardown() {
	c.once.Do(func() {
		c.cancel()
		c.hub.enqueue(func(w *sim.World) { c.hub.detach(w, c) })
		c.ws.CloseNow()
	})
}

// close severs the connection with a proper close frame carrying code and
// reason, and schedules the observer's release. The handshake runs before the
// context is cancelled: cancelling first would abort the underlying
// connection mid-handshake, and the peer would see a dead socket instead of
// the code and reason.
func (c *conn) close(code websocket.StatusCode, reason string) {
	c.once.Do(func() {
		c.hub.enqueue(func(w *sim.World) { c.hub.detach(w, c) })
		c.ws.Close(code, reason)
		c.cancel()
	})
}

// writeLoop drains the outbound queue under the write deadline and keeps the
// idle deadline armed: it pings every IdleTimeout/2 and requires each ping
// answered within IdleTimeout/2, so a peer that neither drains nor responds is
// torn down within roughly IdleTimeout.
func (c *conn) writeLoop(cfg Config) {
	defer c.teardown()
	ping := time.NewTicker(cfg.IdleTimeout / 2)
	defer ping.Stop()
	for {
		select {
		case <-c.ctx.Done():
			return
		case b := <-c.out:
			ctx, cancel := context.WithTimeout(c.ctx, cfg.WriteTimeout)
			err := c.ws.Write(ctx, websocket.MessageBinary, b)
			cancel()
			if err != nil {
				return
			}
		case <-ping.C:
			ctx, cancel := context.WithTimeout(c.ctx, cfg.IdleTimeout/2)
			err := c.ws.Ping(ctx)
			cancel()
			if err != nil {
				return
			}
		}
	}
}

// readLoop services the socket's inbound side. Reading is what processes the
// peer's control frames (pong, close); the read limit set at accept time
// bounds how much a hostile peer can make the server assemble. Wire v1
// defines no client→server kinds, so any inbound data message is a protocol
// violation.
func (c *conn) readLoop() {
	if _, _, err := c.ws.Read(c.ctx); err != nil {
		c.teardown()
		return
	}
	c.close(websocket.StatusPolicyViolation, "wire v1 defines no client messages")
}
