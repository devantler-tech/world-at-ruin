package nakamatrial

// nativeRetirementComplete joins resource absence with durable retirement.
func nativeRetirementComplete(resourceGone bool, leaseCount func() (int, error)) (bool, error) {
	if !resourceGone {
		return false, nil
	}
	count, err := leaseCount()
	if err != nil {
		return false, err
	}
	return count == 0, nil
}
