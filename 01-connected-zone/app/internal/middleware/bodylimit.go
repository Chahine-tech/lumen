package middleware

import "net/http"

// BodyLimit caps the request body size. Without it, a single client can make
// the server buffer an arbitrarily large JSON payload in memory.
// http.MaxBytesReader closes the connection once the limit is exceeded and
// makes further reads return *http.MaxBytesError.
func BodyLimit(maxBytes int64) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if r.Body != nil {
				r.Body = http.MaxBytesReader(w, r.Body, maxBytes)
			}
			next.ServeHTTP(w, r)
		})
	}
}
