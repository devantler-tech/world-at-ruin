package fencereference

import (
	"crypto/sha256"
	"crypto/tls"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"reflect"
	"strings"
	"sync"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/nakamageneration"
)

func referenceConfig() Config {
	return Config{Enabled: true, Record: nakamageneration.Record{
		GenerationID: "generation-1", MemberPodUIDs: []string{"actor-a", "actor-b"},
		MemberSetDigest: "0b9f16d661afb1f86220747ba6a7302a190925b4f682b7dafd576400370f3d57",
		State:           "open", Version: "source-version-1",
	}, ActorSPKI: map[string][32]byte{"actor-a": {1}, "actor-b": {2}}, MaxAttempts: 4}
}

func newReference(t *testing.T) *Reference {
	t.Helper()
	r, err := New(referenceConfig())
	if err != nil {
		t.Fatal(err)
	}
	return r
}

func membershipConfig(t *testing.T, count int) Config {
	t.Helper()
	cfg := referenceConfig()
	cfg.Record.MemberPodUIDs = make([]string, count)
	cfg.ActorSPKI = make(map[string][32]byte, count)
	for i := range count {
		uid := fmt.Sprintf("actor-%03d", i)
		cfg.Record.MemberPodUIDs[i] = uid
		cfg.ActorSPKI[uid] = sha256.Sum256([]byte(uid))
	}
	encoded, err := json.Marshal(cfg.Record.MemberPodUIDs)
	if err != nil {
		t.Fatal(err)
	}
	digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-generation-members/v1\n"), encoded...))
	cfg.Record.MemberSetDigest = hex.EncodeToString(digest[:])
	return cfg
}

func admit(t *testing.T, r *Reference, actor, attempt string) Ticket {
	t.Helper()
	ticket, err := r.Admit(actor, attempt)
	if err != nil {
		t.Fatal(err)
	}
	return ticket
}

func fence(t *testing.T, r *Reference) Receipt {
	t.Helper()
	if err := r.Drain(); err != nil {
		t.Fatal(err)
	}
	receipt, err := r.Fence()
	if err != nil {
		t.Fatal(err)
	}
	return receipt
}

func TestReferenceIsDisabledByDefault(t *testing.T) {
	t.Parallel()
	cfg := referenceConfig()
	cfg.Enabled = false
	if r, err := New(cfg); r != nil || !errors.Is(err, ErrDisabled) {
		t.Fatalf("disabled = %v, %v", r, err)
	}
	if r, err := New(Config{}); r != nil || !errors.Is(err, ErrDisabled) {
		t.Fatalf("zero config = %v, %v", r, err)
	}
}

func TestGenerationContextRejectsAmbiguousMembership(t *testing.T) {
	t.Parallel()
	cases := []struct {
		name   string
		change func(*Config)
	}{
		{"empty generation", func(c *Config) { c.Record.GenerationID = "" }},
		{"whitespace", func(c *Config) { c.Record.GenerationID = "bad id" }},
		{"oversize identity", func(c *Config) { c.Record.GenerationID = strings.Repeat("x", 129) }},
		{"oversize version", func(c *Config) { c.Record.Version = strings.Repeat("x", 1025) }},
		{"missing version", func(c *Config) { c.Record.Version = "" }},
		{"wildcard version", func(c *Config) { c.Record.Version = "*" }},
		{"non-open record", func(c *Config) { c.Record.State = "fenced" }},
		{"wrong digest", func(c *Config) { c.Record.MemberSetDigest = "0" }},
		{"wrong order", func(c *Config) { c.Record.MemberPodUIDs = []string{"actor-b", "actor-a"} }},
		{"duplicate", func(c *Config) { c.Record.MemberPodUIDs = []string{"actor-a", "actor-a"} }},
		{"empty members", func(c *Config) { c.Record.MemberPodUIDs = nil }},
		{"missing actor key", func(c *Config) { delete(c.ActorSPKI, "actor-b") }},
		{"foreign actor key", func(c *Config) { c.ActorSPKI["foreign"] = [32]byte{3} }},
		{"shared actor key", func(c *Config) { c.ActorSPKI["actor-b"] = c.ActorSPKI["actor-a"] }},
		{"zero actor key", func(c *Config) { c.ActorSPKI["actor-b"] = [32]byte{} }},
		{"negative budget", func(c *Config) { c.MaxAttempts = -1 }},
		{"excess budget", func(c *Config) { c.MaxAttempts = 4097 }},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			t.Parallel()
			cfg := referenceConfig()
			tc.change(&cfg)
			if r, err := New(cfg); r != nil || !errors.Is(err, ErrInvalid) {
				t.Fatalf("New = %v, %v", r, err)
			}
		})
	}
}

