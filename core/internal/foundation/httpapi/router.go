package httpapi

import (
	"context"
	"crypto/rand"
	"encoding/hex"
	"errors"
	"log/slog"
	"net/http"
	"sort"
	"strings"
	"time"
)

// Prefix is prepended to every module route.
const Prefix = "/api/" + APIVersion

const maxBodyBytes = 1 << 20

// HandlerFunc is a module handler. Returning an *Error produces that error
// envelope; any other error becomes INTERNAL and is logged.
type HandlerFunc func(w http.ResponseWriter, r *http.Request) error

// Route describes a registered endpoint (used by contract tests).
type Route struct {
	Method string
	Path   string // relative to Prefix, e.g. "/health"
	Public bool
}

// RouteOption customises a route.
type RouteOption func(*Route)

// Public marks a route as reachable without the bearer token.
func Public() RouteOption { return func(rt *Route) { rt.Public = true } }

// TokenVerifier reports whether a presented bearer token is valid.
type TokenVerifier func(token string) bool

// Router is the Core HTTP entry point.
type Router struct {
	mux    *http.ServeMux
	routes []Route
	verify TokenVerifier
	log    *slog.Logger
}

// NewRouter creates a router; verify guards every non-public route.
func NewRouter(log *slog.Logger, verify TokenVerifier) *Router {
	return &Router{mux: http.NewServeMux(), verify: verify, log: log}
}

// Handle registers a handler for method and path (relative to Prefix).
func (rt *Router) Handle(method, path string, h HandlerFunc, opts ...RouteOption) {
	route := Route{Method: method, Path: path}
	for _, o := range opts {
		o(&route)
	}
	rt.routes = append(rt.routes, route)
	rt.mux.Handle(method+" "+Prefix+path, rt.wrap(route, h))
}

// Routes returns all registered routes sorted by path then method.
func (rt *Router) Routes() []Route {
	out := append([]Route(nil), rt.routes...)
	sort.Slice(out, func(i, j int) bool {
		if out[i].Path != out[j].Path {
			return out[i].Path < out[j].Path
		}
		return out[i].Method < out[j].Method
	})
	return out
}

func (rt *Router) wrap(route Route, h HandlerFunc) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !route.Public && !rt.authorized(r) {
			w.Header().Set("WWW-Authenticate", `Bearer realm="aer-core"`)
			WriteError(w, r, NewError(http.StatusUnauthorized, CodeUnauthorized, "missing or invalid bearer token"))
			return
		}
		r.Body = http.MaxBytesReader(w, r.Body, maxBodyBytes)
		if err := h(w, r); err != nil {
			var apiErr *Error
			if !errors.As(err, &apiErr) {
				rt.log.Error("handler failed", "requestId", RequestID(r.Context()), "path", route.Path, "err", err)
			}
			WriteError(w, r, err)
		}
	})
}

func (rt *Router) authorized(r *http.Request) bool {
	h := r.Header.Get("Authorization")
	token, ok := strings.CutPrefix(h, "Bearer ")
	return ok && token != "" && rt.verify != nil && rt.verify(token)
}

// ServeHTTP applies request ID, panic recovery, security headers and access logging,
// and turns unmatched requests into NOT_FOUND / METHOD_NOT_ALLOWED envelopes.
func (rt *Router) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	start := time.Now()
	id := newRequestID()
	r = r.WithContext(context.WithValue(r.Context(), requestIDKey{}, id))
	sw := &statusWriter{ResponseWriter: w, status: http.StatusOK}
	h := sw.Header()
	h.Set("X-Request-ID", id)
	h.Set("X-Content-Type-Options", "nosniff")
	h.Set("Cache-Control", "no-store")

	defer func() {
		if p := recover(); p != nil {
			rt.log.Error("panic in handler", "requestId", id, "path", r.URL.Path, "panic", p)
			if !sw.wrote {
				WriteError(sw, r, NewError(http.StatusInternalServerError, CodeInternal, "internal error"))
			}
		}
		// Never log headers or bodies: they may carry the token or secrets.
		rt.log.Info("http", "requestId", id, "method", r.Method, "path", r.URL.Path,
			"status", sw.status, "durationMs", time.Since(start).Milliseconds())
	}()

	handler, pattern := rt.mux.Handler(r)
	if pattern != "" {
		handler.ServeHTTP(sw, r)
		return
	}
	// Let the mux decide between 404 and 405, then answer with our envelope.
	probe := &probeWriter{header: http.Header{}}
	handler.ServeHTTP(probe, r)
	if probe.status == http.StatusMethodNotAllowed {
		sw.Header().Set("Allow", probe.header.Get("Allow"))
		WriteError(sw, r, NewError(http.StatusMethodNotAllowed, CodeMethodNotAllowed, "method not allowed"))
		return
	}
	WriteError(sw, r, NewError(http.StatusNotFound, CodeNotFound, "no such endpoint"))
}

type requestIDKey struct{}

// RequestID returns the ID assigned to the current request.
func RequestID(ctx context.Context) string {
	id, _ := ctx.Value(requestIDKey{}).(string)
	return id
}

func newRequestID() string {
	var b [12]byte
	_, _ = rand.Read(b[:])
	return hex.EncodeToString(b[:])
}

type statusWriter struct {
	http.ResponseWriter
	status int
	wrote  bool
}

func (s *statusWriter) WriteHeader(code int) {
	if !s.wrote {
		s.status, s.wrote = code, true
	}
	s.ResponseWriter.WriteHeader(code)
}

func (s *statusWriter) Write(b []byte) (int, error) {
	s.wrote = true
	return s.ResponseWriter.Write(b)
}

func (s *statusWriter) Unwrap() http.ResponseWriter { return s.ResponseWriter }

type probeWriter struct {
	header http.Header
	status int
}

func (p *probeWriter) Header() http.Header         { return p.header }
func (p *probeWriter) Write(b []byte) (int, error) { return len(b), nil }
func (p *probeWriter) WriteHeader(code int)        { p.status = code }
