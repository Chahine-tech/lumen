package handlers

import "time"

const (
	// maxItemNameLength bounds the item name, in characters.
	maxItemNameLength = 200

	// GET /items page size: default and maximum.
	defaultItemsLimit = 100
	maxItemsLimit     = 1000

	// dbTimeout bounds every store call. Below the server WriteTimeout (10s),
	// so a slow query still gets an error response.
	dbTimeout = 5 * time.Second
)