func TestContextMembershipAndBudgetLimits(t *testing.T) {
	t.Parallel()
	for _, count := range []int{256, 257} {
		_, err := New(membershipConfig(t, count))
		if count == 256 && err != nil {
			t.Fatalf("maximum membership refused: %v", err)
		}
		if count == 257 && !errors.Is(err, ErrInvalid) {
			t.Fatalf("excess membership accepted: %v", err)
		}
	}
	for _, budget := range []int{0, 4096} {
		cfg := referenceConfig()
		cfg.MaxAttempts = budget
		r, err := New(cfg)
		if err != nil {
			t.Fatal(err)
		}
		count := budget
		if count == 0 {
			count = 256
		}
		for i := range count {
			admit(t, r, "actor-a", fmt.Sprintf("attempt-%d", i))
		}
		if _, err := r.Admit("actor-a", "over-limit"); !errors.Is(err, ErrBudget) {
			t.Fatalf("budget %d over-limit = %v", budget, err)
		}
	}
}

func TestContextOwnsItsMembershipAndIdentityKeys(t *testing.T) {
	t.Parallel()
	cfg := referenceConfig()
	r, err := New(cfg)
	if err != nil {
		t.Fatal(err)
	}
	cfg.Record.MemberPodUIDs[0] = "replacement"
	cfg.ActorSPKI["actor-a"] = [32]byte{9}
	binding := r.Binding()
	if binding.GenerationID != "generation-1" || binding.SourceVersion != "source-version-1" || binding.MemberSetDigest != referenceConfig().Record.MemberSetDigest {
		t.Fatalf("binding = %+v", binding)
	}
	ticket := admit(t, r, "actor-a", "attempt-1")
	if err := r.Commit(ticket, "actor-a", "resource-1"); err != nil {
		t.Fatal(err)
	}
	if _, err := r.Admit("replacement", "attempt-2"); !errors.Is(err, ErrIdentity) {
		t.Fatalf("replaced actor = %v", err)
	}
}

func TestScopedAdmissionHasNoSecondDispatchAndHonorsBudget(t *testing.T) {
	t.Parallel()
	r := newReference(t)
	first := admit(t, r, "actor-a", "attempt-1")
	if _, err := r.Admit("actor-b", "attempt-1"); !errors.Is(err, ErrConflict) {
		t.Fatalf("duplicate = %v", err)
	}
	for i := 2; i <= 4; i++ {
		admit(t, r, "actor-a", fmt.Sprintf("attempt-%d", i))
	}
	if _, err := r.Admit("actor-a", "attempt-5"); !errors.Is(err, ErrBudget) {
		t.Fatalf("budget = %v", err)
	}
	if err := r.Commit(first, "actor-b", "resource-1"); !errors.Is(err, ErrIdentity) {
		t.Fatalf("foreign actor commit = %v", err)
	}
	if err := r.Commit(Ticket{}, "actor-a", "resource-1"); !errors.Is(err, ErrTicket) {
		t.Fatalf("forged ticket = %v", err)
	}
	if err := r.Commit(first, "actor-a", "resource-1"); err != nil {
		t.Fatal(err)
	}
}

func TestCommitIsOwnedAtomicAndIdempotent(t *testing.T) {
	t.Parallel()
	r := newReference(t)
	ticket := admit(t, r, "actor-a", "attempt-1")
	if err := r.Commit(ticket, "actor-a", "resource-1"); err != nil {
		t.Fatal(err)
	}
	if err := r.Commit(ticket, "actor-a", "resource-1"); err != nil {
		t.Fatal(err)
	}
	if err := r.Commit(ticket, "actor-a", "changed"); !errors.Is(err, ErrConflict) {
		t.Fatalf("changed replay = %v", err)
	}
	other := admit(t, r, "actor-b", "attempt-2")
	if err := r.Commit(other, "actor-b", "resource-1"); !errors.Is(err, ErrConflict) {
		t.Fatalf("double allocation = %v", err)
	}
	got := r.Snapshot()
	want := []Allocation{{ActorUID: "actor-a", AttemptID: "attempt-1", ResourceUID: "resource-1"}}
	if !reflect.DeepEqual(got, want) {
		t.Fatalf("ledger = %+v, want %+v", got, want)
	}
	got[0].ResourceUID = "caller mutation"
	if !reflect.DeepEqual(r.Snapshot(), want) {
		t.Fatal("snapshot aliases authority")
	}
}

