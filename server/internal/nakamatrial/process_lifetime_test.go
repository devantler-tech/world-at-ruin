package nakamatrial

import (
	"errors"
	"os"
	"syscall"
	"time"
)

// stopOwnedProcess bounds termination and reaping of this fixture's exact child.
func stopOwnedProcess(process *os.Process, done <-chan struct{}, grace, killWait time.Duration) error {
	select {
	case <-done:
		return nil
	default:
	}
	// A stopped child cannot handle TERM until it is resumed.
	_ = process.Signal(syscall.SIGCONT)
	_ = process.Signal(syscall.SIGTERM)
	select {
	case <-done:
		return nil
	case <-time.After(grace):
	}
	_ = process.Kill()
	select {
	case <-done:
		return errors.New("owned child exceeded cooperative shutdown bound")
	case <-time.After(killWait):
		return errors.New("owned child was not joined after kill")
	}
}
