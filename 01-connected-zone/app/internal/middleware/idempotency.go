package middleware

import (
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"strings"
	"time"

	"go.opentelemetry.io/otel"
	"go.opentelemetry.io/otel/attribute"
	"go.opentelemetry.io/otel/codes"
)

const (
	idempotencyTTL = 24 * time.Hour
	// lockTTL bounds how long a crashed request can block retries with the same key.
	lockTTL = 30 * time.Second
	// maxIdempotencyKeyLength bounds the header (a UUID is 36 characters).
	maxIdempotencyKeyLength = 128
)

var idempotencyTracer = otel.Tracer("lumen-api/idempotency")

type idempotencyStore interface {
	GetIdempotencyResult(ctx context.Context, key string) ([]byte, error)
	SetIdempotencyResult(ctx context.Context, key string, data []byte, ttl time.Duration) error
	// The token identifies the holder: release deletes the lock only if it
	// still holds that token, not the lock of a request that took over
	// after lockTTL.
	AcquireIdempotencyLock(ctx context.Context, key, token string, ttl time.Duration) (bool, error)
	ReleaseIdempotencyLock(ctx context.Context, key, token string) error
}

// replayedHeaders are stored with the response and replayed. Other headers
// (set by the outer middlewares: tracing, security) belong to the request
// that is answering, not to the one that was recorded.
var replayedHeaders = []string{"Content-Type", "Location"}

type cachedResponse struct {
	Status int         `json:"status"`
	Body   []byte      `json:"body"`
	Header http.Header `json:"header,omitempty"`
	// Fingerprint of the request the response belongs to (method, path,
	// query and body). Empty in records written up to v1.6.0: those are
	// replayed without the check until they expire (idempotencyTTL).
	Fingerprint string `json:"fingerprint,omitempty"`
}

// capturingWriter records the status code and body written by the handler.
type capturingWriter struct {
	http.ResponseWriter
	statusCode int
	buf        bytes.Buffer
}

func (cw *capturingWriter) WriteHeader(code int) {
	cw.statusCode = code
	cw.ResponseWriter.WriteHeader(code)
}

func (cw *capturingWriter) Write(b []byte) (int, error) {
	cw.buf.Write(b)
	return cw.ResponseWriter.Write(b)
}

