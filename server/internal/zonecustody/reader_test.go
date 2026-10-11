package zonecustody

import (
	"context"
	"encoding/json"
	"os"
	"strings"
	"testing"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/nakamastorage/nakamastoragetest"
)

// Returning zero diagnostics, ignoring fixtures or accepting future/duplicate
// fields would lose the independently pinned original lifetime.
func TestEveryShippedEnrollmentRemainsReadable(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_zone_enrollment_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeEnrollment(string(raw))
	if err != nil || got.OwnerID != "supervisor-a" || got.ChildIncarnation != "child-a" || got.Lifetime.Namespace != "world" || got.Lifetime.AllocationID != "zone-a" || got.Lifetime.GameServerUID != "uid-a" || got.Lifetime.LeaseObjectID != strings.Repeat("a", 64) || got.Lifetime.AttemptDigest != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" {
		t.Fatal("historical enrollment lost", got, err)
	}
}

func TestEveryShippedCustodyRemainsReadable(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_zone_custody_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	got, err := DecodeCustody(string(raw))
	if err != nil || got.Enrollment.OwnerID != "supervisor-a" || got.Enrollment.ChildIncarnation != "child-a" || got.EnrollmentVersion != "v1" || got.Receipt.Namespace != "world" || got.Receipt.Observer != 7 || got.Receipt.Fence.LeaseObjectID != strings.Repeat("a", 64) || got.Receipt.Fence.AttemptDigest != "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" || got.Receipt.Fence.AllocationID != "zone-a" || got.Receipt.Fence.GameServerUID != "uid-a" || got.Receipt.Fence.LeaseVersion != "original-version" || !got.Receipt.Fence.Generation.Equal(time.Unix(123, 456)) {
		t.Fatal("historical custody lost", got, err)
	}
}

