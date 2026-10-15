// Command trusted-runtime-footprint measures an existing image without retaining an archive.
package main

import (
	"bytes"
	"compress/gzip"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const maximumArchiveBytes = int64(2 * 1024 * 1024 * 1024)

type footprint struct {
	Schema       int    `json:"schema"`
	GoVersion    string `json:"go_version"`
	Image        string `json:"image_config_digest"`
	LogicalBytes int64  `json:"logical_layer_bytes"`
	ArchiveBytes int64  `json:"docker_archive_bytes"`
	GzipBytes    int64  `json:"gzip_archive_bytes"`
	Codec        string `json:"codec"`
	ElapsedMS    int64  `json:"elapsed_ms"`
}

var imageIdentity = regexp.MustCompile(`^sha256:[0-9a-f]{64}$`)

// measureRuntime publishes only a complete bounded export; it admits no executor.
func measureRuntime(ctx context.Context, mode, image string, inspect func(context.Context, string) ([]byte, error), export func(context.Context, string, io.Writer) error, output io.Writer) error {
	switch mode {
	case "", "0":
		return nil
	case "1":
	default:
		return errors.New("runtime footprint selection refused")
	}
	if ctx.Err() != nil || !imageIdentity.MatchString(image) {
		return errors.New("runtime footprint identity or lifetime refused")
	}
	started := time.Now()
	data, err := inspect(ctx, image)
	logical, parseErr := strconv.ParseInt(strings.TrimSpace(string(data)), 10, 64)
	if err != nil || len(data) > 64 || parseErr != nil || logical <= 0 || logical > maximumArchiveBytes || ctx.Err() != nil {
		return errors.New("runtime footprint inspection incomplete")
	}
	compressed := &boundedWriter{ctx: ctx, output: io.Discard, limit: maximumArchiveBytes}
	compressor, err := gzip.NewWriterLevel(compressed, gzip.BestSpeed)
	if err != nil {
		return errors.New("runtime footprint compressor unavailable")
	}
	archive := &boundedWriter{ctx: ctx, output: compressor, limit: maximumArchiveBytes}
	exportErr := export(ctx, image, archive)
	closeErr := compressor.Close()
	if exportErr != nil || closeErr != nil || archive.total <= 0 || ctx.Err() != nil {
		return errors.New("runtime footprint export incomplete")
	}
	report := footprint{Schema: 1, GoVersion: runtime.Version(), Image: image, LogicalBytes: logical, ArchiveBytes: archive.total, GzipBytes: compressed.total, Codec: "go-gzip-best-speed", ElapsedMS: time.Since(started).Milliseconds()}
	encoded, err := json.Marshal(report)
	if err != nil {
		return errors.New("runtime footprint encoding failed")
	}
	encoded = append(encoded, '\n')
	n, err := output.Write(encoded)
	if err != nil || n != len(encoded) {
		return errors.New("runtime footprint report incomplete")
	}
	return nil
}

type boundedWriter struct {
	ctx    context.Context
	output io.Writer
	limit  int64
	total  int64
}

// Write counts forwarded bytes and refuses overflow or canceled observations.
func (w *boundedWriter) Write(data []byte) (int, error) {
	if w.ctx.Err() != nil || int64(len(data)) > w.limit-w.total {
		return 0, errors.New("runtime footprint byte or lifetime bound reached")
	}
	n, err := w.output.Write(data)
	w.total += int64(n)
	if err == nil && n != len(data) {
		err = io.ErrShortWrite
	}
	return n, err
}

// dockerInspect requests only the numeric logical size, never image environment.
func dockerInspect(ctx context.Context, image string) ([]byte, error) {
	var data bytes.Buffer
	command := exec.CommandContext(ctx, "docker", "image", "inspect", "--format", "{{.Size}}", image)
	command.Stdout = &boundedWriter{ctx: ctx, output: &data, limit: 64}
	command.Stderr = io.Discard
	command.WaitDelay = time.Second
	err := command.Run()
	return data.Bytes(), err
}

// dockerExport streams the one already-built immutable image without storing it.
func dockerExport(ctx context.Context, image string, output io.Writer) error {
	command := exec.CommandContext(ctx, "docker", "image", "save", image)
	command.Stdout, command.Stderr = output, io.Discard
	command.WaitDelay = time.Second
	return command.Run()
}

// main keeps optional measurement inside the enclosing host inspection budget.
func main() {
	ctx, cancel := context.WithTimeout(context.Background(), 25*time.Second)
	defer cancel()
	image := ""
	if len(os.Args) == 2 {
		image = os.Args[1]
	}
	if err := measureRuntime(ctx, os.Getenv("WAR_TRUSTED_RUNTIME_FOOTPRINT"), image, dockerInspect, dockerExport, os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}
