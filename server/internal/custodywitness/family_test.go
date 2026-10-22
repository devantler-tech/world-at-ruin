package custodywitness

import (
	"context"
	"errors"
	"strings"
	"testing"
)

// witnessFamily drives one record family through the client so that the
// failure behaviour both families share is proven once, for each of them.
type witnessFamily struct {
	name string
	// storageKey is where the family's record for key is stored.
	storageKey string
	// open writes the family's opening record. It reports whether the call
	// acknowledged exactly that record; a refusal must return the zero record.
	open func(context.Context, *Client) (acknowledged bool, err error)
	// compare compares the opening record with the witness.
	compare func(context.Context, *Client) Verdict
	// competing is another chain's opening record for the same key, encoded.
	competing string
}

func witnessFamilies(t *testing.T) []witnessFamily {
	t.Helper()
	otherEnrollment := enrolled
	otherEnrollment.EnrollmentPin = strings.Repeat("e", 64)
	zoneCompeting, _ := EncodeRecord(otherEnrollment)
	root := generationHistory()[0]
	otherRoot := root
	otherRoot.RegistrationPin = strings.Repeat("0", 64)
	generationCompeting, _ := EncodeGenerationRecord(otherRoot)
	return []witnessFamily{
		{
			name:       "zone",
			storageKey: key,
			open: func(ctx context.Context, c *Client) (bool, error) {
				got, err := c.Write(ctx, Record{}, enrolled)
				if err != nil && got != (Record{}) {
					t.Fatal("zone refusal returned a record", got)
				}
				return err == nil && got == enrolled, err
			},
			compare:   func(ctx context.Context, c *Client) Verdict { return c.Compare(ctx, enrolled) },
			competing: zoneCompeting,
		},
		{
			name:       "generation",
			storageKey: generationStorageKey(key),
			open: func(ctx context.Context, c *Client) (bool, error) {
				got, err := c.WriteGeneration(ctx, GenerationRecord{}, root)
				if err != nil && got != (GenerationRecord{}) {
					t.Fatal("generation refusal returned a record", got)
				}
				return err == nil && got == root, err
			},
			compare:   func(ctx context.Context, c *Client) Verdict { return c.CompareGeneration(ctx, root) },
			competing: generationCompeting,
		},
	}
}

// A lost reply is resolved by one exact re-read and never by a second write; a
// refused condition or a replaced table is never acknowledged.
func TestEveryFamilyResolvesWriteFailuresTheSameWay(t *testing.T) {
	ctx := context.Background()
	for _, family := range witnessFamilies(t) {
		for name, c := range map[string]struct {
			setup        func(*fakeTable)
			acknowledged bool
			puts, gets   int
		}{
			"committed, reply lost":  {func(f *fakeTable) { f.commitThenLose = true }, true, 1, 1},
			"not committed":          {func(f *fakeTable) { f.loseWithoutCommit = true }, false, 1, 1},
			"re-read unavailable":    {func(f *fakeTable) { f.commitThenLose, f.getErr = true, errLost }, false, 1, 1},
			"refused condition":      {func(f *fakeTable) { f.items[family.storageKey] = family.competing }, false, 1, 0},
			"another writer's chain": {func(f *fakeTable) { f.loseWithoutCommit, f.items[family.storageKey] = true, family.competing }, false, 1, 1},
			"replaced before write":  {func(f *fakeTable) { f.identity = replacementTable }, false, 0, 0},
			"identity unreadable":    {func(f *fakeTable) { f.identityErr = errLost }, false, 0, 0},
			"replaced by the write": {func(f *fakeTable) {
				f.onPut = func() { f.identity = replacementTable }
			}, false, 1, 0},
			"replaced before the re-read settles": {func(f *fakeTable) {
				f.commitThenLose, f.onGet = true, func() { f.identity = replacementTable }
			}, false, 1, 1},
		} {
			table := newFake()
			c.setup(table)
			acknowledged, err := family.open(ctx, newClient(t, table))
			if acknowledged != c.acknowledged || (!acknowledged && !errors.Is(err, ErrUnknown)) {
				t.Fatal(family.name, name, "acknowledged", acknowledged, err)
			}
			if table.puts != c.puts || table.gets != c.gets {
				t.Fatal(family.name, name, "writes and re-reads", table.puts, table.gets)
			}
		}

		// A caller that gave up still learns what it committed.
		table := newFake()
		canceled, cancel := context.WithCancel(ctx)
		table.onPut = cancel
		if acknowledged, err := family.open(canceled, newClient(t, table)); !acknowledged || table.puts != 1 || table.gets != 1 {
			t.Fatal(family.name, "a commit canceled before its reply was not resolved by one re-read", err)
		}
		cancel()
	}
}

func TestEveryFamilyReportsAnUnpinnedOrUnreadableTable(t *testing.T) {
	ctx := context.Background()
	for _, family := range witnessFamilies(t) {
		for name, c := range map[string]struct {
			fault func(*fakeTable)
			want  Verdict
		}{
			"replaced":             {func(f *fakeTable) { f.identity = replacementTable }, TableReplaced},
			"replaced by the read": {func(f *fakeTable) { f.onGet = func() { f.identity = replacementTable } }, TableReplaced},
			"identity unreadable":  {func(f *fakeTable) { f.identityErr = errors.New("auth refused") }, Unavailable},
			"identity lost after the read": {func(f *fakeTable) {
				f.onGet = func() { f.identityErr = errLost }
			}, Unavailable},
			"read failed": {func(f *fakeTable) { f.getErr = errors.New("throttled") }, Unavailable},
		} {
			table := newFake()
			if acknowledged, err := family.open(ctx, newClient(t, table)); !acknowledged {
				t.Fatal(family.name, "setup write refused", err)
			}
			c.fault(table)
			if got := family.compare(ctx, newClient(t, table)); got != c.want {
				t.Fatal(family.name, name, got, "want", c.want)
			}
		}
	}
}
