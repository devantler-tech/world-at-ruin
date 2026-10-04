//go:build !unix

package main

import (
	"errors"
	"os"
)

func openInput(_ string) (*os.File, error) {
	return nil, errors.New("offline publication requires a platform with safe no-follow input support")
}
