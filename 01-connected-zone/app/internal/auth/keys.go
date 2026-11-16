package auth

import (
	"context"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"github.com/go-jose/go-jose/v4"
)

var (
	// errKeysUnavailable: the issuer's keys could not be fetched, so a
	// token signed by it cannot be checked either way (503, not 401).
	errKeysUnavailable = errors.New("signing keys unavailable")
	errUnknownKey      = errors.New("unknown signing key")
)

// minRefresh bounds how often a key set is fetched again, after a token
// with an unknown key id or after a failed fetch: a stream of forged key
// ids, or an issuer that is down, costs one request per interval.
var minRefresh = 30 * time.Second

const fetchTimeout = 5 * time.Second

// keySet caches the public keys of one issuer, fetched from its JWKS URL
// when a token names a key id it does not hold (key rotation).
type keySet struct {
	url       string
	tokenFile string
	client    *http.Client

	mu        sync.Mutex
	keys      jose.JSONWebKeySet
	lastFetch time.Time
	lastErr   error
}

func newKeySet(cfg IssuerConfig) (*keySet, error) {
	transport := http.DefaultTransport.(*http.Transport).Clone()
	if cfg.CAFile != "" {
		pem, err := os.ReadFile(cfg.CAFile)
		if err != nil {
			return nil, fmt.Errorf("issuer %q: %w", cfg.Name, err)
		}
		pool := x509.NewCertPool()
		if !pool.AppendCertsFromPEM(pem) {
			return nil, fmt.Errorf("issuer %q: no certificate in %s", cfg.Name, cfg.CAFile)
		}
		transport.TLSClientConfig = &tls.Config{RootCAs: pool, MinVersion: tls.VersionTLS12}
	}
	return &keySet{
		url:       cfg.JWKSURL,
		tokenFile: cfg.TokenFile,
		client:    &http.Client{Transport: transport, Timeout: fetchTimeout},
	}, nil
}

// key returns the signing key with this id, fetching the set again when it
// is not known yet.
func (k *keySet) key(ctx context.Context, kid string) (*jose.JSONWebKey, error) {
	k.mu.Lock()
	defer k.mu.Unlock()
	if key := k.find(kid); key != nil {
		return key, nil
	}
	if !k.lastFetch.IsZero() && time.Since(k.lastFetch) < minRefresh {
		if k.lastErr != nil {
			return nil, fmt.Errorf("%w: %v", errKeysUnavailable, k.lastErr)
		}
		return nil, errUnknownKey
	}
	k.lastFetch = time.Now()
	k.lastErr = k.fetch(ctx)
	if k.lastErr != nil {
		return nil, fmt.Errorf("%w: %v", errKeysUnavailable, k.lastErr)
	}
	if key := k.find(kid); key != nil {
		return key, nil
	}
	return nil, errUnknownKey
}

func (k *keySet) find(kid string) *jose.JSONWebKey {
	for _, key := range k.keys.Key(kid) {
		if key.Use == "" || key.Use == "sig" {
			return &key
		}
	}
	return nil
}

// fetch replaces the key set. On failure the previous keys are kept.
func (k *keySet) fetch(ctx context.Context) error {
	// Not the request context: a client that gives up must not leave the
	// set unfetched for minRefresh
	ctx, cancel := context.WithTimeout(context.WithoutCancel(ctx), fetchTimeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, k.url, nil)
	if err != nil {
		return err
	}
	if k.tokenFile != "" {
		token, err := os.ReadFile(k.tokenFile)
		if err != nil {
			return err
		}
		req.Header.Set("Authorization", "Bearer "+strings.TrimSpace(string(token)))
	}
	resp, err := k.client.Do(req)
	if err != nil {
		return err
	}
	defer func() { _ = resp.Body.Close() }()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("GET %s: status %d", k.url, resp.StatusCode)
	}
	var set jose.JSONWebKeySet
	if err := json.NewDecoder(io.LimitReader(resp.Body, 1<<20)).Decode(&set); err != nil {
		return fmt.Errorf("GET %s: %w", k.url, err)
	}
	k.keys = set
	return nil
}
