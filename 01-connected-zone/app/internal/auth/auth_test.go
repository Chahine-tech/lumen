package auth

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"encoding/pem"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
)

const (
	testIssuer   = "https://kubernetes.default.svc.cluster.local"
	testAudience = "lumen-api"
	testSubject  = "system:serviceaccount:lumen:lumen-smoke-test"
)

// testIssuerServer serves a JWKS and signs tokens with its keys.
type testIssuerServer struct {
	t      *testing.T
	srv    *httptest.Server
	keys   map[string]*rsa.PrivateKey // by kid
	public jose.JSONWebKeySet
	hits   atomic.Int32
	down   atomic.Bool
	// lastAuth is the Authorization header of the last JWKS request
	lastAuth atomic.Value
}

func newTestIssuer(t *testing.T) *testIssuerServer {
	t.Helper()
	ts := &testIssuerServer{t: t, keys: map[string]*rsa.PrivateKey{}}
	ts.addKey("k1")
	ts.srv = httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		ts.hits.Add(1)
		ts.lastAuth.Store(r.Header.Get("Authorization"))
		if ts.down.Load() {
			http.Error(w, "down", http.StatusServiceUnavailable)
			return
		}
		_ = json.NewEncoder(w).Encode(ts.public)
	}))
	t.Cleanup(ts.srv.Close)
	return ts
}

func (ts *testIssuerServer) addKey(kid string) {
	k, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		ts.t.Fatal(err)
	}
	ts.keys[kid] = k
	ts.public.Keys = append(ts.public.Keys, jose.JSONWebKey{Key: &k.PublicKey, KeyID: kid, Algorithm: "RS256", Use: "sig"})
}

// token signs claims (merged over valid defaults) with the key kid.
func (ts *testIssuerServer) token(kid string, override map[string]any) string {
	ts.t.Helper()
	return signRSA(ts.t, ts.keys[kid], kid, override)
}

func validClaims() map[string]any {
	now := time.Now()
	return map[string]any{
		"iss": testIssuer,
		"aud": []string{testAudience},
		"sub": testSubject,
		"iat": now.Unix(),
		"nbf": now.Unix(),
		"exp": now.Add(10 * time.Minute).Unix(),
	}
}

func signRSA(t *testing.T, key *rsa.PrivateKey, kid string, override map[string]any) string {
	t.Helper()
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.RS256, Key: key},
		(&jose.SignerOptions{}).WithType("JWT").WithHeader("kid", kid))
	if err != nil {
		t.Fatal(err)
	}
	return sign(t, signer, override)
}

func sign(t *testing.T, signer jose.Signer, override map[string]any) string {
	t.Helper()
	claims := validClaims()
	for k, v := range override {
		if v == nil {
			delete(claims, k)
		} else {
			claims[k] = v
		}
	}
	raw, err := jwt.Signed(signer).Claims(claims).Serialize()
	if err != nil {
		t.Fatal(err)
	}
	return raw
}

func (ts *testIssuerServer) config() *Config {
	return &Config{
		Audience: testAudience,
		Issuers:  []IssuerConfig{{Name: "kubernetes", Issuer: testIssuer, JWKSURL: ts.srv.URL, CallerClaim: "sub"}},
		Permissions: map[string][]string{
			OpItemsRead:   {AnyCaller},
			OpItemsCreate: {"kubernetes:" + testSubject},
		},
	}
}

func newTestAuthenticator(t *testing.T, cfg *Config, mode Mode) *Authenticator {
	t.Helper()
	if err := cfg.validate(); err != nil {
		t.Fatal(err)
	}
	a, err := New(cfg, mode, nil)
	if err != nil {
		t.Fatal(err)
	}
	return a
}

func withMinRefresh(t *testing.T, d time.Duration) {
	old := minRefresh
	minRefresh = d
	t.Cleanup(func() { minRefresh = old })
}

