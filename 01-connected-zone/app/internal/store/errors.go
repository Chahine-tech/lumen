package store

import "errors"

// ErrNotFound is returned when the requested row does not exist. Any other
// error from the store means the database could not answer.
var ErrNotFound = errors.New("not found")