func TestAttemptAndResourceIdentifiersAreBoundedBeforeMutation(t *testing.T) {
	t.Parallel()
	for _, value := range []string{"", "bad id", strings.Repeat("x", 129)} {
		r := newReference(t)
		if _, err := r.Admit("actor-a", value); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid attempt %q: %v", value, err)
		}
		ticket := admit(t, r, "actor-a", "valid-attempt")
		if err := r.Commit(ticket, "actor-a", value); !errors.Is(err, ErrInvalid) {
			t.Fatalf("invalid resource %q: %v", value, err)
		}
		if len(r.Snapshot()) != 0 {
			t.Fatal("invalid identity mutated ledger")
		}
	}
}

func TestDrainSerializesWithAdmissionAndCommit(t *testing.T) {
	t.Parallel()
	for round := 0; round < 100; round++ {
		r := newReference(t)
		ticket := admit(t, r, "actor-a", "before")
		start := make(chan struct{})
		var wg sync.WaitGroup
		wg.Add(3)
		go func() { defer wg.Done(); <-start; _ = r.Drain() }()
		go func() { defer wg.Done(); <-start; _, _ = r.Admit("actor-b", "racing") }()
		go func() { defer wg.Done(); <-start; _ = r.Commit(ticket, "actor-a", "resource-1") }()
		close(start)
		wg.Wait()
		before := r.Snapshot()
		if _, err := r.Admit("actor-a", "after"); !errors.Is(err, ErrClosed) {
			t.Fatalf("post-drain admit = %v", err)
		}
		if err := r.Commit(ticket, "actor-a", "resource-2"); !errors.Is(err, ErrClosed) {
			t.Fatalf("post-drain commit = %v", err)
		}
		if !reflect.DeepEqual(before, r.Snapshot()) {
			t.Fatal("post-drain mutation")
		}
		if err := r.Drain(); err != nil {
			t.Fatalf("repeat drain = %v", err)
		}
	}
}

func TestReceiptsRequireCompleteExactOriginatingAuthority(t *testing.T) {
	t.Parallel()
	r := newReference(t)
	if _, err := r.Fence(); !errors.Is(err, ErrProof) {
		t.Fatalf("open fence = %v", err)
	}
	receipt := fence(t, r)
	if err := r.Accept(receipt, r.Binding()); err != nil {
		t.Fatal(err)
	}
	if err := r.Accept(Receipt{}, r.Binding()); !errors.Is(err, ErrProof) {
		t.Fatalf("empty receipt = %v", err)
	}
	mutations := []struct {
		name   string
		change func(*Receipt)
	}{
		{"digest", func(v *Receipt) { v.binding.MemberSetDigest = "other" }},
		{"generation", func(v *Receipt) { v.binding.GenerationID = "other" }},
		{"source version", func(v *Receipt) { v.binding.SourceVersion = "other" }},
		{"missing members", func(v *Receipt) { v.members = v.members[:1] }},
		{"extra members", func(v *Receipt) { v.members = append(v.members, "other") }},
		{"reordered members", func(v *Receipt) { v.members[0], v.members[1] = v.members[1], v.members[0] }},
		{"stale revision", func(v *Receipt) { v.revision-- }},
		{"foreign owner", func(v *Receipt) { v.owner = newReference(t).authority }},
	}
	for _, mutation := range mutations {
		t.Run(mutation.name, func(t *testing.T) {
			t.Parallel()
			altered := receipt
			altered.members = receipt.Members()
			mutation.change(&altered)
			if err := r.Accept(altered, r.Binding()); !errors.Is(err, ErrProof) {
				t.Fatalf("tampered receipt accepted: %v", err)
			}
		})
	}
	wrongDigest := r.Binding()
	wrongDigest.MemberSetDigest = "other"
	if err := r.Accept(receipt, wrongDigest); !errors.Is(err, ErrProof) {
		t.Fatalf("wrong pinned digest = %v", err)
	}
	wrong := r.Binding()
	wrong.SourceVersion = "another-version"
	if err := r.Accept(receipt, wrong); !errors.Is(err, ErrProof) {
		t.Fatalf("wrong version = %v", err)
	}
	wrong = r.Binding()
	wrong.GenerationID = "another-generation"
	if err := r.Accept(receipt, wrong); !errors.Is(err, ErrProof) {
		t.Fatalf("wrong generation = %v", err)
	}
	members := receipt.Members()
	members[0] = "other"
	if !reflect.DeepEqual(receipt.Members(), []string{"actor-a", "actor-b"}) {
		t.Fatal("receipt membership aliases caller")
	}
	if _, err := r.Admit("actor-a", "late"); !errors.Is(err, ErrClosed) {
		t.Fatalf("fenced admit = %v", err)
	}
	repeated, err := r.Fence()
	if err != nil || r.Accept(repeated, r.Binding()) != nil {
		t.Fatalf("repeat fence = %v", err)
	}
}

