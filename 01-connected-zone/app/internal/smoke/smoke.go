// Package smoke checks a deployed lumen-api through its public API: the
// dependency report, optionally that a request without a token is refused,
// then an item created with an Idempotency-Key, the request replayed, the
// item read and deleted. Run by `lumen-api smoke`.
package smoke

import (
	"bytes"
	"context"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"strings"
	"time"
)

// replicaLagTimeout bounds the wait for a deleted item to disappear: reads
// go to a replica, which may still return it for a moment.
var replicaLagTimeout = 10 * time.Second

// healthTimeout bounds the wait for /health to answer 200. A new pod cannot
// reach the API for its first seconds, until kube-router has programmed its
// NetworkPolicies (measured on k3d: connection refused at once, success
// after 10s).
var healthTimeout = 30 * time.Second

// Options of Run.
type Options struct {
	// Token is sent as a bearer token with every request but the
	// unauthenticated check (issue #18).
	Token string
	// ExpectAuth checks that GET /items without a token gets 401: the API
	// enforces authentication (AUTH_MODE=enforce).
	ExpectAuth bool
}

// Run runs the checks against baseURL (e.g. http://lumen-api:8080) and
// returns the first failure. The item it creates is deleted even when a
// later check fails.
func Run(ctx context.Context, client *http.Client, baseURL string, opts Options) error {
	c := checker{client: client, base: strings.TrimRight(baseURL, "/"), token: opts.Token}

	deadline := time.Now().Add(healthTimeout)
	for {
		status, _, body, err := c.do(ctx, http.MethodGet, "/health", nil, nil)
		if err == nil && status == http.StatusOK {
			break
		}
		// Not a pod that is starting: the token is missing or refused
		if err == nil && (status == http.StatusUnauthorized || status == http.StatusForbidden) {
			return fmt.Errorf("health: status %d: %s", status, body)
		}
		if time.Now().After(deadline) {
			if err != nil {
				return fmt.Errorf("health: %w", err)
			}
			return fmt.Errorf("health: status %d, want 200 within %s: %s", status, healthTimeout, body)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("health: %w", ctx.Err())
		case <-time.After(time.Second):
		}
	}
	slog.Info("Smoke: health ok")

	if opts.ExpectAuth {
		anonymous := checker{client: client, base: c.base}
		status, _, body, err := anonymous.do(ctx, http.MethodGet, "/items", nil, nil)
		if err != nil {
			return fmt.Errorf("auth: %w", err)
		}
		if status != http.StatusUnauthorized {
			return fmt.Errorf("auth: GET /items without a token: status %d, want 401: %s", status, body)
		}
		slog.Info("Smoke: request without a token refused")
	}

	key := "smoke-" + rand.Text()
	payload, _ := json.Marshal(map[string]string{"name": key})
	hdr := http.Header{"Idempotency-Key": {key}, "Content-Type": {"application/json"}}

	status, _, created, err := c.do(ctx, http.MethodPost, "/items", payload, hdr)
	if err != nil {
		return fmt.Errorf("create: %w", err)
	}
	if status != http.StatusCreated {
		return fmt.Errorf("create: status %d, want 201: %s", status, created)
	}
	var item struct {
		ID   int    `json:"id"`
		Name string `json:"name"`
	}
	if err := json.Unmarshal(created, &item); err != nil || item.ID == 0 || item.Name != key {
		return fmt.Errorf("create: unexpected body: %s", created)
	}
	path := "/items/" + strconv.Itoa(item.ID)
	slog.Info("Smoke: item created", "id", item.ID)

	deleted := false
	defer func() {
		if deleted {
			return
		}
		// Not ctx: it may be the one that expired
		cleanup, cancel := context.WithTimeout(context.WithoutCancel(ctx), 5*time.Second)
		defer cancel()
		if _, _, _, derr := c.do(cleanup, http.MethodDelete, path, nil, nil); derr != nil {
			slog.Warn("Smoke: test item not deleted", "id", item.ID, "error", derr)
		}
	}()

	status, respHdr, replayed, err := c.do(ctx, http.MethodPost, "/items", payload, hdr)
	if err != nil {
		return fmt.Errorf("replay: %w", err)
	}
	if status != http.StatusCreated || respHdr.Get("Idempotency-Replayed") != "true" || !bytes.Equal(replayed, created) {
		return fmt.Errorf("replay: status %d, Idempotency-Replayed %q, body %s; want 201, \"true\" and the first response %s",
			status, respHdr.Get("Idempotency-Replayed"), replayed, created)
	}
	slog.Info("Smoke: replay returned the stored response")

	status, _, body, err := c.do(ctx, http.MethodGet, path, nil, nil)
	if err != nil {
		return fmt.Errorf("read: %w", err)
	}
	if status != http.StatusOK || !bytes.Contains(body, []byte(key)) {
		return fmt.Errorf("read: status %d, body %s; want 200 and the item", status, body)
	}
	slog.Info("Smoke: item read")

	status, _, body, err = c.do(ctx, http.MethodDelete, path, nil, nil)
	if err != nil {
		return fmt.Errorf("delete: %w", err)
	}
	if status != http.StatusNoContent {
		return fmt.Errorf("delete: status %d, want 204: %s", status, body)
	}
	deleted = true

	deadline = time.Now().Add(replicaLagTimeout)
	for {
		status, _, body, err = c.do(ctx, http.MethodGet, path, nil, nil)
		if err != nil {
			return fmt.Errorf("read after delete: %w", err)
		}
		if status == http.StatusNotFound {
			break
		}
		if status != http.StatusOK || time.Now().After(deadline) {
			return fmt.Errorf("read after delete: status %d, want 404 within %s: %s", status, replicaLagTimeout, body)
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("read after delete: %w", ctx.Err())
		case <-time.After(500 * time.Millisecond):
		}
	}
	slog.Info("Smoke: item deleted")
	return nil
}

type checker struct {
	client *http.Client
	base   string
	token  string
}

func (c checker) do(ctx context.Context, method, path string, body []byte, hdr http.Header) (int, http.Header, []byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, c.base+path, bytes.NewReader(body))
	if err != nil {
		return 0, nil, nil, err
	}
	for k, v := range hdr {
		req.Header[k] = v
	}
	if c.token != "" {
		req.Header.Set("Authorization", "Bearer "+c.token)
	}
	resp, err := c.client.Do(req)
	if err != nil {
		return 0, nil, nil, err
	}
	defer func() { _ = resp.Body.Close() }()
	b, err := io.ReadAll(io.LimitReader(resp.Body, 64<<10))
	return resp.StatusCode, resp.Header, bytes.TrimSpace(b), err
}