func TestVerify(t *testing.T) {
	ts := newTestIssuer(t)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	past := time.Now().Add(-time.Hour)

	cases := []struct {
		name  string
		token string
	}{
		{"wrong audience", ts.token("k1", map[string]any{"aud": []string{"vault"}})},
		{"expired", ts.token("k1", map[string]any{"exp": past.Unix(), "iat": past.Add(-time.Hour).Unix(), "nbf": nil})},
		{"no expiry", ts.token("k1", map[string]any{"exp": nil})},
		{"not yet valid", ts.token("k1", map[string]any{"nbf": time.Now().Add(time.Hour).Unix()})},
		{"unknown issuer", ts.token("k1", map[string]any{"iss": "https://elsewhere"})},
		{"signed by another key with the same kid", signRSA(t, other, "k1", nil)},
		{"unknown kid", signRSA(t, other, "k9", nil)},
		{"no caller claim", ts.token("k1", map[string]any{"sub": nil})},
		{"caller claim not a string", ts.token("k1", map[string]any{"sub": 42})},
		{"caller with a control character", ts.token("k1", map[string]any{"sub": "a\nb"})},
		{"caller too long", ts.token("k1", map[string]any{"sub": strings.Repeat("a", maxCallerLength+1)})},
		{"not a JWT", "abc"},
		{"unsigned", unsignedToken(t)},
		{"HMAC with the public key as secret", hmacToken(t, ts)},
	}

	// Control: the valid token passes
	caller, err := a.Verify(context.Background(), ts.token("k1", nil))
	if err != nil || caller != "kubernetes:"+testSubject {
		t.Fatalf("valid token: caller %q, err %v", caller, err)
	}
	for _, c := range cases {
		t.Run(c.name, func(t *testing.T) {
			caller, err := a.Verify(context.Background(), c.token)
			if !errors.Is(err, errInvalid) {
				t.Fatalf("caller %q, err %v; want errInvalid", caller, err)
			}
		})
	}
}

func unsignedToken(t *testing.T) string {
	enc := func(v any) string {
		b, _ := json.Marshal(v)
		return base64.RawURLEncoding.EncodeToString(b)
	}
	_ = t
	return enc(map[string]string{"alg": "none", "kid": "k1"}) + "." + enc(validClaims()) + "."
}

func hmacToken(t *testing.T, ts *testIssuerServer) string {
	t.Helper()
	pub, _ := json.Marshal(ts.public.Keys[0])
	signer, err := jose.NewSigner(jose.SigningKey{Algorithm: jose.HS256, Key: pub},
		(&jose.SignerOptions{}).WithHeader("kid", "k1"))
	if err != nil {
		t.Fatal(err)
	}
	return sign(t, signer, nil)
}

func TestVerifyES256(t *testing.T) {
	ts := newTestIssuer(t)
	ec, _ := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	ts.public.Keys = append(ts.public.Keys, jose.JSONWebKey{Key: &ec.PublicKey, KeyID: "e1", Algorithm: "ES256", Use: "sig"})
	a := newTestAuthenticator(t, ts.config(), Enforce)
	signer, _ := jose.NewSigner(jose.SigningKey{Algorithm: jose.ES256, Key: ec}, (&jose.SignerOptions{}).WithHeader("kid", "e1"))
	if _, err := a.Verify(context.Background(), sign(t, signer, nil)); err != nil {
		t.Fatal(err)
	}
}

func TestCallerClaim(t *testing.T) {
	ts := newTestIssuer(t)
	cfg := ts.config()
	cfg.Issuers[0].Name = "vault"
	cfg.Issuers[0].CallerClaim = "entity_name"
	a := newTestAuthenticator(t, cfg, Enforce)
	caller, err := a.Verify(context.Background(), ts.token("k1", map[string]any{"entity_name": "lumen-client"}))
	if err != nil || caller != "vault:lumen-client" {
		t.Fatalf("caller %q, err %v", caller, err)
	}
	// sub is not the caller claim of this issuer
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); !errors.Is(err, errInvalid) {
		t.Fatalf("err %v, want errInvalid", err)
	}
}

