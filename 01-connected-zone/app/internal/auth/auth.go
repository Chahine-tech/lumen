// Package auth identifies the caller of a request from a bearer JWT and
// checks its permissions (issue #18).
//
// Tokens come from the issuers of the configuration: in the cluster,
// projected ServiceAccount tokens (Kubernetes API server keys); outside,
// Vault identity tokens. A token is accepted when its signature verifies
// with a key of its issuer, it carries the configured audience and it has
// not expired. The caller is "<issuer name>:<caller claim>", for example
// kubernetes:system:serviceaccount:lumen:lumen-smoke-test.
package auth

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"log/slog"
	"net/http"
	"slices"
	"strings"
	"time"
	"unicode"

	"github.com/go-jose/go-jose/v4"
	"github.com/go-jose/go-jose/v4/jwt"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/trace"
)

// Anonymous is recorded as the actor of a request served without a caller
// (Report mode). A caller always contains ':', so it cannot be confused.
const Anonymous = "anonymous"

// leeway allows for clock skew between the issuer and this pod.
const leeway = 30 * time.Second

// maxCallerLength bounds the caller claim, which goes to logs, spans,
// Redis keys and the events table.
const maxCallerLength = 256

var signingAlgs = []jose.SignatureAlgorithm{jose.RS256, jose.ES256}

// Results of authentication and authorization, for the metrics.
const (
	ResultOK          = "ok"
	ResultMissing     = "missing"
	ResultInvalid     = "invalid"
	ResultUnavailable = "unavailable"
	ResultForbidden   = "forbidden"
)

var (
	errNoToken = errors.New("no bearer token")
	errInvalid = errors.New("invalid token")
)

type issuer struct {
	cfg  IssuerConfig
	keys *keySet
}

// Authenticator checks tokens and permissions.
type Authenticator struct {
	mode     Mode
	audience string
	issuers  map[string]*issuer // by "iss"
	perms    map[string][]string
	// observe counts each result (metrics); may be nil
	observe func(result string)
	now     func() time.Time
}

// New builds an Authenticator. observe, when not nil, is called once per
// authenticated request and once per permission check with a Result*.
func New(cfg *Config, mode Mode, observe func(result string)) (*Authenticator, error) {
	a := &Authenticator{
		mode:     mode,
		audience: cfg.Audience,
		issuers:  map[string]*issuer{},
		perms:    cfg.Permissions,
		observe:  observe,
		now:      time.Now,
	}
	for _, ic := range cfg.Issuers {
		ks, err := newKeySet(ic)
		if err != nil {
			return nil, err
		}
		a.issuers[ic.Issuer] = &issuer{cfg: ic, keys: ks}
	}
	return a, nil
}

// Verify returns the caller a token identifies. The error wraps errInvalid
// for a token that is not acceptable, errKeysUnavailable when the keys of
// its issuer could not be fetched.
func (a *Authenticator) Verify(ctx context.Context, raw string) (string, error) {
	tok, err := jwt.ParseSigned(raw, signingAlgs)
	if err != nil {
		return "", fmt.Errorf("%w: %v", errInvalid, err)
	}
	// Read before verification only to pick the issuer: Claims below
	// checks the signature with that issuer's keys, and the issuer again.
	var unverified jwt.Claims
	if err := tok.UnsafeClaimsWithoutVerification(&unverified); err != nil {
		return "", fmt.Errorf("%w: %v", errInvalid, err)
	}
	is, ok := a.issuers[unverified.Issuer]
	if !ok {
		return "", fmt.Errorf("%w: unknown issuer", errInvalid)
	}
	if len(tok.Headers) != 1 || tok.Headers[0].KeyID == "" {
		return "", fmt.Errorf("%w: no key id", errInvalid)
	}
	key, err := is.keys.key(ctx, tok.Headers[0].KeyID)
	if errors.Is(err, errUnknownKey) {
		return "", fmt.Errorf("%w: %v", errInvalid, err)
	}
	if err != nil {
		return "", err
	}

	var claims jwt.Claims
	var extra map[string]any
	if err := tok.Claims(key, &claims, &extra); err != nil {
		return "", fmt.Errorf("%w: %v", errInvalid, err)
	}
	// ValidateWithLeeway skips a missing exp: a token without one (a legacy
	// ServiceAccount token Secret) would never expire
	if claims.Expiry == nil {
		return "", fmt.Errorf("%w: no expiry", errInvalid)
	}
	expected := jwt.Expected{Issuer: is.cfg.Issuer, AnyAudience: jwt.Audience{a.audience}, Time: a.now()}
	if err := claims.ValidateWithLeeway(expected, leeway); err != nil {
		return "", fmt.Errorf("%w: %v", errInvalid, err)
	}

	id, _ := extra[is.cfg.CallerClaim].(string)
	if id == "" || len(id) > maxCallerLength || strings.IndexFunc(id, unicode.IsControl) >= 0 {
		return "", fmt.Errorf("%w: claim %q missing or not a valid caller", errInvalid, is.cfg.CallerClaim)
	}
	return is.cfg.Name + ":" + id, nil
}

