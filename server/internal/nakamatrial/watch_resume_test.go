//go:build war_native_trial

package nakamatrial

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"

	"github.com/coder/websocket"
	"github.com/devantler-tech/world-at-ruin/server/handoff"
	"github.com/devantler-tech/world-at-ruin/server/wire"
)

// TestClosedLoopMovementAfterWatchLoss catches an admission-only observation
// being mistaken for irreversible termination of established session authority.
func TestClosedLoopMovementAfterWatchLoss(t *testing.T) {
	f := closedFixture(t)
	z := f.startZone("zone-a", f.key, "", false, "-movement-intents", "-movement-hold-ticks", "1")
	f.launch(f.env, filepath.Join(*bundle, "modules"), 10, true)
	account, uid := f.account("watch-resume-closed-loop")
	got := f.handoff(account)
	ctx, cancel := context.WithTimeout(t.Context(), 15*time.Second)
	defer cancel()
	c, err := z.dial(ctx, got, wire.MovementVersion)
	if err != nil {
		t.Fatal(err)
	}
	// Registered before suspension; later fixture cleanup also resumes the
	// exact child and bounds both cooperative shutdown and kill/join.
	reader := readMovement(ctx, c)
	t.Cleanup(func() {
		_ = z.process.cmd.Process.Signal(syscall.SIGCONT)
		cancel()
		_ = c.CloseNow()
		select {
		case <-reader.done:
		case <-time.After(time.Second):
			t.Error("movement reader was not joined")
		}
	})
	before := reader.next(t, ctx)
	if before.AppliedSequence != 0 {
		t.Fatal("stationary baseline already applied movement")
	}
	claimed, version := f.claimed(leaseKey(uid))
	connections := z.claimConnections.Load()
	if z.sidecar.WatchCalls() != 1 || connections == 0 {
		t.Fatal("control lacks the original SDK watch or private claim connection")
	}
	if err := z.process.cmd.Process.Signal(syscall.SIGSTOP); err != nil {
		t.Fatal("suspend exact owned child", err)
	}
	waitFor(t, time.Second, "exact child independently observed stopped", func() bool {
		select {
		case <-z.process.done:
			t.Fatal("zone exited before suspension was observed")
		default:
		}
		status, err := os.ReadFile("/proc/" + strconv.Itoa(z.process.cmd.Process.Pid) + "/status")
		if err != nil {
			t.Fatal("observe exact owned child through procfs", err)
		}
		for line := range strings.SplitSeq(string(status), "\n") {
			if fields := strings.Fields(line); len(fields) >= 2 && fields[0] == "State:" {
				return fields[1] == "T"
			}
		}
		t.Fatal("owned child procfs observation lacks state")
		return false
	})
	z.sidecar.EndWatchStreams()
	if err := z.process.cmd.Process.Signal(syscall.SIGCONT); err != nil {
		t.Fatal("resume exact owned child", err)
	}
	// EOF consumption is asynchronous. Only a genuine 401 while the original
	// handoff remains valid can establish admission refusal.
	waitFor(t, 2*time.Second, "fresh admission refused after generated watch EOF", func() bool {
		return z.unexpiredRefusal(got)
	})
	for range 2 {
		if !z.unexpiredRefusal(got) {
			t.Fatal("fresh admission refusal did not remain HTTP 401")
		}
	}
	health := z.sidecar.HealthBeats()
	waitFor(t, time.Second, "independent SDK health survives watch loss", func() bool {
		return z.sidecar.HealthBeats() > health+2
	})
	// No movement was sent before suspension. This new sequence therefore
	// cannot be acknowledged by a buffered pre-suspension frame.
	const resumedSequence = 101
	intent, err := wire.EncodeIntent(wire.MovementIntent{Sequence: resumedSequence, X: 1000, Sprint: true})
	if err != nil {
		t.Fatal(err)
	}
	if err := c.Write(ctx, websocket.MessageBinary, intent); err != nil {
		t.Fatal(err)
	}
	ack := reader.next(t, ctx)
	for ack.AppliedSequence != resumedSequence {
		ack = reader.next(t, ctx)
	}
	if ack.Tick <= before.Tick || ack.Pos.X <= before.Pos.X || ack.Pos.X-before.Pos.X > 399 || ack.Pos.Y != before.Pos.Y || ack.Pos.Z != before.Pos.Z {
		t.Fatalf("resumed exact socket did not apply bounded authoritative movement: %+v → %+v", before, ack)
	}
	for stopped := ack; ack.Tick < stopped.Tick+3; {
		ack = reader.next(t, ctx)
		if ack.AppliedSequence != resumedSequence || ack.Pos != stopped.Pos {
			t.Fatal("single resumed intent did not stop after its hold tick")
		}
	}
	after, afterVersion := f.claimed(leaseKey(uid))
	if after != claimed || afterVersion != version || z.claimConnections.Load() != connections {
		t.Fatal("watch loss changed exact private ownership or opened a new private claim connection")
	}
	z.killZone()
	t.Logf("WATCH RESUME CONTROL: exact child observed stopped; generated watch EOF; unexpired repeated HTTP 401; health active; original socket applied fresh sequence %d at newer tick; private row/version retained; no new private TCP connection; exact child killed and joined", resumedSequence)
}

