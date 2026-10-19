package custodywitness

import (
	"context"
	"errors"
	"maps"
	"strings"
	"sync"
	"testing"
	"time"
)

var pinnedTable = TableIdentity{ID: "table-a", CreatedAt: time.Unix(1700000000, 5).UTC()}

// fakeTable is a strongly consistent single-item compare-and-set store. Its
// fault switches model each way a real table call can end.
type fakeTable struct {
	mu          sync.Mutex
	identity    TableIdentity
	items       map[string]string
	puts, gets  int
	identityErr error
	getErr      error
	// commitThenLose stores the write and then reports an ambiguous error.
	commitThenLose bool
	// loseWithoutCommit reports an ambiguous error and stores nothing.
	loseWithoutCommit bool
	// onPut runs after a write is stored, before its reply returns.
	onPut func()
	// onGet runs after a read, before its reply returns.
	onGet func()
}

func newFake() *fakeTable {
	return &fakeTable{identity: pinnedTable, items: map[string]string{}}
}

func (f *fakeTable) Identity(context.Context) (TableIdentity, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	return f.identity, f.identityErr
}

func (f *fakeTable) Get(_ context.Context, key string) (string, bool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.gets++
	if f.getErr != nil {
		return "", false, f.getErr
	}
	value, found := f.items[key]
	if f.onGet != nil {
		f.onGet()
	}
	return value, found, nil
}

var errLost = errors.New("reply lost")

func (f *fakeTable) Put(_ context.Context, key, expected, value string) error {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.puts++
	if f.loseWithoutCommit {
		return errLost
	}
	current, found := f.items[key]
	if (expected == "" && found) || (expected != "" && (!found || current != expected)) {
		return ErrConditionFailed
	}
	f.items[key] = value
	if f.onPut != nil {
		f.onPut()
	}
	if f.commitThenLose {
		return errLost
	}
	return nil
}

func (f *fakeTable) snapshot() map[string]string {
	f.mu.Lock()
	defer f.mu.Unlock()
	return maps.Clone(f.items)
}

func newClient(t *testing.T, table Table) *Client {
	t.Helper()
	client, err := New(Config{Enabled: true, Table: table, Identity: pinnedTable})
	if err != nil {
		t.Fatal(err)
	}
	return client
}

func TestNewRefusesDisabledIncompleteOrUnpinnedConfiguration(t *testing.T) {
	var typedNil *fakeTable
	for _, cfg := range []Config{
		{Table: newFake(), Identity: pinnedTable},
		{Enabled: true, Identity: pinnedTable},
		{Enabled: true, Table: typedNil, Identity: pinnedTable},
		{Enabled: true, Table: newFake()},
		{Enabled: true, Table: newFake(), Identity: TableIdentity{ID: "table-a"}},
		{Enabled: true, Table: newFake(), Identity: TableIdentity{ID: "table a", CreatedAt: pinnedTable.CreatedAt}},
	} {
		if client, err := New(cfg); err == nil || client != nil {
			t.Fatal("unusable configuration accepted", cfg)
		}
	}
}

func TestEachStageAdvancesOnlyFromTheExactPreviousRecord(t *testing.T) {
	table := newFake()
	client := newClient(t, table)
	ctx := context.Background()
	for _, step := range []struct{ previous, next Record }{{Record{}, enrolled}, {enrolled, custody}, {custody, tombstone}} {
		got, err := client.Write(ctx, step.previous, step.next)
		if err != nil || got != step.next {
			t.Fatal("forward step refused", step.next.Stage, err)
		}
		if verdict := client.Compare(ctx, step.next); verdict != Verified {
			t.Fatal("acknowledged record not verified", step.next.Stage, verdict)
		}
	}
}

// Every refusal leaves the stored record exactly as it was.
func TestRefusalsLeaveTheWitnessUnchanged(t *testing.T) {
	ctx := context.Background()
	otherEnrollment := enrolled
	otherEnrollment.EnrollmentPin = strings.Repeat("e", 64)
	wrongPrevious := enrolled
	wrongPrevious.EnrollmentPin = strings.Repeat("e", 64)
	wrongCustody := wrongPrevious
	wrongCustody.Stage, wrongCustody.CustodyPin = StageCustody, custody.CustodyPin
	for name, attempt := range map[string]struct {
		stored         []Record
		previous, next Record
	}{
		"second enrollment with another pin": {[]Record{enrolled}, Record{}, otherEnrollment},
		"repeated enrollment":                {[]Record{enrolled}, Record{}, enrolled},
		"skipped custody":                    {[]Record{enrolled}, custody, tombstone},
		"repeated custody":                   {[]Record{enrolled, custody}, enrolled, custody},
		"wrong previous pin":                 {[]Record{enrolled}, wrongPrevious, wrongCustody},
		"write after tombstone":              {[]Record{enrolled, custody, tombstone}, custody, tombstone},
		"custody without enrollment":         {nil, enrolled, custody},
		"enrollment claimed as later stage":  {nil, Record{}, custody},
		"backward step":                      {[]Record{enrolled, custody}, custody, enrolled},
	} {
		table := newFake()
		client := newClient(t, table)
		previous := Record{}
		for _, record := range attempt.stored {
			if _, err := client.Write(ctx, previous, record); err != nil {
				t.Fatal(name, "setup failed", err)
			}
			previous = record
		}
		before := table.snapshot()
		if got, err := client.Write(ctx, attempt.previous, attempt.next); err == nil || got != (Record{}) {
			t.Fatal(name, "refused step acknowledged", got)
		}
		if !maps.Equal(before, table.snapshot()) {
			t.Fatal(name, "refused step changed the witness")
		}
	}
}

