package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

const imageFixture = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"

// A complete export reports transfer bytes separately from logical layer size.
func TestCompleteFootprintAndExplicitSelection(t *testing.T) {
	for _, mode := range []string{"", "0", "1", "unknown"} {
		t.Run("selection-"+mode, func(t *testing.T) {
			calls := 0
			inspect := func(context.Context, string) ([]byte, error) { calls++; return []byte("999\n"), nil }
			payload := strings.Repeat("owned export bytes", 100)
			export := func(_ context.Context, image string, output io.Writer) error {
				calls++
				if image != imageFixture {
					t.Fatal("unexpected image selection")
				}
				_, err := io.WriteString(output, payload)
				return err
			}
			var output bytes.Buffer
			err := measureRuntime(context.Background(), mode, imageFixture, inspect, export, &output)
			if mode == "unknown" {
				if err == nil || calls != 0 || output.Len() != 0 {
					t.Fatal("unknown selection performed effects")
				}
				return
			}
			if mode != "1" {
				if err != nil || calls != 0 || output.Len() != 0 {
					t.Fatal("disabled measurement was not inert")
				}
				return
			}
			var got footprint
			if err != nil || calls != 2 || json.Unmarshal(output.Bytes(), &got) != nil {
				t.Fatal("complete export did not produce one report")
			}
			var compressed bytes.Buffer
			gzipWriter, err := gzip.NewWriterLevel(&compressed, gzip.BestSpeed)
			if err != nil {
				t.Fatal(err)
			}
			if _, err = io.WriteString(gzipWriter, payload); err != nil || gzipWriter.Close() != nil {
				t.Fatal("independent compression failed")
			}
			if got.Image != imageFixture || got.LogicalBytes != 999 || got.ArchiveBytes != int64(len(payload)) || got.GzipBytes != int64(compressed.Len()) || got.Codec != "go-gzip-best-speed" {
				t.Fatalf("incorrect complete footprint: %+v", got)
			}
		})
	}
}

// Plausible partial data followed by failure cannot become a successful metric.
func TestIncompleteFootprintsNeverPublish(t *testing.T) {
	for _, name := range []string{"image", "inspect-error", "inspect-malformed", "inspect-large", "inspect-limit", "export-error", "export-empty", "export-canceled", "canceled"} {
		t.Run(name, func(t *testing.T) {
			ctx, cancel := context.WithCancel(t.Context())
			defer cancel()
			image := imageFixture
			if name == "image" {
				image = "mutable:tag"
			}
			if name == "canceled" {
				cancel()
			}
			inspect := func(context.Context, string) ([]byte, error) {
				switch name {
				case "inspect-error":
					return []byte("999"), errors.New("private inspection failure")
				case "inspect-malformed":
					return []byte("999\n1"), nil
				case "inspect-large":
					return []byte(strings.Repeat("1", 65)), nil
				case "inspect-limit":
					return []byte("2147483649"), nil
				}
				return []byte("999"), nil
			}
			export := func(_ context.Context, _ string, output io.Writer) error {
				if name == "export-empty" {
					return nil
				}
				if name == "export-canceled" {
					cancel()
				}
				if _, err := io.WriteString(output, "partial export"); err != nil {
					return err
				}
				return errors.New("private export failure")
			}
			var output bytes.Buffer
			err := measureRuntime(ctx, "1", image, inspect, export, &output)
			if err == nil || output.Len() != 0 || strings.Contains(err.Error(), "private") {
				t.Fatal("incomplete observation published data or private error")
			}
		})
	}
}

// The byte cap refuses the whole overflowing write before forwarding it.
func TestArchiveByteLimit(t *testing.T) {
	var output bytes.Buffer
	writer := &boundedWriter{ctx: t.Context(), output: &output, limit: 16}
	if n, err := io.WriteString(writer, "12345678"); err != nil || n != 8 {
		t.Fatal("bounded positive failed")
	}
	if n, err := io.WriteString(writer, "123456789"); err == nil || n != 0 || writer.total != 8 || output.String() != "12345678" {
		t.Fatal("archive byte cap failed")
	}
}

// Real subprocess adapters reject valid-looking output when the producer fails.
func TestDockerAdaptersPreserveFailureAndCancellation(t *testing.T) {
	directory := t.TempDir()
	script := `#!/bin/sh
case "$1:$2" in
  image:inspect)
    test "$#" = 5 && test "$3" = --format && test "$4" = '{{.Size}}' || exit 9
    if test "$FOOTPRINT_FIXTURE" = inspect-overflow; then printf '%065d\n' 1; exit 0; fi
    printf '999\n'
    if test "$FOOTPRINT_FIXTURE" = inspect-failure; then printf 'private-sentinel' >&2; exit 7; fi
    ;;
  image:save)
    test "$#" = 3 || exit 9
    printf 'owned export'
    case "$FOOTPRINT_FIXTURE" in
      export-failure) printf 'private-sentinel' >&2; exit 8 ;;
      cancellation|writer-failure) exec /bin/sleep 60 ;;
    esac
    ;;
  *) exit 9 ;;
esac
`
	if err := os.WriteFile(filepath.Join(directory, "docker"), []byte(script), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", directory+string(os.PathListSeparator)+os.Getenv("PATH"))
	for _, mode := range []string{"complete", "inspect-failure", "inspect-overflow", "export-failure", "cancellation", "writer-failure"} {
		t.Run(mode, func(t *testing.T) {
			t.Setenv("FOOTPRINT_FIXTURE", mode)
			ctx, cancel := context.WithTimeout(t.Context(), 5*time.Second)
			defer cancel()
			var output bytes.Buffer
			rejected := &rejectingWriter{}
			started := time.Now()
			export := dockerExport
			if mode == "cancellation" {
				export = func(ctx context.Context, image string, output io.Writer) error {
					return dockerExport(ctx, image, &cancelingWriter{output: output, cancel: cancel})
				}
			}
			if mode == "writer-failure" {
				cancel()
				ctx, cancel = context.WithTimeout(t.Context(), time.Second)
				defer cancel()
				export = func(ctx context.Context, image string, _ io.Writer) error { return dockerExport(ctx, image, rejected) }
			}
			err := measureRuntime(ctx, "1", imageFixture, dockerInspect, export, &output)
			if mode == "complete" {
				var got footprint
				if err != nil || json.Unmarshal(output.Bytes(), &got) != nil || got.ArchiveBytes != 12 {
					t.Fatal("actual subprocess positive failed")
				}
			} else if err == nil || output.Len() != 0 || strings.Contains(err.Error(), "private-sentinel") {
				t.Fatal("failed subprocess became a public metric")
			}
			if mode == "writer-failure" && !rejected.called {
				t.Fatal("the live producer did not reach the rejecting writer")
			}
			if (mode == "cancellation" || mode == "writer-failure") && time.Since(started) > 3*time.Second {
				t.Fatal("subprocess cancellation did not join promptly")
			}
		})
	}
}

type rejectingWriter struct{ called bool }

// Write refuses output while the fixture's producer remains alive.
func (w *rejectingWriter) Write([]byte) (int, error) {
	w.called = true
	return 0, errors.New("private writer failure")
}

type cancelingWriter struct {
	output io.Writer
	cancel context.CancelFunc
}

// Write cancels only after a real producer has emitted a partial stream.
func (w *cancelingWriter) Write(data []byte) (int, error) {
	n, err := w.output.Write(data)
	w.cancel()
	return n, err
}
