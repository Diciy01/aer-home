package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

const testToken = "test-token-not-a-secret"

func newTestRouter(t *testing.T) (*Router, *strings.Builder) {
	t.Helper()
	logs := &strings.Builder{}
	log := slog.New(slog.NewTextHandler(logs, nil))
	rt := NewRouter(log, func(tok string) bool { return tok == testToken })
	rt.Handle("GET", "/open", func(w http.ResponseWriter, r *http.Request) error {
		WriteData(w, r, http.StatusOK, map[string]string{"hello": "world"})
		return nil
	}, Public())
	rt.Handle("GET", "/secret", func(w http.ResponseWriter, r *http.Request) error {
		WriteData(w, r, http.StatusOK, "ok")
		return nil
	})
	rt.Handle("GET", "/conflict", func(http.ResponseWriter, *http.Request) error {
		return NewError(http.StatusConflict, CodeConflict, "revision mismatch").WithDetails(map[string]any{"revision": 3})
	}, Public())
	rt.Handle("GET", "/boom", func(http.ResponseWriter, *http.Request) error {
		return errors.New("db password=hunter2 leaked?")
	}, Public())
	rt.Handle("GET", "/items/{id}", func(w http.ResponseWriter, r *http.Request) error {
		WriteData(w, r, http.StatusOK, r.PathValue("id"))
		return nil
	}, Public())
	rt.Handle("GET", "/panic", func(http.ResponseWriter, *http.Request) error {
		panic("kaboom")
	}, Public())
	return rt, logs
}

type envelope struct {
	Data  json.RawMessage `json:"data"`
	Error *struct {
		Code    Code           `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	} `json:"error"`
	Meta Meta `json:"meta"`
}

func do(t *testing.T, h http.Handler, method, path, token string) (*http.Response, envelope) {
	t.Helper()
	req := httptest.NewRequest(method, path, nil)
	if token != "" {
		req.Header.Set("Authorization", "Bearer "+token)
	}
	rec := httptest.NewRecorder()
	h.ServeHTTP(rec, req)
	res := rec.Result()
	body, _ := io.ReadAll(res.Body)
	var env envelope
	if err := json.Unmarshal(body, &env); err != nil {
		t.Fatalf("%s %s: body is not JSON envelope: %q", method, path, body)
	}
	if env.Meta.RequestID == "" || env.Meta.APIVersion != "v1" {
		t.Fatalf("%s %s: missing meta: %+v", method, path, env.Meta)
	}
	if res.Header.Get("X-Request-ID") != env.Meta.RequestID {
		t.Fatalf("X-Request-ID header does not match meta")
	}
	return res, env
}

func TestSuccessEnvelope(t *testing.T) {
	rt, _ := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/open", "")
	if res.StatusCode != 200 || env.Error != nil || string(env.Data) != `{"hello":"world"}` {
		t.Fatalf("status=%d env=%+v data=%s", res.StatusCode, env, env.Data)
	}
	if ct := res.Header.Get("Content-Type"); !strings.HasPrefix(ct, "application/json") {
		t.Fatalf("Content-Type = %q", ct)
	}
	if res.Header.Get("Cache-Control") != "no-store" || res.Header.Get("X-Content-Type-Options") != "nosniff" {
		t.Fatal("security headers missing")
	}
}

func TestAuthRequired(t *testing.T) {
	rt, _ := newTestRouter(t)
	for _, tok := range []string{"", "wrong"} {
		res, env := do(t, rt, "GET", "/api/v1/secret", tok)
		if res.StatusCode != 401 || env.Error == nil || env.Error.Code != CodeUnauthorized {
			t.Fatalf("token %q: status=%d env=%+v", tok, res.StatusCode, env)
		}
		if res.Header.Get("WWW-Authenticate") == "" {
			t.Fatal("WWW-Authenticate missing")
		}
	}
	res, env := do(t, rt, "GET", "/api/v1/secret", testToken)
	if res.StatusCode != 200 || env.Error != nil {
		t.Fatalf("valid token rejected: %d %+v", res.StatusCode, env)
	}
}

func TestAPIErrorWithDetails(t *testing.T) {
	rt, _ := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/conflict", "")
	if res.StatusCode != 409 || env.Error.Code != CodeConflict || env.Error.Details["revision"] != float64(3) {
		t.Fatalf("status=%d env=%+v", res.StatusCode, env.Error)
	}
}

func TestInternalErrorIsNotLeaked(t *testing.T) {
	rt, logs := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/boom", "")
	if res.StatusCode != 500 || env.Error.Code != CodeInternal || strings.Contains(env.Error.Message, "hunter2") {
		t.Fatalf("status=%d err=%+v", res.StatusCode, env.Error)
	}
	if !strings.Contains(logs.String(), "handler failed") {
		t.Fatal("original error should be logged server-side")
	}
}

func TestPanicRecovered(t *testing.T) {
	rt, logs := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/panic", "")
	if res.StatusCode != 500 || env.Error.Code != CodeInternal {
		t.Fatalf("status=%d err=%+v", res.StatusCode, env.Error)
	}
	if !strings.Contains(logs.String(), "kaboom") {
		t.Fatal("panic not logged")
	}
}

func TestNotFoundAndMethodNotAllowed(t *testing.T) {
	rt, _ := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/nope", "")
	if res.StatusCode != 404 || env.Error.Code != CodeNotFound {
		t.Fatalf("404: status=%d err=%+v", res.StatusCode, env.Error)
	}
	res, env = do(t, rt, "POST", "/api/v1/open", "")
	if res.StatusCode != 405 || env.Error.Code != CodeMethodNotAllowed || !strings.Contains(res.Header.Get("Allow"), "GET") {
		t.Fatalf("405: status=%d allow=%q err=%+v", res.StatusCode, res.Header.Get("Allow"), env.Error)
	}
}

func TestTokenNeverLogged(t *testing.T) {
	rt, logs := newTestRouter(t)
	do(t, rt, "GET", "/api/v1/secret", testToken)
	if strings.Contains(logs.String(), testToken) {
		t.Fatal("bearer token leaked into logs")
	}
}

func TestRoutesListed(t *testing.T) {
	rt, _ := newTestRouter(t)
	routes := rt.Routes()
	if len(routes) != 6 || routes[0].Path != "/boom" {
		t.Fatalf("routes = %+v", routes)
	}
}

func TestPathValues(t *testing.T) {
	rt, _ := newTestRouter(t)
	res, env := do(t, rt, "GET", "/api/v1/items/abc-123", "")
	if res.StatusCode != 200 || string(env.Data) != `"abc-123"` {
		t.Fatalf("path value not propagated: %d %s", res.StatusCode, env.Data)
	}
}