// unexpiredRefusal never accepts expiry, transport failure or another HTTP code.
func (z *trialZone) unexpiredRefusal(got handoff.Handoff) bool {
	z.f.t.Helper()
	if !got.ExpiresAt.After(time.Now()) {
		z.f.t.Fatal("admission probe began after original handoff expiry")
	}
	ctx, cancel := context.WithTimeout(z.f.t.Context(), 500*time.Millisecond)
	defer cancel()
	c, err := z.dial(ctx, got, wire.MovementVersion)
	if c != nil {
		_ = c.CloseNow()
	}
	if !got.ExpiresAt.After(time.Now()) {
		z.f.t.Fatal("original handoff expired during admission probe")
	}
	return err != nil && strings.Contains(err.Error(), "zone HTTP 401:")
}

type movementRead struct {
	ack wire.MovementAck
	err error
}

type movementReader struct {
	results chan movementRead
	done    chan struct{}
}

// readMovement owns the only socket reader throughout suspension and resumption.
// Errors cross back to the test goroutine; workers never invoke testing.Fatal.
func readMovement(ctx context.Context, c *websocket.Conn) *movementReader {
	r := &movementReader{results: make(chan movementRead, 64), done: make(chan struct{})}
	go func() {
		defer close(r.done)
		defer close(r.results)
		joined := false
		for {
			kind, data, err := c.Read(ctx)
			var m wire.Message
			if err == nil {
				m, err = wire.Decode(data)
				if err == nil && (kind != websocket.MessageBinary || m.Version != wire.MovementVersion) {
					err = errors.New("movement reader received a non-v3 binary frame")
				}
				if err == nil && !joined {
					if m.Kind != wire.KindSnapshot {
						err = errors.New("movement reader omitted initial snapshot")
					} else {
						joined = true
					}
				}
			}
			if err == nil && m.Kind != wire.KindMovementAck {
				continue
			}
			select {
			case r.results <- movementRead{ack: m.Ack, err: err}:
			case <-ctx.Done():
				return
			}
			if err != nil {
				return
			}
		}
	}()
	return r
}

func (r *movementReader) next(t *testing.T, ctx context.Context) wire.MovementAck {
	t.Helper()
	select {
	case result, ok := <-r.results:
		if !ok || result.err != nil {
			t.Fatal("movement reader ended before required acknowledgement", result.err)
		}
		return result.ack
	case <-ctx.Done():
		t.Fatal("movement acknowledgement exceeded control bound", ctx.Err())
		return wire.MovementAck{}
	}
}
