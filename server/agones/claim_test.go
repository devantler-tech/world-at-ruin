package agones

import (
	"context"
	"strings"
	"testing"
	"time"

	sdkproto "agones.dev/agones/pkg/sdk"
	"github.com/devantler-tech/world-at-ruin/server/agones/agonestest"
	"google.golang.org/protobuf/proto"
)

const testLeaseID = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
const testAttemptDigest = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

func preparedClaim(t *testing.T) (*PreparedAdmission, *agonestest.Sidecar, context.CancelFunc) {
	t.Helper()
	f := startFake(t, nil)
	f.SetGameServer("games", "zone-17", "uid-17", "Starting")
	_, publicPEM := wrappingKey(t)
	ctx, cancel := context.WithCancel(context.Background())
	t.Cleanup(cancel)
	p, err := PrepareAdmission(ctx, Config{HealthInterval: time.Millisecond, Logf: t.Logf}, AdmissionConfig{
		WrappingPublicKeyPEM: publicPEM,
	})
	if err != nil {
		t.Fatal(err)
	}
	return p, f, cancel
}

func allocatedClaimSnapshot(t *testing.T, f *agonestest.Sidecar) *sdkproto.GameServer {
	t.Helper()
	gs, err := f.GetGameServer(context.Background(), &sdkproto.Empty{})
	if err != nil {
		t.Fatal(err)
	}
	gs.Status.State = "Allocated"
	gs.ObjectMeta.Annotations[ClaimLocatorAnnotation] = "v1." + testLeaseID + "." + testAttemptDigest
	gs.ObjectMeta.Labels[AttemptLabel] = testAttemptDigest
	return gs
}

func TestClaimBindingRequiresObservedExactAllocation(t *testing.T) {
	p, f, cancel := preparedClaim(t)
	defer cancel()
	if _, err := p.ClaimBinding(); err == nil {
		t.Fatal("Starting metadata granted a claim binding")
	}
	gs := allocatedClaimSnapshot(t, f)
	f.HoldWatchEvents()
	f.PublishGameServer(gs)
	if _, err := p.ClaimBinding(); err == nil {
		t.Fatal("unobserved allocation granted a claim binding")
	}
	f.ReleaseWatchEvents()
	var binding ClaimBinding
	waitFor(t, time.Second, func() bool {
		var err error
		binding, err = p.ClaimBinding()
		return err == nil
	}, "observed claim binding")
	if binding.Namespace != "games" || binding.AllocationID != "zone-17" || binding.GameServerUID != "uid-17" ||
		binding.LeaseObjectID != testLeaseID || binding.AttemptDigest != testAttemptDigest {
		t.Fatal("claim binding does not name the exact allocated resource and locator")
	}
	if !p.ClaimBindingCurrent(binding) {
		t.Fatal("fresh binding is not current")
	}
	altered := binding
	altered.GameServerUID = "sibling"
	if p.ClaimBindingCurrent(altered) || !p.ClaimBindingCurrent(binding) {
		t.Fatal("a caller can mutate the observed binding")
	}
	bad := proto.CloneOf(gs)
	bad.Status.State = "Shutdown"
	f.PublishGameServer(bad)
	waitFor(t, time.Second, func() bool { return !p.ClaimBindingCurrent(binding) }, "binding invalidation")
	f.PublishGameServer(gs)
	waitFor(t, time.Second, func() bool { _, err := p.ClaimBinding(); return err == nil }, "new observation")
	if p.ClaimBindingCurrent(binding) {
		t.Fatal("an old claim survived an invalidation and restoration of identical metadata")
	}
	cancel()
	if _, err := p.ClaimBinding(); err == nil {
		t.Fatal("canceled preparation kept admitting claims")
	}
}

