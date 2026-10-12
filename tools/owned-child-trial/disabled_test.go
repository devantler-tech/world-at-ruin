//go:build !war_child_trial

package ownedchild

// nativeEnabled leaves ordinary source tests independent of Linux processes.
func nativeEnabled() bool { return false }

// worker refuses a native helper when the explicit test build is absent.
func worker(string) int { return 2 }
