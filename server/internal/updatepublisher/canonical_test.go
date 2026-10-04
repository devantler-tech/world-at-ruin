package updatepublisher

import (
	"encoding/json"
	"os"
	"strings"
	"testing"
)

func TestSharedClientCanonicalVectors(t *testing.T) {
	raw, err := os.ReadFile("../../../client/tests/data/jcs_vectors.json")
	if err != nil {
		t.Fatal(err)
	}
	var vectors struct {
		Vectors []struct {
			Name     string
			Input    json.RawMessage
			Expected string
		}
		Refusals []struct {
			Name  string
			Input json.RawMessage
		}
	}
	if err := json.Unmarshal(raw, &vectors); err != nil {
		t.Fatal(err)
	}
	for _, v := range vectors.Vectors {
		t.Run(v.Name, func(t *testing.T) {
			got, err := Canonicalize(v.Input)
			if err != nil || string(got) != v.Expected {
				t.Fatalf("canonical bytes: %q, %v; want %q", got, err, v.Expected)
			}
		})
	}
	for _, v := range vectors.Refusals {
		t.Run(v.Name, func(t *testing.T) {
			if _, err := Canonicalize(v.Input); err == nil {
				t.Fatal("out-of-domain signing input accepted")
			}
		})
	}
}

func TestAmbiguousSigningInputIsRefused(t *testing.T) {
	for _, raw := range []string{`{"x":1,"x":2}`, `{"a":{"x":1,"x":1}}`, `{"s":"\ud800"}`, `{"s":"\udc00"}`, `{"v":9007199254740993}`, `{} {}`, `{"x":1.1}`, strings.Repeat("[", 66) + "0" + strings.Repeat("]", 66), "{\"s\":\"\xff\"}"} {
		if _, err := Canonicalize([]byte(raw)); err == nil {
			t.Errorf("accepted ambiguous or unsupported input %q", raw)
		}
	}
	got, err := Canonicalize([]byte(`{"v":1e3,"zero":-0,"s":"\ud800\udc00"}`))
	if err != nil || string(got) != "{\"s\":\"𐀀\",\"v\":1000,\"zero\":0}" {
		t.Fatalf("exact integer and paired Unicode: %q %v", got, err)
	}
}