func TestClaimBindingRejectsInvalidMetadata(t *testing.T) {
	p, f, cancel := preparedClaim(t)
	defer cancel()
	valid := allocatedClaimSnapshot(t, f)
	for _, tc := range []struct {
		name   string
		mutate func(*sdkproto.GameServer)
	}{
		{"namespace", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Namespace = "other" }},
		{"name", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Name = "other" }},
		{"UID", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Uid = "other" }},
		{"state", func(gs *sdkproto.GameServer) { gs.Status.State = "Ready" }},
		{"deletion", func(gs *sdkproto.GameServer) { gs.ObjectMeta.DeletionTimestamp = 1 }},
		{"envelope", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Annotations[AdmissionEnvelopeAnnotation] += "a" }},
		{"key", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Annotations[AdmissionKeyAnnotation] = "other" }},
		{"ready label", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Labels[AdmissionReadyLabel] = "other" }},
		{"missing locator", func(gs *sdkproto.GameServer) { delete(gs.GetObjectMeta().GetAnnotations(), ClaimLocatorAnnotation) }},
		{"wrong version", func(gs *sdkproto.GameServer) {
			gs.ObjectMeta.Annotations[ClaimLocatorAnnotation] = "v2." + testLeaseID + "." + testAttemptDigest
		}},
		{"uppercase key", func(gs *sdkproto.GameServer) {
			gs.ObjectMeta.Annotations[ClaimLocatorAnnotation] = "v1." + strings.ToUpper(testLeaseID) + "." + testAttemptDigest
		}},
		{"noncanonical digest", func(gs *sdkproto.GameServer) {
			gs.ObjectMeta.Annotations[ClaimLocatorAnnotation] = "v1." + testLeaseID + "." + strings.Repeat("a", 51) + "b"
		}},
		{"attempt mismatch", func(gs *sdkproto.GameServer) { gs.ObjectMeta.Labels[AttemptLabel] = strings.Repeat("b", 52) }},
	} {
		t.Run(tc.name, func(t *testing.T) {
			f.PublishGameServer(valid)
			var binding ClaimBinding
			waitFor(t, time.Second, func() bool { var err error; binding, err = p.ClaimBinding(); return err == nil }, "valid allocation")
			bad := proto.CloneOf(valid)
			tc.mutate(bad)
			f.PublishGameServer(bad)
			waitFor(t, time.Second, func() bool { return !p.ClaimBindingCurrent(binding) }, "invalid observation")
			if _, err := p.ClaimBinding(); err == nil {
				t.Fatal("invalid metadata still admits a new claim")
			}
		})
	}
}

func TestClaimBindingRefusesAfterWatchEndsWhileHealthRemainsHealthy(t *testing.T) {
	p, f, cancel := preparedClaim(t)
	defer cancel()
	lifecycle, err := p.Ready()
	if err != nil {
		t.Fatal(err)
	}
	defer func() {
		if err := lifecycle.Shutdown(); err != nil {
			t.Error(err)
		}
	}()
	f.PublishGameServer(allocatedClaimSnapshot(t, f))
	var binding ClaimBinding
	waitFor(t, 5*time.Second, func() bool { var err error; binding, err = p.ClaimBinding(); return err == nil }, "allocated binding")
	beats := f.HealthBeats()
	f.EndWatchStreams()
	waitFor(t, 5*time.Second, func() bool { return f.HealthBeats() > beats+2 }, "continued health stream")
	waitFor(t, time.Second, func() bool { return !p.ClaimBindingCurrent(binding) }, "watch termination refusal")
}

func TestPreparedAdmissionRefusesReadyAfterWatchEnds(t *testing.T) {
	p, f, cancel := preparedClaim(t)
	defer cancel()
	f.EndWatchStreams()
	waitFor(t, time.Second, func() bool { return p.binding.ctx.Err() != nil }, "watch termination")
	if lifecycle, err := p.Ready(); err == nil {
		if stopErr := lifecycle.Shutdown(); stopErr != nil {
			t.Error(stopErr)
		}
		t.Fatal("ended observation watch still advertised readiness")
	}
	if f.ReadyCalls() != 0 {
		t.Fatal("ended observation watch called Ready on the sidecar")
	}
	if err := p.Shutdown(); err != nil {
		t.Fatal(err)
	}
}

func TestClaimBindingInvalidatesOnLifecycleShutdownAndWatchLoss(t *testing.T) {
	for _, loseWatch := range []bool{false, true} {
		t.Run(map[bool]string{false: "shutdown", true: "sidecar recovery"}[loseWatch], func(t *testing.T) {
			p, f, cancel := preparedClaim(t)
			defer cancel()
			lifecycle, err := p.Ready()
			if err != nil {
				t.Fatal(err)
			}
			f.PublishGameServer(allocatedClaimSnapshot(t, f))
			var binding ClaimBinding
			waitFor(t, time.Second, func() bool { var err error; binding, err = p.ClaimBinding(); return err == nil }, "allocated binding")
			if loseWatch {
				f.KillHealthStreamAt(f.HealthBeats() + 1)
				waitFor(t, 5*time.Second, func() bool { return !p.ClaimBindingCurrent(binding) }, "watch-loss refusal")
			}
			if err := lifecycle.Shutdown(); err != nil {
				t.Fatal(err)
			}
			if p.ClaimBindingCurrent(binding) {
				t.Fatal("stopped lifecycle kept a claim binding")
			}
		})
	}
}