func TestKeyRotation(t *testing.T) {
	withMinRefresh(t, 0)
	ts := newTestIssuer(t)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); err != nil {
		t.Fatal(err)
	}
	ts.addKey("k2")
	if _, err := a.Verify(context.Background(), ts.token("k2", nil)); err != nil {
		t.Fatalf("key added after the first fetch: %v", err)
	}
	if got := ts.hits.Load(); got != 2 {
		t.Fatalf("%d fetches, want 2", got)
	}
}

func TestRefreshIsThrottled(t *testing.T) {
	withMinRefresh(t, time.Hour)
	ts := newTestIssuer(t)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	other, _ := rsa.GenerateKey(rand.Reader, 2048)
	for i := 0; i < 5; i++ {
		if _, err := a.Verify(context.Background(), signRSA(t, other, "forged", nil)); !errors.Is(err, errInvalid) {
			t.Fatalf("err %v, want errInvalid", err)
		}
	}
	// A known key still verifies without a fetch
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); err != nil {
		t.Fatal(err)
	}
	if got := ts.hits.Load(); got != 1 {
		t.Fatalf("%d fetches, want 1", got)
	}
}

func TestKeysUnavailable(t *testing.T) {
	withMinRefresh(t, 0)
	ts := newTestIssuer(t)
	ts.down.Store(true)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); !errors.Is(err, errKeysUnavailable) {
		t.Fatalf("err %v, want errKeysUnavailable", err)
	}
	ts.down.Store(false)
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); err != nil {
		t.Fatalf("after the issuer is back: %v", err)
	}
	// Once fetched, keys survive an outage of the issuer
	ts.down.Store(true)
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); err != nil {
		t.Fatalf("issuer down, key cached: %v", err)
	}
}

func TestFailedFetchIsThrottled(t *testing.T) {
	withMinRefresh(t, time.Hour)
	ts := newTestIssuer(t)
	ts.down.Store(true)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	for i := 0; i < 3; i++ {
		if _, err := a.Verify(context.Background(), ts.token("k1", nil)); !errors.Is(err, errKeysUnavailable) {
			t.Fatalf("err %v, want errKeysUnavailable", err)
		}
	}
	if got := ts.hits.Load(); got != 1 {
		t.Fatalf("%d fetches, want 1", got)
	}
}

func TestJWKSOverTLSWithToken(t *testing.T) {
	ts := newTestIssuer(t)
	tlsSrv := httptest.NewTLSServer(ts.srv.Config.Handler)
	t.Cleanup(tlsSrv.Close)
	dir := t.TempDir()
	caFile := filepath.Join(dir, "ca.crt")
	tokenFile := filepath.Join(dir, "token")
	ca := pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: tlsSrv.Certificate().Raw})
	if err := os.WriteFile(caFile, ca, 0o600); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(tokenFile, []byte("sa-token\n"), 0o600); err != nil {
		t.Fatal(err)
	}

	cfg := ts.config()
	cfg.Issuers[0].JWKSURL = tlsSrv.URL
	cfg.Issuers[0].CAFile = caFile
	cfg.Issuers[0].TokenFile = tokenFile
	a := newTestAuthenticator(t, cfg, Enforce)
	if _, err := a.Verify(context.Background(), ts.token("k1", nil)); err != nil {
		t.Fatal(err)
	}
	if got := ts.lastAuth.Load(); got != "Bearer sa-token" {
		t.Fatalf("JWKS request Authorization %q", got)
	}

	// Control: without the CA, the server certificate is refused
	cfg.Issuers[0].CAFile = ""
	b := newTestAuthenticator(t, cfg, Enforce)
	if _, err := b.Verify(context.Background(), ts.token("k1", nil)); !errors.Is(err, errKeysUnavailable) {
		t.Fatalf("err %v, want errKeysUnavailable", err)
	}
}

// serve runs h behind Authenticate and returns the status and the caller
// the handler saw.
func serve(a *Authenticator, h http.HandlerFunc, path, authz string) (*httptest.ResponseRecorder, string) {
	var seen string
	inner := http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		seen = Caller(r.Context())
		h(w, r)
	})
	req := httptest.NewRequest(http.MethodGet, path, nil)
	if authz != "" {
		req.Header.Set("Authorization", authz)
	}
	rec := httptest.NewRecorder()
	a.Authenticate("/livez", "/readyz")(inner).ServeHTTP(rec, req)
	return rec, seen
}

