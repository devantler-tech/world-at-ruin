package custodywitness

import (
	"encoding/json"
	"strconv"
	"strings"
	"testing"
)

// strictReaderCorruptions returns the shared refusal set for one shipped
// document: the empty, scalar, trailing-garbage, oversized and invalid-UTF-16
// forms, then each member corrupted on its own — nulled, repeated, followed by
// a foreign member, emptied or retyped to every value in retyped. Dropping a
// member is checked here, because the result must still be valid JSON for the
// refusal to prove anything. It also returns how many members the document
// holds, so a caller can pin the fixture's shape.
func strictReaderCorruptions(t *testing.T, document []byte, decode func(string) error, retyped ...string) ([]string, int) {
	t.Helper()
	original := string(document)
	bad := []string{"", "null", "[]", "7", "{}", original + "{}", original + " x", strings.Repeat(" ", maximumDocumentBytes) + original, strings.Replace(original, `"stage":"`, `"stage":"\ud800`, 1)}
	var fields map[string]json.RawMessage
	if err := json.Unmarshal(document, &fields); err != nil {
		t.Fatal(err)
	}
	for name, value := range fields {
		member := strconv.Quote(name) + ":" + string(value)
		if strings.Count(original, member) != 1 {
			t.Fatal("fixture member not exercised", name)
		}
		before, after, _ := strings.Cut(original, member)
		dropped := before + strings.TrimPrefix(after, ",")
		if trimmed, ok := strings.CutSuffix(before, ","); ok {
			dropped = trimmed + after
		}
		if err := decode(dropped); err == nil || !json.Valid([]byte(dropped)) {
			t.Fatal("dropping a member must leave valid JSON that is refused", name, dropped)
		}
		replacements := []string{strconv.Quote(name) + ":null", member + "," + member, member + `,"foreign":7`, strconv.Quote(name) + `:""`}
		for _, raw := range retyped {
			replacements = append(replacements, strconv.Quote(name)+":"+raw)
		}
		for _, replacement := range replacements {
			bad = append(bad, before+replacement+after)
		}
	}
	return bad, len(fields)
}
