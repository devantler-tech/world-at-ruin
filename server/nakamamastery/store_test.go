package nakamamastery

import (
	"context"
	"encoding/json"
	"errors"
	"reflect"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
	"github.com/devantler-tech/world-at-ruin/server/playerstate"
)

const subject = "11111111-1111-4111-8111-111111111111"
const sibling = "22222222-2222-4222-8222-222222222222"

func setup(t *testing.T) (*Store, Authority, *nakamastoragetest.Fake, context.Context) {
	t.Helper()
	authority, err := NewAuthority(Config{Enabled: true, SourceUID: "source-1", SourceIncarnation: "incarnation-1"})
	if err != nil {
		t.Fatal(err)
	}
	storage := nakamastoragetest.New()
	store, err := NewStore(storage, authority)
	if err != nil {
		t.Fatal(err)
	}
	return store, authority, storage, nakamastoragetest.AuthenticatedContext(subject)
}

func award(t *testing.T, authority Authority, id string, amount int64) Event {
	t.Helper()
	event, err := authority.Award(subject, id, "axe", amount)
	if err != nil {
		t.Fatal(err)
	}
	return event
}

func TestPrivateOwnerReplayAndFreshAuthority(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	first := award(t, authority, "award-1", 108)
	out, err := store.Apply(ctx, first)
	if err != nil || out.State.Weapons["axe"] != (Track{100, 8}) {
		t.Fatalf("award = %#v %v", out, err)
	}
	second := award(t, authority, "award-2", 8)
	if _, err := store.Apply(ctx, second); err != nil {
		t.Fatal(err)
	}
	version := storage.NextVersion()
	out, err = store.Apply(ctx, first)
	if err != nil || out.State.Weapons["axe"] != (Track{100, 8}) || storage.NextVersion() != version {
		t.Fatalf("historical replay = %#v %v", out, err)
	}
	current, _, err := store.Load(ctx, subject)
	if err != nil || current.Weapons["axe"] != (Track{100, 16}) {
		t.Fatalf("current = %#v %v", current, err)
	}
	fresh, err := NewAuthority(Config{Enabled: true, SourceUID: "source-1", SourceIncarnation: "incarnation-1"})
	if err != nil {
		t.Fatal(err)
	}
	recovered, err := NewStore(storage, fresh)
	if err != nil {
		t.Fatal(err)
	}
	out, err = recovered.Apply(ctx, award(t, fresh, "award-1", 108))
	if err != nil || out.State.Weapons["axe"] != (Track{100, 8}) || storage.NextVersion() != version {
		t.Fatalf("fresh replay = %#v %v", out, err)
	}
	changed := award(t, authority, "award-1", 109)
	if _, err := store.Apply(ctx, changed); !errors.Is(err, playerstate.ErrKeyConflict) {
		t.Fatalf("changed amount = %v", err)
	}
	changedKind, err := authority.Death(subject, "award-1", 50)
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Apply(ctx, changedKind); !errors.Is(err, playerstate.ErrKeyConflict) {
		t.Fatalf("changed operation = %v", err)
	}
	if storage.NextVersion() != version {
		t.Fatal("conflict changed state")
	}
	for _, object := range storage.Objects() {
		if object.UserID != "00000000-0000-0000-0000-000000000000" || object.PermissionRead != 0 || object.PermissionWrite != 0 {
			t.Fatal("record or audit not private/system-owned")
		}
	}
	if len(storage.Objects()) != 3 {
		t.Fatalf("objects = %d", len(storage.Objects()))
	}
}

func TestDisabledForeignAndSiblingEventsNeverRead(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	disabled, err := NewAuthority(Config{})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := disabled.Award(subject, "award-1", "axe", 1); !errors.Is(err, ErrDisabled) {
		t.Fatalf("default off = %v", err)
	}
	if _, err := store.Apply(ctx, Event{}); err == nil {
		t.Fatal("zero event accepted")
	}
	other, err := NewAuthority(Config{Enabled: true, SourceUID: "other", SourceIncarnation: "original"})
	if err != nil {
		t.Fatal(err)
	}
	if _, err := store.Apply(ctx, award(t, other, "foreign", 1)); err == nil {
		t.Fatal("foreign seal accepted")
	}
	event := award(t, authority, "sibling", 1)
	if _, err := store.Apply(nakamastoragetest.AuthenticatedContext(sibling), event); err == nil {
		t.Fatal("sibling accepted")
	}
	if _, _, err := store.Load(ctx, sibling); err == nil {
		t.Fatal("sibling read accepted")
	}
	if storage.ReadCalls != 0 || len(storage.WriteCalls) != 0 {
		t.Fatal("invalid authority or subject reached storage")
	}
	copyAuthority := authority
	if _, err := store.Apply(ctx, award(t, copyAuthority, "copy", 1)); err != nil {
		t.Fatal(err)
	}
}