func ok(w http.ResponseWriter, _ *http.Request) { w.WriteHeader(http.StatusOK) }

func TestAuthenticateEnforce(t *testing.T) {
	withMinRefresh(t, 0)
	ts := newTestIssuer(t)
	var results []string
	cfg := ts.config()
	_ = cfg.validate()
	a, _ := New(cfg, Enforce, func(r string) { results = append(results, r) })

	rec, caller := serve(a, ok, "/items", "Bearer "+ts.token("k1", nil))
	if rec.Code != http.StatusOK || caller != "kubernetes:"+testSubject {
		t.Fatalf("valid token: %d, caller %q", rec.Code, caller)
	}
	rec, _ = serve(a, ok, "/items", "bearer "+ts.token("k1", nil))
	if rec.Code != http.StatusOK {
		t.Fatalf("lower case scheme: %d", rec.Code)
	}

	rec, _ = serve(a, ok, "/items", "")
	if rec.Code != http.StatusUnauthorized || rec.Header().Get("WWW-Authenticate") != `Bearer realm="lumen-api"` {
		t.Fatalf("no token: %d %q", rec.Code, rec.Header().Get("WWW-Authenticate"))
	}
	rec, _ = serve(a, ok, "/items", "Basic dXNlcjpwYXNz")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("basic auth: %d", rec.Code)
	}
	rec, _ = serve(a, ok, "/items", "Bearer "+ts.token("k1", map[string]any{"aud": []string{"other"}}))
	if rec.Code != http.StatusUnauthorized || !strings.Contains(rec.Header().Get("WWW-Authenticate"), "invalid_token") {
		t.Fatalf("invalid token: %d %q", rec.Code, rec.Header().Get("WWW-Authenticate"))
	}
	rec, _ = serve(a, ok, "/readyz", "")
	if rec.Code != http.StatusOK {
		t.Fatalf("exempt path: %d", rec.Code)
	}
	// Exempt by exact path only
	rec, _ = serve(a, ok, "/readyz/x", "")
	if rec.Code != http.StatusUnauthorized {
		t.Fatalf("/readyz/x: %d", rec.Code)
	}

	ts.down.Store(true)
	rec, _ = serve(a, ok, "/items", "Bearer "+ts.token("k1", map[string]any{}))
	if rec.Code != http.StatusOK {
		t.Fatalf("cached key, issuer down: %d", rec.Code)
	}
	ts.addKey("k2")
	rec, _ = serve(a, ok, "/items", "Bearer "+ts.token("k2", nil))
	if rec.Code != http.StatusServiceUnavailable || rec.Header().Get("Retry-After") == "" {
		t.Fatalf("new key, issuer down: %d", rec.Code)
	}

	want := []string{ResultOK, ResultOK, ResultMissing, ResultMissing, ResultInvalid, ResultMissing, ResultOK, ResultUnavailable}
	if strings.Join(results, ",") != strings.Join(want, ",") {
		t.Fatalf("results %v, want %v", results, want)
	}
}

func TestAuthenticateReport(t *testing.T) {
	ts := newTestIssuer(t)
	a := newTestAuthenticator(t, ts.config(), Report)
	rec, caller := serve(a, ok, "/items", "")
	if rec.Code != http.StatusOK || caller != "" {
		t.Fatalf("no token: %d, caller %q", rec.Code, caller)
	}
	rec, caller = serve(a, ok, "/items", "Bearer garbage")
	if rec.Code != http.StatusOK || caller != "" {
		t.Fatalf("invalid token: %d, caller %q", rec.Code, caller)
	}
	rec, caller = serve(a, ok, "/items", "Bearer "+ts.token("k1", nil))
	if rec.Code != http.StatusOK || caller != "kubernetes:"+testSubject {
		t.Fatalf("valid token: %d, caller %q", rec.Code, caller)
	}
}

