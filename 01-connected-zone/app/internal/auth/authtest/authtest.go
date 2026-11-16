// Package authtest runs a token issuer for tests: a JWKS server and tokens
// signed with its key.
package authtest

import (
	"crypto/rand"
	"crypto/rsa"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
	"time"

	"github.com/Chahine-tech/lumen/internal/auth"
	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

const (
	Issuer   = "https://issuer.test"
	Audience = "lumen-api"
	// Name prefixes the callers of this issuer: Caller("x") is "test:x".
	Name = "test"
)

type Server struct {
	t   *testing.T
	URL string
	key *rsa.PrivateKey
}

// New starts the JWKS server, stopped at the end of the test.
func New(t *testing.T) *Server {
	t.Helper()
	key, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	set := jose.JSONWebKeySet{Keys: []jose.JSONWebKey{{Key: &key.PublicKey, KeyID: "k1", Algorithm: "RS256", Use: "sig"}}}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		_ = json.NewEncoder(w).Encode(set)
	}))
	t.Cleanup(srv.Close)
	return &Server{t: t, URL: srv.URL, key: key}
}

// Config accepts this issuer's tokens, with the given permissions.
func (s *Server) Config(perms map[string][]string) *auth.Config {
	return &auth.Config{
		Audience:    Audience,
		Issuers:     []auth.IssuerConfig{{Name: Name, Issuer: Issuer, JWKSURL: s.URL, CallerClaim: "sub"}},
		Permissions: perms,
	}
}

// Token returns a valid token for subject sub.
func (s *Server) Token(sub string) string {
	s.t.Helper()
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: s.key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", "k1"))
	if err != nil {
		s.t.Fatal(err)
	}
	now := time.Now()
	raw, err := jwt.Signed(signer).Claims(jwt.Claims{
		Issuer:   Issuer,
		Subject:  sub,
		Audience: jwt.Audience{Audience},
		IssuedAt: jwt.NewNumericDate(now),
		Expiry:   jwt.NewNumericDate(now.Add(10 * time.Minute)),
	}).Serialize()
	if err != nil {
		s.t.Fatal(err)
	}
	return raw
}

// Caller is the caller a token of Token(sub) identifies.
func Caller(sub string) string { return Name + ":" + sub }
