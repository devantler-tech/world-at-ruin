//go:build !unix

package contentpack

import (
	"errors"
	"os"
)

// ReadRegular refuses platforms without the required descriptor policy.
func ReadRegular(_ *os.Root, _ string, _ int64) ([]byte, error) {
	return nil, errors.New("content pack tooling requires safe no-follow file support")
}
