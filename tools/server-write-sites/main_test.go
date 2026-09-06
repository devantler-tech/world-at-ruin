package main

import (
	"reflect"
	"testing"
)

func TestWriteSitesDoNotDependOnCollectionLiterals(t *testing.T) {
	t.Parallel()
	for name, source := range map[string]string{
		"imported-collection":     `package p; import shared "example.com/shared"; func (s *Store) Save(){ s.storage.StorageWrite(ctx, shared.Collection) }`,
		"constructed-collection":  `package p; func (s *Store) Save(){ s.storage.StorageWrite(ctx, prefix + suffix) }`,
		"captured-method":         `package p; func (s *Store) Save(){ write := s.storage.StorageWrite; write(ctx, records) }`,
		"closure":                 `package p; func (s *Store) Save(){ go func(){ s.storage.StorageWrite(ctx, records) }() }`,
		"shadowed-runtime-import": `package p; import runtime "github.com/heroiclabs/nakama-common/runtime"; type Write = runtime.StorageWrite; func (s *Store) Save(runtime Writer){ runtime.StorageWrite(ctx, records) }`,
	} {
		t.Run(name, func(t *testing.T) {
			t.Parallel()
			got, err := writeSites("server/p/store.go", []byte(source))
			want := []string{"server/p/store.go|Store.Save|StorageWrite|1"}
			if err != nil || !reflect.DeepEqual(got, want) {
				t.Fatalf("write inventory: %v, %v", got, err)
			}
		})
	}
}

func TestWriteSitesTrackEveryOccurrenceAndForwardedRecord(t *testing.T) {
	t.Parallel()
	source := `package p
import nk "github.com/heroiclabs/nakama-common/runtime"
import state "github.com/devantler-tech/world-at-ruin/server/playerstate"
var pending = state.RecordWrite{}
type Client interface { StorageWrite([]*nk.StorageWrite) }
func (s *Store) Save(){
 s.storage.StorageWrite(ctx, []*nk.StorageWrite{{}})
 s.storage.StorageWrite(ctx, writes)
 s.mutations.Apply(ctx, state.Mutation{Record:state.RecordWrite{}})
}
// s.storage.StorageWrite() is only prose
`
	got, err := writeSites("server/p/store.go", []byte(source))
	want := []string{"server/p/store.go|package|RecordWrite|1", "server/p/store.go|Store.Save|StorageWrite|1", "server/p/store.go|Store.Save|StorageWrite|2", "server/p/store.go|Store.Save|RecordWrite|1"}
	if err != nil || !reflect.DeepEqual(got, want) {
		t.Fatalf("incomplete boundary inventory: %v, %v", got, err)
	}
}

func TestWriteSitesFailClosedOnAmbiguousSource(t *testing.T) {
	t.Parallel()
	for _, source := range []string{`package p; func broken(`, `package p; import . "github.com/heroiclabs/nakama-common/runtime"`, `package p; import . "github.com/devantler-tech/world-at-ruin/server/playerstate"`} {
		if _, err := writeSites("server/p/store.go", []byte(source)); err == nil {
			t.Fatalf("ambiguous source accepted: %s", source)
		}
	}
}
