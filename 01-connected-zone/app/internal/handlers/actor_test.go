package handlers

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/Chahine-tech/lumen/internal/auth"
	"github.com/Chahine-tech/lumen/internal/auth/authtest"
)

// The events of a write record the authenticated caller, or "anonymous"
// when the request was served without one (report mode).
func TestActorIsTheCaller(t *testing.T) {
	iss := authtest.New(t)
	authn, err := auth.New(iss.Config(nil), auth.Report, nil)
	if err != nil {
		t.Fatal(err)
	}
	s := newFakeItemStore()
	h := NewHandler(nil, s, nil)
	mux := http.NewServeMux()
	mux.HandleFunc("POST /items", h.CreateItem)
	mux.HandleFunc("DELETE /items/{id}", h.DeleteItem)
	handler := authn.Authenticate()(mux)

	for _, tc := range []struct {
		method, path, body, sub, want string
	}{
		{http.MethodPost, "/items", `{"name":"x"}`, "alice", authtest.Caller("alice")},
		{http.MethodDelete, "/items/1", "", "bob", authtest.Caller("bob")},
		{http.MethodPost, "/items", `{"name":"y"}`, "", auth.Anonymous},
	} {
		req := httptest.NewRequest(tc.method, tc.path, strings.NewReader(tc.body))
		if tc.sub != "" {
			req.Header.Set("Authorization", "Bearer "+iss.Token(tc.sub))
		}
		rec := httptest.NewRecorder()
		handler.ServeHTTP(rec, req)
		if rec.Code >= 300 || s.lastActor != tc.want {
			t.Errorf("%s %s as %q: %d, actor %q; want %q", tc.method, tc.path, tc.sub, rec.Code, s.lastActor, tc.want)
		}
	}
}