func TestRequire(t *testing.T) {
	ts := newTestIssuer(t)
	smoke := "Bearer " + ts.token("k1", nil)
	someone := "Bearer " + ts.token("k1", map[string]any{"sub": "system:serviceaccount:lumen:other"})

	cases := []struct {
		mode  Mode
		op    string
		authz string
		want  int
	}{
		{Enforce, OpItemsCreate, smoke, http.StatusOK},          // listed
		{Enforce, OpItemsCreate, someone, http.StatusForbidden}, // not listed
		{Enforce, OpItemsRead, someone, http.StatusOK},          // "*"
		{Enforce, OpItemsDelete, smoke, http.StatusForbidden},   // operation not configured
		{Report, OpItemsDelete, smoke, http.StatusOK},           // served, logged
		{Report, OpItemsCreate, "", http.StatusOK},              // anonymous, served
		{Enforce, OpItemsRead, "", http.StatusUnauthorized},     // stopped by Authenticate
	}
	for _, c := range cases {
		a := newTestAuthenticator(t, ts.config(), c.mode)
		rec, _ := serve(a, a.Require(c.op, ok), "/items", c.authz)
		if rec.Code != c.want {
			t.Errorf("%s %s %q: %d, want %d", c.mode, c.op, c.authz[:min(len(c.authz), 12)], rec.Code, c.want)
		}
	}
}

func TestTrack(t *testing.T) {
	ts := newTestIssuer(t)
	a := newTestAuthenticator(t, ts.config(), Enforce)
	ctx, caller := Track(context.Background())
	req := httptest.NewRequest(http.MethodGet, "/items", nil).WithContext(ctx)
	req.Header.Set("Authorization", "Bearer "+ts.token("k1", nil))
	a.Authenticate()(http.HandlerFunc(ok)).ServeHTTP(httptest.NewRecorder(), req)
	if caller() != "kubernetes:"+testSubject {
		t.Fatalf("tracked caller %q", caller())
	}
}

func TestLoadConfig(t *testing.T) {
	dir := t.TempDir()
	write := func(s string) string {
		p := filepath.Join(dir, "auth.json")
		if err := os.WriteFile(p, []byte(s), 0o600); err != nil {
			t.Fatal(err)
		}
		return p
	}
	good := `{"audience":"lumen-api","issuers":[{"name":"kubernetes","issuer":"https://k","jwks_url":"https://k/jwks"}],
		"permissions":{"items:read":["*"]}}`
	c, err := LoadConfig(write(good))
	if err != nil || c.Issuers[0].CallerClaim != "sub" {
		t.Fatalf("good config: %v %+v", err, c)
	}
	bad := map[string]string{
		"unknown field":     `{"audience":"a","issuers":[{"name":"k","issuer":"i","jwks_url":"u"}],"permision":{}}`,
		"no audience":       `{"issuers":[{"name":"k","issuer":"i","jwks_url":"u"}]}`,
		"no issuer":         `{"audience":"a","issuers":[]}`,
		"no jwks_url":       `{"audience":"a","issuers":[{"name":"k","issuer":"i"}]}`,
		"name with colon":   `{"audience":"a","issuers":[{"name":"k:x","issuer":"i","jwks_url":"u"}]}`,
		"duplicate issuer":  `{"audience":"a","issuers":[{"name":"k","issuer":"i","jwks_url":"u"},{"name":"v","issuer":"i","jwks_url":"u"}]}`,
		"unknown operation": `{"audience":"a","issuers":[{"name":"k","issuer":"i","jwks_url":"u"}],"permissions":{"items:write":["*"]}}`,
	}
	for name, s := range bad {
		if _, err := LoadConfig(write(s)); err == nil {
			t.Errorf("%s: accepted", name)
		}
	}
}

func TestParseMode(t *testing.T) {
	for in, want := range map[string]Mode{"": Enforce, "enforce": Enforce, "report": Report} {
		if got, err := ParseMode(in); err != nil || got != want {
			t.Errorf("ParseMode(%q) = %q, %v", in, got, err)
		}
	}
	if _, err := ParseMode("off"); err == nil {
		t.Error("ParseMode(off) accepted")
	}
}
