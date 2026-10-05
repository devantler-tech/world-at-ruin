package groundgoldens

import (
	"bytes"
	"os"
	"testing"
)

func TestCommittedCorpusIsReproducible(t *testing.T) {
	want, err := Bytes()
	if err != nil {
		t.Fatal(err)
	}
	got, err := os.ReadFile("../../../client/tests/data/ground_step_goldens.json")
	if err != nil {
		t.Fatal(err)
	}
	if !bytes.Equal(got, want) {
		t.Fatal("ground-step corpus differs; regenerate with go -C server run ./cmd/groundgoldens")
	}
}