func TestUnknownResultCannotBecomeProof(t *testing.T) {
	t.Parallel()
	r := newReference(t)
	ticket := admit(t, r, "actor-a", "attempt-1")
	if _, err := r.Resolve(ticket, Receipt{}); !errors.Is(err, ErrProof) {
		t.Fatalf("missing proof = %v", err)
	}
	if err := r.Commit(ticket, "actor-a", "resource-1"); err != nil {
		t.Fatal(err)
	}
	result, err := r.Resolve(ticket, fence(t, r))
	if err != nil {
		t.Fatal(err)
	}
	if result.Unallocated || result.Allocation.ResourceUID != "resource-1" {
		t.Fatalf("committed resolution = %+v", result)
	}
}

func TestFreshIncarnationRefusesOldTicketsAndReceipts(t *testing.T) {
	t.Parallel()
	old := newReference(t)
	ticket := admit(t, old, "actor-a", "attempt-1")
	receipt := fence(t, old)
	fresh := newReference(t)
	if err := fresh.Commit(ticket, "actor-a", "resource-1"); !errors.Is(err, ErrTicket) {
		t.Fatalf("old ticket = %v", err)
	}
	if err := fresh.Accept(receipt, fresh.Binding()); !errors.Is(err, ErrProof) {
		t.Fatalf("old receipt = %v", err)
	}
	if _, err := fresh.Resolve(ticket, receipt); !errors.Is(err, ErrProof) && !errors.Is(err, ErrTicket) {
		t.Fatalf("old resolution = %v", err)
	}
	if len(fresh.Snapshot()) != 0 {
		t.Fatal("restart reconstructed unproved state")
	}
}

func TestCopiedHandleCannotRetainOpenCommitAuthority(t *testing.T) {
	t.Parallel()
	original := newReference(t)
	copied := *original
	ticket := admit(t, &copied, "actor-a", "attempt-1")
	receipt := fence(t, original)
	if err := original.Accept(receipt, original.Binding()); err != nil {
		t.Fatal(err)
	}
	if err := copied.Commit(ticket, "actor-a", "late-resource"); !errors.Is(err, ErrClosed) {
		t.Fatalf("copied handle bypassed original fence: %v", err)
	}
	if len(original.Snapshot()) != 0 || len(copied.Snapshot()) != 0 {
		t.Fatal("accepted fence permitted copied-handle mutation")
	}
	if result, err := copied.Resolve(ticket, receipt); err != nil || !result.Unallocated {
		t.Fatalf("copied handle lost originating proof: %+v %v", result, err)
	}
}

func TestTLSConfigurationCannotDisableVerification(t *testing.T) {
	t.Parallel()
	r := newReference(t)
	for _, cfg := range []*tls.Config{nil, {InsecureSkipVerify: true, ServerName: "allocator.test"}, {}} {
		if _, err := r.TLSConfig("actor-a", cfg); !errors.Is(err, ErrIdentity) {
			t.Fatalf("unsafe TLS accepted: %v", err)
		}
	}
	if _, err := r.TLSConfig("foreign", &tls.Config{ServerName: "allocator.test"}); !errors.Is(err, ErrIdentity) {
		t.Fatalf("foreign actor = %v", err)
	}
}
