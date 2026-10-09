//go:build war_native_trial

package nakamatrial

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"

	"github.com/devantler-tech/world-at-ruin/server/internal/allocatorjournal"
)

//go:embed testdata/golden_allocator_grant_journal_v1.json
var nativeJournalFixture []byte

// journalObjectID is the public deterministic fixture address, not a credential.
const journalObjectID = "c3be3a401178b7bbc9e7df4140309335b7d5f06188f18c7c8dadcd2378e466e8"

// journalExpected pins every field independently of the reader and object.
func journalExpected(count int) allocatorjournal.JournalObservation {
	grants := []allocatorjournal.JournalGrant{
		{ActorUID: "pod-a", AttemptID: "attempt-a", Name: "zone-a", UID: "uid-a", SourceVersion: "resource-a"},
		{ActorUID: "pod-b", AttemptID: "attempt-b", Name: "zone-b", UID: "uid-b", SourceVersion: "resource-b"},
	}
	digests := []string{
		"fa56417bc7a979772aba3d458f0b5ff22a3462f45e74483a79859c7942fe60ef", "04ffb01614210bbfe881e39066096a7b18aae8990342de7fdc784ded54b06730",
		"4febaec6be92e850b2d08dd58cf55bb7e368994f597c35915286be3278f79226",
	}
	return allocatorjournal.JournalObservation{Binding: allocatorjournal.JournalBinding{
		GenerationID: "generation-1", GenerationVersion: "source-version-1", MemberPodUIDs: []string{"pod-a", "pod-b"},
		MemberSetDigest: "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d",
		IncarnationID:   "incarnation-1", Namespace: "trial", Fleet: "fleet", IssuedCount: count, IssuedDigest: digests[count],
	}, Grants: grants[:count]}
}

// journalDocument changes fixture inventory only during disposable setup.
func journalDocument(t *testing.T, count int) []byte {
	t.Helper()
	var doc map[string]any
	if json.Unmarshal(nativeJournalFixture, &doc) != nil {
		t.Fatal("journal fixture unavailable")
	}
	want := journalExpected(count)
	doc["grant_count"], doc["grant_set_digest"], doc["grants"] = count, want.Binding.IssuedDigest, want.Grants
	raw, err := json.Marshal(doc)
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

// journalSeed writes only to the fresh database owned by newFixture.
func (f *fixture) journalSeed(raw []byte) {
	f.t.Helper()
	if _, err := f.db.Exec("INSERT INTO storage(collection,key,user_id,value,version,read,write,create_time,update_time) VALUES($1,$2,$3::uuid,$4::text::jsonb,md5($4::text),0,0,now(),now())", allocatorjournal.JournalCollection, journalObjectID, zeroOwner, string(raw)); err != nil {
		f.t.Fatal("seed disposable journal")
	}
}

// journalRow independently inspects the actual private object's version and bytes.
func (f *fixture) journalRow() (string, string, int, int) {
	f.t.Helper()
	var value, version string
	var read, write int
	if err := f.db.QueryRow("SELECT value::text,version,read,write FROM storage WHERE collection=$1 AND key=$2 AND user_id=$3::uuid", allocatorjournal.JournalCollection, journalObjectID, zeroOwner).Scan(&value, &version, &read, &write); err != nil {
		f.t.Fatal("read disposable journal")
	}
	return value, version, read, write
}

func journalEnv(t *testing.T, binding allocatorjournal.JournalBinding) map[string]string {
	t.Helper()
	raw, err := json.Marshal(binding)
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED": "true", "WAR_ALLOCATOR_JOURNAL_PROBE_BINDING": string(raw)}
}

// verifyJournalArtifact binds each scenario to the unchanged actual candidate.
func verifyJournalArtifact(t *testing.T) {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join(*bundle, "bundle.json"))
	if err != nil {
		t.Fatal(err)
	}
	var evidence struct {
		Schema       int               `json:"schema"`
		OS           string            `json:"os"`
		Architecture string            `json:"architecture"`
		Go           string            `json:"go_version"`
		Artifacts    map[string]string `json:"artifact_sha256"`
	}
	if json.Unmarshal(raw, &evidence) != nil || evidence.Schema != 1 || evidence.OS != "linux" || evidence.Architecture != runtime.GOARCH || evidence.Go != "go1.27.2" || len(evidence.Artifacts) != 2 {
		t.Fatal("journal candidate identity incomplete")
	}
	for _, name := range []string{"nakama", "modules/world_at_ruin.so"} {
		data, err := os.ReadFile(filepath.Join(*bundle, name))
		if err != nil {
			t.Fatal(err)
		}
		digest := sha256.Sum256(data)
		if hex.EncodeToString(digest[:]) != evidence.Artifacts[name] {
			t.Fatal("journal candidate artifact changed")
		}
		t.Logf("JOURNAL CANDIDATE: architecture=%s artifact=%s sha256=%s", runtime.GOARCH, name, evidence.Artifacts[name])
	}
}