func TestStrictReadersRefuseIncompleteAndConflictingDocuments(t *testing.T) {
	enrollment, err := os.ReadFile("testdata/golden_zone_enrollment_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	custody, err := os.ReadFile("testdata/golden_zone_custody_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, fixture := range []struct {
		family string
		raw    []byte
	}{{"enrollment", enrollment}, {"custody", custody}} {
		family, raw := fixture.family, fixture.raw
		read := func(value string) error {
			if family == "enrollment" {
				_, err = DecodeEnrollment(value)
			} else {
				_, err = DecodeCustody(value)
			}
			return err
		}
		for _, bad := range []string{"null", "[]", string(raw) + "{}", strings.Replace(string(raw), `"schema":1`, `"schema":2`, 1), strings.Replace(string(raw), `"schema":1`, `"schema":1,"schema":1`, 1), strings.Replace(string(raw), `"namespace":"world"`, `"namespace":"world","namespace":"world"`, 1), strings.Replace(string(raw), `"owner_id":"supervisor-a"`, `"owner_id":null`, 1), strings.Replace(string(raw), `"child_incarnation":"child-a"`, `"foreign":"child-a"`, 1)} {
			if read(bad) == nil {
				t.Fatal("ambiguous document accepted", family, bad)
			}
		}
	}
}

// Ordinary Unmarshal at either nested level accepts foreign/duplicate fields.
// Each required member is independently corrupted without changing siblings.
func TestReceiptAndFenceRequireStrictCompleteObjects(t *testing.T) {
	raw, err := os.ReadFile("testdata/golden_zone_custody_v1.json")
	if err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{strings.Replace(string(raw), `"owner_id":"supervisor-a"`, `"owner_id":"\ud800"`, 1), strings.Replace(string(raw), `"LeaseVersion":"original-version"`, `"LeaseVersion":"\udfff"`, 1)} {
		if _, err = DecodeCustody(bad); err == nil {
			t.Fatal("lossy Unicode identity accepted")
		}
	}
	var document struct {
		Receipt json.RawMessage `json:"receipt"`
	}
	if err = json.Unmarshal(raw, &document); err != nil {
		t.Fatal(err)
	}
	var receipt struct{ Fence json.RawMessage }
	if err = json.Unmarshal(document.Receipt, &receipt); err != nil {
		t.Fatal(err)
	}
	for _, object := range []struct {
		raw    json.RawMessage
		fields []string
	}{
		{document.Receipt, []string{`"Namespace":"world"`, `"Observer":7`, `"Fence":` + string(receipt.Fence)}},
		{receipt.Fence, []string{`"LeaseObjectID":"` + strings.Repeat("a", 64) + `"`, `"LeaseVersion":"original-version"`, `"AttemptDigest":"` + strings.Repeat("a", 52) + `"`, `"AllocationID":"zone-a"`, `"GameServerUID":"uid-a"`, `"Generation":"1970-01-01T00:02:03.000000456Z"`}},
	} {
		original := string(object.raw)
		badObjects := []string{"null", "[]", "7", original + "{}"}
		for _, member := range object.fields {
			name, _, _ := strings.Cut(member, ":")
			without := strings.Replace(original, member+",", "", 1)
			if without == original {
				without = strings.Replace(original, ","+member, "", 1)
			}
			if without == original {
				t.Fatal("fixture member not exercised", name)
			}
			badObjects = append(badObjects, without, strings.Replace(original, member, name+":null", 1), strings.Replace(original, member, member+","+member, 1), strings.Replace(original, member, member+`,"foreign":7`, 1))
		}
		for _, bad := range badObjects {
			value := strings.Replace(string(raw), original, bad, 1)
			if _, err = DecodeCustody(value); err == nil {
				t.Fatal("ambiguous nested custody accepted", bad)
			}
		}
	}
	for _, replacement := range []struct{ old, next string }{{`"Observer":7`, `"Observer":0`}, {`"Generation":"1970-01-01T00:02:03.000000456Z"`, `"Generation":"0001-01-01T00:00:00Z"`}} {
		if _, err = DecodeCustody(strings.Replace(string(raw), replacement.old, replacement.next, 1)); err == nil {
			t.Fatal("zero receipt identity accepted")
		}
	}
}

func TestReadbackIsDiagnosticAndRequiresCompleteIndependentPins(t *testing.T) {
	s, cfg, r := fixture()
	e := reserve(t, cfg)
	if err := e.RetainOriginal(t.Context(), r); err != nil {
		t.Fatal(err)
	}
	pins, ok := e.Pins()
	if !ok {
		t.Fatal("missing original ACKs")
	}
	got, err := Read(t.Context(), ReadConfig{Enabled: true, Storage: s, Pins: pins})
	if err != nil || got != pins {
		t.Fatal("complete pinned diagnostics unavailable", err)
	}
	for _, change := range []string{"enrollment version", "custody version", "receipt", "owner", "private permissions", "lost row", "partial read"} {
		t.Run(change, func(t *testing.T) {
			copy := pins
			storage := nakamastoragetest.New()
			for _, row := range s.Objects() {
				storage.Seed(row)
			}
			switch change {
			case "enrollment version":
				copy.EnrollmentVersion = "foreign"
			case "custody version":
				copy.CustodyVersion = "foreign"
			case "receipt":
				copy.Receipt.Fence.LeaseVersion = "new-version"
			case "owner":
				copy.Enrollment.OwnerID = "new-owner"
			case "private permissions":
				row, _ := storage.Get(CustodyCollection, LifetimeKey(cfg.Binding), "")
				row.PermissionRead = 1
				storage.Seed(row)
			case "lost row":
				storage = nakamastoragetest.New()
			case "partial read":
				storage.ReadErr = context.DeadlineExceeded
			}
			if _, err := Read(t.Context(), ReadConfig{Enabled: true, Storage: storage, Pins: copy}); err == nil {
				t.Fatal("changed or incomplete readback adopted")
			}
		})
	}
	if _, err := Read(t.Context(), ReadConfig{Storage: s, Pins: pins}); err == nil {
		t.Fatal("disabled reader accepted")
	}
}
