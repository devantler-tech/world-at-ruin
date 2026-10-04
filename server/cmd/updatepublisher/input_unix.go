//go:build unix

package main

import (
	"errors"
	"os"
	"path/filepath"
	"syscall"
)

// Rooted open pins the directory; no-follow and nonblocking bind validation to
// the opened object without following a substituted symlink or hanging on a FIFO.
func openInput(path string) (*os.File, error) {
	root, err := os.OpenRoot(filepath.Dir(path))
	if err != nil {
		return nil, errors.New("input directory cannot be opened")
	}
	file, openErr := root.OpenFile(filepath.Base(path), os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	closeErr := root.Close()
	if closeErr != nil && file != nil {
		return nil, errors.Join(closeErr, file.Close())
	}
	return file, errors.Join(openErr, closeErr)
}