func TestNativeJournalDefaultOff(t *testing.T) {
	verifyJournalArtifact(t)
	for _, flag := range []string{"", "false"} {
		f := newFixture(t)
		p := f.launch(map[string]string{"WAR_ALLOCATOR_JOURNAL_PROBE_ENABLED": flag, "WAR_ALLOCATOR_JOURNAL_PROBE_BINDING": "invalid", "WAR_ALLOCATOR_JOURNAL_PROBE_CANCEL_READ": "invalid"}, filepath.Join(*bundle, "modules"), 10, true)
		if strings.Contains(p.log.String(), "NAKAMA JOURNAL PROBE PASS") {
			t.Fatal("default-off candidate ran journal probe")
		}
		var rows int
		if err := f.db.QueryRow("SELECT count(*) FROM storage WHERE collection=$1", allocatorjournal.JournalCollection).Scan(&rows); err != nil || rows != 0 {
			t.Fatal("default startup created journal fixtures")
		}
		if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
			t.Fatal("default startup contacted allocation provider")
		}
		p.stop(t)
	}
}

func TestNativeJournalReadback(t *testing.T) {
	verifyJournalArtifact(t)
	for count := 0; count <= 2; count++ {
		t.Run(fmt.Sprintf("grants-%d", count), func(t *testing.T) {
			f := newFixture(t)
			f.journalSeed(journalDocument(t, count))
			before, version, read, write := f.journalRow()
			if read != 0 || write != 0 || version == "" {
				t.Fatal("fixture lacks exact private metadata")
			}
			want := journalExpected(count)
			want.Binding.Version = version
			raw, err := json.Marshal(want)
			if err != nil {
				t.Fatal(err)
			}
			digest := sha256.Sum256(raw)
			marker := fmt.Sprintf("NAKAMA JOURNAL PROBE PASS: grants=%d observation_sha256=%s", count, hex.EncodeToString(digest[:]))
			p := f.launch(journalEnv(t, want.Binding), filepath.Join(*bundle, "modules"), 10, true)
			if !strings.Contains(p.log.String(), marker) {
				t.Fatal("packaged reader did not preserve complete independent observation")
			}
			p.stop(t)
			after, afterVersion, afterRead, afterWrite := f.journalRow()
			if before != after || version != afterVersion || read != afterRead || write != afterWrite {
				t.Fatal("journal probe changed backing storage")
			}
			if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
				t.Fatal("journal observation affected allocation provider")
			}
			t.Logf("JOURNAL READBACK PASS: complete grants=%d exact-version=1 private=1 unchanged=1", count)
		})
	}
}

func TestNativeJournalRefusals(t *testing.T) {
	verifyJournalArtifact(t)
	for _, fault := range []string{"missing", "changed-version", "wrong-incarnation", "stored-incarnation", "issued-substitution", "incomplete-expectation", "malformed", "future-schema", "canceled", "public-read", "public-write"} {
		t.Run(fault, func(t *testing.T) {
			f := newFixture(t)
			raw := journalDocument(t, 2)
			switch fault {
			case "malformed":
				raw = []byte(`{"schema":1}`)
			case "future-schema":
				raw = []byte(strings.Replace(string(raw), `"schema":1`, `"schema":2`, 1))
			case "stored-incarnation", "issued-substitution":
				var doc map[string]any
				if err := json.Unmarshal(raw, &doc); err != nil {
					t.Fatal(err)
				}
				if fault == "stored-incarnation" {
					doc["authority_incarnation"] = "different-incarnation"
				} else {
					grants := journalExpected(2).Grants
					grants[0].AttemptID = "substitute-attempt"
					encoded, err := json.Marshal(grants)
					if err != nil {
						t.Fatal(err)
					}
					digest := sha256.Sum256(append([]byte("world-at-ruin/allocator-issued-grants/v1\n"), encoded...))
					doc["grants"], doc["grant_set_digest"] = grants, hex.EncodeToString(digest[:])
				}
				var err error
				raw, err = json.Marshal(doc)
				if err != nil {
					t.Fatal(err)
				}
			}
			binding := journalExpected(2).Binding
			var before, version string
			read, write := 0, 0
			if fault != "missing" {
				f.journalSeed(raw)
				if fault == "public-read" || fault == "public-write" {
					column := "read"
					if fault == "public-write" {
						column = "write"
					}
					if _, err := f.db.Exec("UPDATE storage SET "+column+"=1 WHERE collection=$1 AND key=$2", allocatorjournal.JournalCollection, journalObjectID); err != nil {
						t.Fatal(err)
					}
				}
				before, version, read, write = f.journalRow()
				binding.Version = version
			} else {
				binding.Version = "missing-version"
			}
			switch fault {
			case "changed-version":
				binding.Version = "stale-version"
			case "wrong-incarnation":
				binding.IncarnationID = "different-incarnation"
			case "incomplete-expectation":
				expected := journalExpected(1).Binding
				expected.Version = binding.Version
				binding = expected
			}
			env := journalEnv(t, binding)
			if fault == "canceled" {
				env["WAR_ALLOCATOR_JOURNAL_PROBE_CANCEL_READ"] = "true"
			}
			p := f.launch(env, filepath.Join(*bundle, "modules"), 10, false)
			if p.err == nil || !strings.Contains(p.log.String(), "journal probe: observation remains unknown") || strings.Contains(p.log.String(), "NAKAMA JOURNAL PROBE PASS") {
				t.Fatal("conflicting read did not remain wholly unknown")
			}
			if fault != "missing" {
				after, afterVersion, afterRead, afterWrite := f.journalRow()
				if before != after || version != afterVersion || read != afterRead || write != afterWrite {
					t.Fatal("refused probe mutated journal")
				}
			}
			if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
				t.Fatal("refused observation affected allocation")
			}
			t.Logf("JOURNAL REFUSAL PASS: control=%s unknown=1 partial=0 unchanged=1", fault)
		})
	}
}
