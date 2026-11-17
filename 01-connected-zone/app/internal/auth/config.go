package auth

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"slices"
	"strings"
)

// Mode says what happens to a request that is not authenticated or not
// allowed.
type Mode string

const (
	// Enforce rejects it: 401 without a valid token, 403 without the
	// permission.
	Enforce Mode = "enforce"
	// Report serves it and logs what enforce would have answered, so that
	// callers can move to tokens before enforce is switched on.
	Report Mode = "report"
)

// Operations checked by Require. A permission lists the callers allowed to
// run the operation; "*" allows any authenticated caller.
const (
	OpItemsRead   = "items:read"
	OpItemsCreate = "items:create"
	OpItemsDelete = "items:delete"
	OpEventsRead  = "events:read"
)

var operations = []string{OpItemsRead, OpItemsCreate, OpItemsDelete, OpEventsRead}

// AnyCaller in a permission allows every authenticated caller.
const AnyCaller = "*"

// Config is the JSON file named by AUTH_CONFIG.
type Config struct {
	// Audience the tokens must carry in "aud".
	Audience string `json:"audience"`
	// Issuers whose tokens are accepted.
	Issuers []IssuerConfig `json:"issuers"`
	// Permissions maps an operation to the callers allowed to run it. An
	// operation that is not listed is allowed to nobody.
	Permissions map[string][]string `json:"permissions"`
}

// IssuerConfig is one token issuer.
type IssuerConfig struct {
	// Name prefixes the caller identity: <name>:<caller claim>.
	Name string `json:"name"`
	// Issuer must match the "iss" claim exactly.
	Issuer string `json:"issuer"`
	// JWKSURL serves the issuer's public keys.
	JWKSURL string `json:"jwks_url"`
	// CAFile verifies the JWKS server instead of the system roots (the
	// Kubernetes API server).
	CAFile string `json:"ca_file,omitempty"`
	// TokenFile holds a bearer token sent with the JWKS request, read at
	// each fetch (a projected ServiceAccount token, which is rotated).
	TokenFile string `json:"token_file,omitempty"`
	// CallerClaim names the claim that identifies the caller. Default "sub".
	CallerClaim string `json:"caller_claim,omitempty"`
}

// LoadConfig reads and checks the configuration file.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c Config
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	if err := c.validate(); err != nil {
		return nil, fmt.Errorf("%s: %w", path, err)
	}
	return &c, nil
}

func (c *Config) validate() error {
	if c.Audience == "" {
		return fmt.Errorf("audience is required")
	}
	if len(c.Issuers) == 0 {
		return fmt.Errorf("at least one issuer is required")
	}
	names := map[string]bool{}
	issuers := map[string]bool{}
	for i := range c.Issuers {
		is := &c.Issuers[i]
		if is.Name == "" || strings.Contains(is.Name, ":") {
			return fmt.Errorf("issuer %d: name is required and must not contain ':'", i)
		}
		if is.Issuer == "" || is.JWKSURL == "" {
			return fmt.Errorf("issuer %q: issuer and jwks_url are required", is.Name)
		}
		if names[is.Name] || issuers[is.Issuer] {
			return fmt.Errorf("issuer %q: name or issuer listed twice", is.Name)
		}
		names[is.Name], issuers[is.Issuer] = true, true
		if is.CallerClaim == "" {
			is.CallerClaim = "sub"
		}
	}
	for op := range c.Permissions {
		if !slices.Contains(operations, op) {
			return fmt.Errorf("permissions: unknown operation %q (known: %s)", op, strings.Join(operations, ", "))
		}
	}
	return nil
}

// ParseMode reads AUTH_MODE. Empty means Enforce.
func ParseMode(s string) (Mode, error) {
	switch Mode(s) {
	case "", Enforce:
		return Enforce, nil
	case Report:
		return Report, nil
	}
	return "", fmt.Errorf("AUTH_MODE must be %q or %q, got %q", Enforce, Report, s)
}