func TestReplacedOrUnreadableTableRefusesWrites(t *testing.T) {
	for name, fault := range map[string]func(*fakeTable){
		"replaced id":       func(f *fakeTable) { f.identity.ID = "table-b" },
		"recreated":         func(f *fakeTable) { f.identity.CreatedAt = f.identity.CreatedAt.Add(time.Nanosecond) },
		"identity failure":  func(f *fakeTable) { f.identityErr = errors.New("throttled") },
		"service lost both": func(f *fakeTable) { f.loseWithoutCommit = true },
	} {
		table := newFake()
		fault(table)
		if got, err := newClient(t, table).Write(context.Background(), Record{}, enrolled); err == nil || got != (Record{}) {
			t.Fatal(name, "write acknowledged")
		}
		if len(table.snapshot()) != 0 {
			t.Fatal(name, "refused write was stored")
		}
	}
}

// A lost reply is resolved by one exact re-read and never by a second write.
func TestLostReplyIsResolvedOnlyByTheExactReread(t *testing.T) {
	ctx := context.Background()
	committed := newFake()
	committed.commitThenLose = true
	if got, err := newClient(t, committed).Write(ctx, Record{}, enrolled); err != nil || got != enrolled {
		t.Fatal("committed write with a lost reply was not acknowledged", err)
	}
	if committed.puts != 1 || committed.gets != 1 {
		t.Fatal("lost reply was retried or re-read more than once", committed.puts, committed.gets)
	}

	lost := newFake()
	lost.loseWithoutCommit = true
	if got, err := newClient(t, lost).Write(ctx, Record{}, enrolled); err == nil || got != (Record{}) {
		t.Fatal("uncommitted write acknowledged")
	}
	if lost.puts != 1 || lost.gets != 1 || len(lost.snapshot()) != 0 {
		t.Fatal("uncommitted write was retried", lost.puts, lost.gets)
	}

	// A competing writer's record is not this call's acknowledgement.
	raced := newFake()
	raced.loseWithoutCommit = true
	competing, _ := EncodeRecord(Record{LifetimeKey: key, Stage: StageEnrolled, EnrollmentPin: strings.Repeat("e", 64)})
	raced.items[key] = competing
	if _, err := newClient(t, raced).Write(ctx, Record{}, enrolled); err == nil {
		t.Fatal("another writer's record acknowledged")
	}

	unreadable := newFake()
	unreadable.commitThenLose = true
	unreadable.getErr = errors.New("unavailable")
	if _, err := newClient(t, unreadable).Write(ctx, Record{}, enrolled); err == nil {
		t.Fatal("unresolved reply acknowledged")
	}
}

// A caller that gave up still learns what it committed, through the bounded
// detached re-read, and never through a retry.
func TestCanceledCallerResolvesItsOwnCommit(t *testing.T) {
	table := newFake()
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	table.onPut = cancel
	if got, err := newClient(t, table).Write(ctx, Record{}, enrolled); err != nil || got != enrolled {
		t.Fatal("a commit canceled before its reply was not resolved", err)
	}
	if table.puts != 1 || table.gets != 1 {
		t.Fatal("canceled commit was retried", table.puts, table.gets)
	}

	// A caller canceled before the write never reaches the table at all.
	early := newFake()
	canceled, stop := context.WithCancel(context.Background())
	stop()
	if _, err := newClient(t, early).Write(canceled, Record{}, enrolled); err == nil || early.puts != 0 {
		t.Fatal("canceled call reached the table", early.puts)
	}
}