// Authenticate returns a middleware that identifies the caller of every
// request, except on the exempt paths (the kubelet probes, which cannot
// send a token). In Enforce mode, a request without a valid token gets 401,
// and 503 when the issuer's keys cannot be fetched. In Report mode it is
// served without a caller.
func (a *Authenticator) Authenticate(exempt ...string) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if slices.Contains(exempt, r.URL.Path) {
				next.ServeHTTP(w, r)
				return
			}
			var id string
			err := errNoToken
			if raw, ok := bearer(r); ok {
				id, err = a.Verify(r.Context(), raw)
			}
			if err == nil {
				a.count(ResultOK)
				ctx := withCaller(r.Context(), id)
				trace.SpanFromContext(ctx).SetAttributes(attribute.String("lumen.caller", id))
				next.ServeHTTP(w, r.WithContext(ctx))
				return
			}

			result := ResultInvalid
			switch {
			case errors.Is(err, errNoToken):
				result = ResultMissing
			case errors.Is(err, errKeysUnavailable):
				result = ResultUnavailable
			}
			a.count(result)
			if a.mode == Report {
				slog.Warn("Auth: request served without a caller (report mode)",
					"result", result, "error", err, "method", r.Method, "path", r.URL.Path)
				next.ServeHTTP(w, r)
				return
			}
			if result == ResultUnavailable {
				slog.Error("Auth: issuer keys unavailable", "error", err)
				w.Header().Set("Retry-After", "5")
				writeError(w, http.StatusServiceUnavailable, "token could not be verified, retry later")
				return
			}
			// RFC 6750: no error attribute when the request had no token
			if result == ResultMissing {
				w.Header().Set("WWW-Authenticate", `Bearer realm="lumen-api"`)
			} else {
				slog.Info("Auth: token rejected", "error", err, "method", r.Method, "path", r.URL.Path)
				w.Header().Set("WWW-Authenticate", `Bearer realm="lumen-api", error="invalid_token"`)
			}
			writeError(w, http.StatusUnauthorized, "a valid bearer token is required")
		})
	}
}

// Require wraps a handler with a permission check for op. In Enforce mode a
// caller without the permission gets 403. In Report mode the request is
// served and the refusal logged.
func (a *Authenticator) Require(op string, next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		caller := Caller(r.Context())
		if a.allowed(op, caller) {
			next(w, r)
			return
		}
		a.count(ResultForbidden)
		if a.mode == Report {
			slog.Warn("Auth: operation served without the permission (report mode)",
				"operation", op, "caller", caller, "method", r.Method, "path", r.URL.Path)
			next(w, r)
			return
		}
		if caller == "" {
			// Only reachable when a route is not behind Authenticate
			w.Header().Set("WWW-Authenticate", `Bearer realm="lumen-api"`)
			writeError(w, http.StatusUnauthorized, "a valid bearer token is required")
			return
		}
		slog.Info("Auth: operation denied", "operation", op, "caller", caller)
		writeError(w, http.StatusForbidden, "caller is not allowed to "+op)
	}
}

func (a *Authenticator) allowed(op, caller string) bool {
	if caller == "" {
		return false
	}
	allowed := a.perms[op]
	return slices.Contains(allowed, caller) || slices.Contains(allowed, AnyCaller)
}

func (a *Authenticator) count(result string) {
	if a.observe != nil {
		a.observe(result)
	}
}

// bearer returns the token of an "Authorization: Bearer <token>" header.
func bearer(r *http.Request) (string, bool) {
	scheme, token, ok := strings.Cut(r.Header.Get("Authorization"), " ")
	if !ok || !strings.EqualFold(scheme, "Bearer") {
		return "", false
	}
	token = strings.TrimSpace(token)
	return token, token != ""
}

func writeError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]string{"error": msg})
}

type callerKey struct{}

// callerHolder lets a middleware outside Authenticate (Logging) read the
// caller once the request is served.
type callerHolder struct{ caller string }

// Track returns a context in which Authenticate records the caller, and a
// function that returns it ("" when there is none) after the request.
func Track(ctx context.Context) (context.Context, func() string) {
	h := &callerHolder{}
	return context.WithValue(ctx, callerKey{}, h), func() string { return h.caller }
}

func withCaller(ctx context.Context, caller string) context.Context {
	if h, ok := ctx.Value(callerKey{}).(*callerHolder); ok {
		h.caller = caller
		return ctx
	}
	return context.WithValue(ctx, callerKey{}, &callerHolder{caller: caller})
}

// Caller returns the authenticated caller of the request, "" when there is
// none.
func Caller(ctx context.Context) string {
	if h, ok := ctx.Value(callerKey{}).(*callerHolder); ok {
		return h.caller
	}
	return ""
}
