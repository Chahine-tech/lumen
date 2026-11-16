package app

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Chahine-tech/lumen/internal/auth"
	"github.com/Chahine-tech/lumen/internal/auth/authtest"
	"github.com/Chahine-tech/lumen/internal/handlers"
)

// Each API route checks the permission of its own operation: only the
// caller granted that operation gets past the check. Without PostgreSQL the
// handlers answer 503, which tells "allowed" from 403.
func TestRoutePermissions(t *testing.T) {
	iss := authtest.New(t)
	perms := map[string][]string{
		auth.OpItemsRead:   {authtest.Caller("reader")},
		auth.OpItemsCreate: {authtest.Caller("creator")},
		auth.OpItemsDelete: {authtest.Caller("deleter")},
		auth.OpEventsRead:  {authtest.Caller("auditor")},
	}
	authn, err := auth.New(iss.Config(perms), auth.Enforce, nil)
	if err != nil {
		t.Fatal(err)
	}
	h := authn.Authenticate("/livez", "/readyz")((&App{}).publicMux(handlers.NewHandler(nil, nil, nil), authn))

	routes := map[string]string{
		"GET /items":      "reader",
		"GET /items/1":    "reader",
		"POST /items":     "creator",
		"DELETE /items/1": "deleter",
		"GET /events":     "auditor",
	}
	callers := []string{"reader", "creator", "deleter", "auditor"}
	for route, allowed := range routes {
		method, path, _ := strings.Cut(route, " ")
		for _, c := range callers {
			req := httptest.NewRequest(method, path, nil)
			req.Header.Set("Authorization", "Bearer "+iss.Token(c))
			rec := httptest.NewRecorder()
			h.ServeHTTP(rec, req)
			want := http.StatusForbidden
			if c == allowed {
				want = http.StatusServiceUnavailable // past the check, no database
			}
			if rec.Code != want {
				t.Errorf("%s as %s: %d, want %d", route, c, rec.Code, want)
			}
		}
		// No token
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(method, path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without a token: %d, want 401", route, rec.Code)
		}
	}

	// The probes need no token
	for _, path := range []string{"/livez", "/readyz"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusOK {
			t.Errorf("%s without a token: %d, want 200", path, rec.Code)
		}
	}
	// /hello (any authenticated caller) and /health: 401 without a token
	for _, path := range []string{"/hello", "/health"} {
		rec := httptest.NewRecorder()
		h.ServeHTTP(rec, httptest.NewRequest(http.MethodGet, path, nil))
		if rec.Code != http.StatusUnauthorized {
			t.Errorf("%s without a token: %d, want 401", path, rec.Code)
		}
	}
}