func TestCompareClassifiesEveryOutcome(t *testing.T) {
	ctx := context.Background()
	write := func(t *testing.T, records ...Record) *fakeTable {
		t.Helper()
		table := newFake()
		client := newClient(t, table)
		previous := Record{}
		for _, record := range records {
			if _, err := client.Write(ctx, previous, record); err != nil {
				t.Fatal(err)
			}
			previous = record
		}
		return table
	}
	divergent := custody
	divergent.CustodyPin = strings.Repeat("e", 64)
	for name, c := range map[string]struct {
		table    *fakeTable
		expected Record
		want     Verdict
	}{
		"verified":                  {write(t, enrolled, custody), custody, Verified},
		"rolled back to enrolled":   {write(t, enrolled, custody, tombstone), enrolled, WitnessAhead},
		"rolled back to custody":    {write(t, enrolled, custody, tombstone), custody, WitnessAhead},
		"never witnessed custody":   {write(t, enrolled), custody, WitnessBehind},
		"never witnessed tombstone": {write(t, enrolled, custody), tombstone, WitnessBehind},
		"absent":                    {write(t), enrolled, Absent},
		"divergent same stage":      {write(t, enrolled, custody), divergent, Conflicting},
		"divergent behind":          {write(t, enrolled, custody), Record{LifetimeKey: key, Stage: StageTombstone, EnrollmentPin: enrolled.EnrollmentPin, CustodyPin: divergent.CustodyPin, TombstonePin: tombstone.TombstonePin}, Conflicting},
		"divergent ahead":           {write(t, enrolled, divergent), enrolled, WitnessAhead},
		"invalid expected":          {write(t, enrolled), Record{}, Unavailable},
	} {
		if got := newClient(t, c.table).Compare(ctx, c.expected); got != c.want {
			t.Fatal(name, got, "want", c.want)
		}
	}

	ahead := write(t, enrolled, custody, tombstone)
	if got := newClient(t, ahead).Compare(ctx, Record{LifetimeKey: key, Stage: StageEnrolled, EnrollmentPin: strings.Repeat("e", 64)}); got != Conflicting {
		t.Fatal("a later record of another chain read as rollback", got)
	}

	corrupt := newFake()
	corrupt.items[key] = `{"schema":2}`
	if got := newClient(t, corrupt).Compare(ctx, enrolled); got != Conflicting {
		t.Fatal("unreadable record not conflicting", got)
	}
	foreign := newFake()
	value, _ := EncodeRecord(Record{LifetimeKey: strings.Repeat("e", 64), Stage: StageEnrolled, EnrollmentPin: enrolled.EnrollmentPin})
	foreign.items[key] = value
	if got := newClient(t, foreign).Compare(ctx, enrolled); got != Conflicting {
		t.Fatal("record for another lifetime not conflicting", got)
	}

	replaced := write(t, enrolled)
	replaced.identity.ID = "table-b"
	if got := newClient(t, replaced).Compare(ctx, enrolled); got != TableReplaced {
		t.Fatal("replaced table not detected", got)
	}
	for name, fault := range map[string]func(*fakeTable){
		"identity": func(f *fakeTable) { f.identityErr = errors.New("auth refused") },
		"read":     func(f *fakeTable) { f.getErr = errors.New("throttled") },
	} {
		table := write(t, enrolled)
		fault(table)
		if got := newClient(t, table).Compare(ctx, enrolled); got != Unavailable {
			t.Fatal(name, "failure not unavailable", got)
		}
	}
}

// replacementTable is the identity a recreated table under the same name has.
var replacementTable = TableIdentity{ID: "table-b", CreatedAt: pinnedTable.CreatedAt.Add(time.Hour)}

func TestTableReplacedDuringAnOperationIsNeverAcknowledgedOrVerified(t *testing.T) {
	ctx := context.Background()

	writer := newFake()
	writer.onPut = func() { writer.identity = replacementTable }
	if got, err := newClient(t, writer).Write(ctx, Record{}, enrolled); !errors.Is(err, ErrUnknown) || got != (Record{}) {
		t.Fatal("write that reached a replacement table acknowledged", got, err)
	}

	lost := newFake()
	lost.commitThenLose = true
	lost.onGet = func() { lost.identity = replacementTable }
	if got, err := newClient(t, lost).Write(ctx, Record{}, enrolled); !errors.Is(err, ErrUnknown) || got != (Record{}) {
		t.Fatal("re-read from a replacement table acknowledged", got, err)
	}

	reader := newFake()
	if _, err := newClient(t, reader).Write(ctx, Record{}, enrolled); err != nil {
		t.Fatal(err)
	}
	reader.onGet = func() { reader.identity = replacementTable }
	if got := newClient(t, reader).Compare(ctx, enrolled); got != TableReplaced {
		t.Fatal("read from a replacement table not reported replaced", got)
	}

	unreadable := newFake()
	if _, err := newClient(t, unreadable).Write(ctx, Record{}, enrolled); err != nil {
		t.Fatal(err)
	}
	unreadable.onGet = func() { unreadable.identityErr = errLost }
	if got := newClient(t, unreadable).Compare(ctx, enrolled); got != Unavailable {
		t.Fatal("unconfirmed identity after a read not reported unavailable", got)
	}

	failing := newFake()
	if _, err := newClient(t, failing).Write(ctx, Record{}, enrolled); err != nil {
		t.Fatal(err)
	}
	failing.getErr = errLost
	failing.identity = replacementTable
	client := &Client{table: failing, identity: pinnedTable}
	failing.identity = pinnedTable
	failing.onGet = nil
	_ = client
}
