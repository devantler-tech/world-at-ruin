//go:build unix

package main

import (
	"os"
	"path/filepath"
	"syscall"
	"testing"
)

func TestInputsRejectLinksPipesAndPublicPrivateKeys(t *testing.T) {
	dir := t.TempDir()
	key := filepath.Join(dir, "key")
	if err := os.WriteFile(key, []byte("private"), 0600); err != nil {
		t.Fatal(err)
	}
	root, err := os.OpenRoot(dir)
	if err != nil {
		t.Fatal(err)
	}
	if err := root.Chmod("key", 0644); err != nil {
		t.Fatal(err)
	}
	if err := root.Close(); err != nil {
		t.Fatal(err)
	}
	if _, err := readFile(key, true); err == nil {
		t.Fatal("publicly readable private input accepted")
	}
	link := filepath.Join(dir, "link")
	if err := os.Symlink(key, link); err != nil {
		t.Fatal(err)
	}
	if _, err := readFile(link, false); err == nil {
		t.Fatal("input symlink followed")
	}
	pipe := filepath.Join(dir, "pipe")
	if err := syscall.Mkfifo(pipe, 0600); err != nil {
		t.Fatal(err)
	}
	if _, err := readFile(pipe, false); err == nil {
		t.Fatal("FIFO accepted")
	}
}