func TestNoopDeathIsAuditedBeforeLaterAward(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	seedState(t, storage, State{Schema: 1, Weapons: map[string]Track{"axe": {200, 1}}, Stain: Stain{ID: "old", Points: map[string]int64{"axe": 9}}})
	death, err := authority.Death(subject, "death-noop", 50)
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, death)
	if err != nil || len(out.Dropped) != 0 || out.State.Stain.ID != "old" {
		t.Fatalf("no-op = %#v %v", out, err)
	}
	if _, err := store.Apply(ctx, award(t, authority, "later", 5)); err != nil {
		t.Fatal(err)
	}
	before := storage.NextVersion()
	out, err = store.Apply(ctx, death)
	current, _, loadErr := store.Load(ctx, subject)
	if err != nil || loadErr != nil || len(out.Dropped) != 0 || current.Weapons["axe"] != (Track{200, 6}) || storage.NextVersion() != before || len(storage.Objects()) != 3 {
		t.Fatalf("no-op replay = %#v %#v %v", out, current, err)
	}
}

func TestDeathAndExactStainReclaimAreAtomic(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	seedState(t, storage, State{Schema: 1, Weapons: map[string]Track{"axe": {200, 75}, "spear": {100, 49}}, Stain: Stain{ID: "old", Points: map[string]int64{"axe": 7, "spear": 3}}})
	death, err := authority.Death(subject, "death-1", 50)
	if err != nil {
		t.Fatal(err)
	}
	out, err := store.Apply(ctx, death)
	if err != nil || !reflect.DeepEqual(out.Destroyed, map[string]int64{"axe": 7, "spear": 3}) {
		t.Fatalf("death = %#v %v", out, err)
	}
	wrong, err := authority.Reclaim(subject, "wrong-reclaim", "old")
	if err != nil {
		t.Fatal(err)
	}
	before := storage.NextVersion()
	if _, err := store.Apply(ctx, wrong); err == nil || storage.NextVersion() != before {
		t.Fatal("stale reclaim changed state")
	}
	reclaim, err := authority.Reclaim(subject, "reclaim-1", out.State.Stain.ID)
	if err != nil {
		t.Fatal(err)
	}
	out, err = store.Apply(ctx, reclaim)
	if err != nil || out.Credited != 61 || out.State.Weapons["axe"] != (Track{200, 75}) || out.State.Weapons["spear"] != (Track{100, 49}) || out.State.Stain.ID != "" {
		t.Fatalf("reclaim = %#v %v", out, err)
	}
	before = storage.NextVersion()
	again, err := store.Apply(ctx, reclaim)
	if err != nil || !reflect.DeepEqual(again, out) || storage.NextVersion() != before {
		t.Fatal("reclaim repeated value")
	}
	for _, batch := range storage.WriteCalls {
		if len(batch) != 2 || batch[0].Version == "" || batch[1].Version != "*" {
			t.Fatal("not conditional atomic state+audit")
		}
	}
}

func TestLostAcknowledgementAndAbsentRecovery(t *testing.T) {
	store, authority, storage, ctx := setup(t)
	storage.AfterWrite = func(int) error { return errors.New("private transport details") }
	event := award(t, authority, "lost", 105)
	out, err := store.Apply(ctx, event)
	if err != nil || out.State.Weapons["axe"] != (Track{100, 5}) || len(storage.WriteCalls) != 1 {
		t.Fatalf("recovered = %#v %v", out, err)
	}
	storage.AfterWrite = nil
	before := storage.NextVersion()
	out, err = store.Resolve(ctx, event)
	if err != nil || out.State.Weapons["axe"] != (Track{100, 5}) || storage.NextVersion() != before {
		t.Fatal("read-only recovery changed state")
	}
	missing := award(t, authority, "unobserved", 3)
	if _, err := store.Resolve(ctx, missing); !errors.Is(err, playerstate.ErrIndeterminate) {
		t.Fatalf("absence = %v", err)
	}
	storage.WriteErr = errors.New("secret backend details")
	if _, err := store.Apply(ctx, missing); !errors.Is(err, playerstate.ErrIndeterminate) || strings.Contains(err.Error(), "secret") {
		t.Fatalf("uncertain = %v", err)
	}
	cancelCtx, cancel := context.WithCancel(ctx)
	cancel()
	if _, err := store.Resolve(cancelCtx, event); !errors.Is(err, context.Canceled) || !errors.Is(err, playerstate.ErrIndeterminate) {
		t.Fatalf("cancellation = %v", err)
	}
}

func TestMalformedOrPublicRecordRefuses(t *testing.T) {
	for _, value := range []string{`{"schema":1,"weapons":{},"stain":{"id":"","points":{}}}`, `{"schema":1,"schema":1,"weapons":{},"stain":{"id":"","points":{}}}`} {
		store, _, storage, ctx := setup(t)
		storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "mastery:" + subject, Value: value, Version: "v1", PermissionRead: 2})
		if _, _, err := store.Load(ctx, subject); err == nil {
			t.Fatal("public record accepted")
		}
	}
}

func seedState(t *testing.T, storage *nakamastoragetest.Fake, state State) {
	t.Helper()
	raw, err := json.Marshal(state)
	if err != nil {
		t.Fatal(err)
	}
	storage.Seed(nakamastoragetest.Object{Collection: Collection, Key: "mastery:" + subject, Value: string(raw), Version: "seed"})
}