// Idempotency returns a middleware that deduplicates non-idempotent requests using
// an Idempotency-Key header. Results are cached in Redis for 24 hours.
// Only applied to methods passed in applyTo (typically POST and DELETE).
//
// A key belongs to one request: reusing it with another method, path or body
// is answered 422. While Redis is unavailable, requests that carry a key are
// answered 503 instead of running without deduplication; requests without a
// key are not affected. docs/architecture.md, "Idempotency".
func Idempotency(store idempotencyStore, applyTo ...string) func(http.Handler) http.Handler {
	methods := make(map[string]bool, len(applyTo))
	for _, m := range applyTo {
		methods[strings.ToUpper(m)] = true
	}

	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !methods[r.Method] {
				next.ServeHTTP(w, r)
				return
			}

			key := r.Header.Get("Idempotency-Key")
			if key == "" {
				next.ServeHTTP(w, r)
				return
			}
			if !validIdempotencyKey(key) {
				writeIdempotencyError(w, http.StatusBadRequest,
					"Idempotency-Key must be 1 to 128 visible ASCII characters")
				return
			}

			ctx, span := idempotencyTracer.Start(r.Context(), "idempotency.check")
			defer span.End()
			span.SetAttributes(attribute.String("idempotency.key", key))

			body, err := io.ReadAll(r.Body)
			if err != nil {
				var tooLarge *http.MaxBytesError
				if errors.As(err, &tooLarge) {
					writeIdempotencyError(w, http.StatusRequestEntityTooLarge, "request body too large")
					return
				}
				writeIdempotencyError(w, http.StatusBadRequest, "could not read the request body")
				return
			}
			r.Body = io.NopCloser(bytes.NewReader(body))
			fp := fingerprint(r, body)

			// unavailable answers 503: running the handler without the
			// record would break the guarantee the client asked for.
			unavailable := func(op string, err error) {
				slog.Error("Idempotency store unavailable", "op", op, "error", err)
				span.RecordError(err)
				span.SetStatus(codes.Error, op)
				w.Header().Set("Retry-After", "5")
				writeIdempotencyError(w, http.StatusServiceUnavailable,
					"idempotency store unavailable, retry later")
			}

			// Cache hit: return the stored response.
			cached, err := lookup(ctx, store, key)
			if err != nil {
				unavailable("get", err)
				return
			}
			if cached != nil {
				span.SetAttributes(attribute.Bool("idempotency.cache_hit", true))
				replay(w, cached, fp)
				return
			}
			span.SetAttributes(attribute.Bool("idempotency.cache_hit", false))

			// Claim the key before executing, so two in-flight requests with the
			// same key cannot both run the handler.
			token := rand.Text()
			locked, err := store.AcquireIdempotencyLock(ctx, key, token, lockTTL)
			if err != nil {
				unavailable("lock", err)
				return
			}
			if !locked {
				span.SetAttributes(attribute.Bool("idempotency.conflict", true))
				w.Header().Set("Retry-After", "1")
				writeIdempotencyError(w, http.StatusConflict,
					"a request with this Idempotency-Key is already in progress")
				return
			}
			defer func() {
				// Not the request context: the client may be gone, the lock
				// must still be released.
				if err := store.ReleaseIdempotencyLock(context.WithoutCancel(ctx), key, token); err != nil {
					slog.Warn("Idempotency lock not released, expires in lockTTL", "error", err)
				}
			}()
			// The other request may have stored its result between our cache
			// check and the lock acquisition: re-check before executing.
			cached, err = lookup(ctx, store, key)
			if err != nil {
				unavailable("get", err)
				return
			}
			if cached != nil {
				span.SetAttributes(attribute.Bool("idempotency.cache_hit", true))
				replay(w, cached, fp)
				return
			}

			// Execute the handler and store the result.
			cw := &capturingWriter{ResponseWriter: w, statusCode: http.StatusOK}
			next.ServeHTTP(cw, r.WithContext(ctx))

			// Never cache 5xx: a transient server error must not be replayed
			// for 24h to every retry of the same key.
			if cw.statusCode >= http.StatusInternalServerError {
				return
			}
			resp := cachedResponse{
				Status:      cw.statusCode,
				Body:        cw.buf.Bytes(),
				Header:      http.Header{},
				Fingerprint: fp,
			}
			for _, h := range replayedHeaders {
				if v := cw.Header().Values(h); len(v) > 0 {
					resp.Header[h] = v
				}
			}
			data, err := json.Marshal(resp)
			if err == nil {
				err = store.SetIdempotencyResult(context.WithoutCancel(ctx), key, data, idempotencyTTL)
			}
			if err != nil {
				// The response is already sent. Without the record, a retry
				// with this key executes the request again.
				slog.Error("Idempotency result not stored, a retry will execute again", "error", err)
				span.RecordError(err)
				span.SetStatus(codes.Error, "store result")
			}
		})
	}
}

// validIdempotencyKey accepts 1 to maxIdempotencyKeyLength visible ASCII
// characters (no space, no control character).
func validIdempotencyKey(key string) bool {
	if len(key) == 0 || len(key) > maxIdempotencyKeyLength {
		return false
	}
	for i := 0; i < len(key); i++ {
		if key[i] < 0x21 || key[i] > 0x7e {
			return false
		}
	}
	return true
}

// fingerprint identifies the request a key was first used for.
func fingerprint(r *http.Request, body []byte) string {
	h := sha256.New()
	h.Write([]byte(r.Method + "\n" + r.URL.Path + "\n" + r.URL.RawQuery + "\n"))
	h.Write(body)
	return hex.EncodeToString(h.Sum(nil))
}

// lookup returns the stored response for key, or nil when there is none.
// A record that cannot be decoded counts as none.
func lookup(ctx context.Context, store idempotencyStore, key string) (*cachedResponse, error) {
	data, err := store.GetIdempotencyResult(ctx, key)
	if err != nil || data == nil {
		return nil, err
	}
	var resp cachedResponse
	if json.Unmarshal(data, &resp) != nil {
		return nil, nil
	}
	return &resp, nil
}

// replay writes the stored response, or 422 when it belongs to another request.
func replay(w http.ResponseWriter, resp *cachedResponse, fp string) {
	if resp.Fingerprint != "" && resp.Fingerprint != fp {
		writeIdempotencyError(w, http.StatusUnprocessableEntity,
			"Idempotency-Key already used for a different request")
		return
	}
	for h, v := range resp.Header {
		w.Header()[h] = v
	}
	if w.Header().Get("Content-Type") == "" {
		w.Header().Set("Content-Type", "application/json")
	}
	w.Header().Set("Idempotency-Replayed", "true")
	w.WriteHeader(resp.Status)
	w.Write(resp.Body)
}

func writeIdempotencyError(w http.ResponseWriter, status int, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	json.NewEncoder(w).Encode(map[string]string{"error": msg})
}
