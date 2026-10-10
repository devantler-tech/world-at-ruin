//go:build war_native_trial

package nakamatrial

import (
	"encoding/json"
	"path/filepath"
	"strings"
	"testing"
)

// The admission row is created ONLY through the packaged Go runtime. SQL is
// used for independent readback, never to seed the row under test.
const admissionObjectID = "bccfcc5493d974e057fe04530eec857e7306c572868ce55c76016a12cf989fdc"

func admissionEnv(t *testing.T, scenario string) map[string]string {
	t.Helper()
	grant, err := json.Marshal(journalExpected(1).Grants[0])
	if err != nil {
		t.Fatal(err)
	}
	return map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": "true", "WAR_ALLOCATOR_ADMISSION_PROBE_SCENARIO": scenario, "WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL": string(journalDocument(t, 0)), "WAR_ALLOCATOR_ADMISSION_PROBE_GRANT": string(grant)}
}
func TestNativeAdmissionDefaultOff(t *testing.T) {
	verifyJournalArtifact(t)
	for _, flag := range []string{"", "false"} {
		t.Run("flag="+flag, func(t *testing.T) {
			f := newFixture(t)
			env := map[string]string{"WAR_ALLOCATOR_ADMISSION_PROBE_ENABLED": flag, "WAR_ALLOCATOR_ADMISSION_PROBE_JOURNAL": "invalid", "WAR_ALLOCATOR_ADMISSION_PROBE_SCENARIO": "invalid", "WAR_DURABLE_GENERATION_PROBE_ENABLED": flag, "WAR_DURABLE_GENERATION_PROBE_MATERIAL": "/invalid", "WAR_DURABLE_GENERATION_PROBE_SCENARIO": "invalid"}
			p := f.launch(env, filepath.Join(*bundle, "modules"), 10, true)
			if strings.Contains(p.log.String(), "NAKAMA ADMISSION PROBE") || strings.Contains(p.log.String(), "NAKAMA CAPABILITY PROBE") {
				t.Fatal("disabled write experiment ran")
			}
			var count int
			if f.db.QueryRow("SELECT count(*) FROM storage WHERE collection='world_at_ruin_allocator_admissions'").Scan(&count) != nil || count != 0 {
				t.Fatal("disabled experiment wrote storage")
			}
			if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
				t.Fatal("disabled experiment touched GameServer path")
			}
		})
	}
}
func TestNativeAdmissionConditionalTransitions(t *testing.T) {
	verifyJournalArtifact(t)
	for _, scenario := range []string{"sequence", "incarnation-race", "drain-race", "lost-ack"} {
		t.Run(scenario, func(t *testing.T) {
			f := newFixture(t)
			p := f.launch(admissionEnv(t, scenario), filepath.Join(*bundle, "modules"), 10, true)
			if !strings.Contains(p.log.String(), "NAKAMA ADMISSION PROBE PASS: scenario="+scenario+" ") {
				t.Fatal("native write scenario did not complete")
			}
			var value, version, owner string
			var read, write, count int
			if f.db.QueryRow("SELECT value::text,version,user_id::text,read,write FROM storage WHERE collection='world_at_ruin_allocator_admissions' AND key=$1", admissionObjectID).Scan(&value, &version, &owner, &read, &write) != nil || version == "" || owner != zeroOwner || read != 0 || write != 0 {
				t.Fatal("private admission row not persisted at generation-wide key")
			}
			if f.db.QueryRow("SELECT count(*) FROM storage WHERE collection='world_at_ruin_allocator_admissions'").Scan(&count) != nil || count != 1 {
				t.Fatal("another incarnation created a separate authority root")
			}
			var got struct {
				Schema  int
				Phase   string
				Journal struct {
					Generation   string   `json:"generation_id"`
					Source       string   `json:"generation_source_version"`
					Members      []string `json:"member_pod_uids"`
					MemberDigest string   `json:"member_set_digest"`
					Incarnation  string   `json:"authority_incarnation"`
					Namespace    string
					Fleet        string
					Count        int    `json:"grant_count"`
					Digest       string `json:"grant_set_digest"`
					Grants       []struct {
						Actor     string `json:"actor_uid"`
						Attempt   string `json:"attempt_id"`
						Name, UID string
						Source    string `json:"source_version"`
					}
				}
			}
			if json.Unmarshal([]byte(value), &got) != nil || got.Schema != 1 || got.Journal.Generation != "generation-1" || got.Journal.Source != "source-version-1" || len(got.Journal.Members) != 2 || got.Journal.Members[0] != "pod-a" || got.Journal.Members[1] != "pod-b" || got.Journal.MemberDigest != "5452b4d6f907967c5ef74179a64c12ea48755828ccea8fc9aac8092faa3bfe0d" || got.Journal.Namespace != "trial" || got.Journal.Fleet != "fleet" {
				t.Fatal("immutable generation binding changed")
			}
			wantCount := 0
			switch scenario {
			case "sequence":
				wantCount = 1
				if got.Phase != "draining" {
					t.Fatal("stale registration reopened drain")
				}
			case "incarnation-race":
				if got.Phase != "open" || (got.Journal.Incarnation != "incarnation-1" && got.Journal.Incarnation != "contending-incarnation") {
					t.Fatal("incarnation election lost binding")
				}
			case "drain-race":
				if got.Phase == "open" {
					wantCount = 1
				} else if got.Phase != "draining" {
					t.Fatal("invalid race outcome")
				}
			case "lost-ack":
				if got.Phase != "open" || !strings.Contains(p.log.String(), "phase=unknown grants=-1") {
					t.Fatal("lost reply restored authority")
				}
			}
			if scenario != "incarnation-race" && got.Journal.Incarnation != "incarnation-1" {
				t.Fatal("authority incarnation changed")
			}
			if got.Journal.Count != wantCount || len(got.Journal.Grants) != wantCount {
				t.Fatal("registration/drain inventory incomplete")
			}
			wantDigest := "fa56417bc7a979772aba3d458f0b5ff22a3462f45e74483a79859c7942fe60ef"
			if wantCount == 1 {
				wantDigest = "04ffb01614210bbfe881e39066096a7b18aae8990342de7fdc784ded54b06730"
				g := got.Journal.Grants[0]
				if g.Actor != "pod-a" || g.Attempt != "attempt-a" || g.Name != "zone-a" || g.UID != "uid-a" || g.Source != "resource-a" {
					t.Fatal("frozen grant identity changed")
				}
			}
			if got.Journal.Digest != wantDigest {
				t.Fatal("stored complete-set digest changed")
			}
			if allocations, requests := f.counts(); allocations != 0 || requests != 0 {
				t.Fatal("admission experiment touched GameServer allocation")
			}
			t.Logf("ADMISSION CAS PASS: scenario=%s phase=%s grants=%d private=1 root_count=1", scenario, got.Phase, wantCount)
		})
	}
}
