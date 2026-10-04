//go:build unix

package contentpack

import (
	"errors"
	"io"
	"os"
	"syscall"
)

// ReadRegular binds bounded input policy to an opened no-follow, nonblocking descriptor.
func ReadRegular(root *os.Root, name string, limit int64) ([]byte, error) {
	file, err := root.OpenFile(name, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
	if err != nil {
		return nil, errors.New("resource cannot be opened safely")
	}
	info, err := file.Stat()
	if err != nil || !info.Mode().IsRegular() || info.Size() > limit {
		return nil, errors.Join(errors.New("resource is nonregular or oversized"), file.Close())
	}
	raw, readErr := io.ReadAll(io.LimitReader(file, limit+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || int64(len(raw)) > limit {
		return nil, errors.New("resource cannot be read within its budget")
	}
	return raw, nil
}
