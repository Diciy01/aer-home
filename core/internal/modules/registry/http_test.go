package registry

import (
	"encoding/json"
	"io"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"

	"aerhome/core/internal/foundation/httpapi"
)

const httpToken = "test-token-not-a-secret"

type apiResp struct {
	Status int
	Header http.Header
	Data   json.RawMessage
	Error  *struct {
		Code    string         `json:"code"`
		Message string         `json:"message"`
		Details map[string]any `json:"details"`
	}
}

func newTestServer(t *testing.T) *httptest.Server {
	t.Helper()
	db := openDB(t, filepath.Join(t.TempDir(), "reg.db"))
	t.Cleanup(func() { db.Close() })
	rt := httpapi.NewRouter(slog.New(slog.NewTextHandler(io.Discard, nil)), func(tok string) bool { return tok == httpToken })
	(&Module{svc: NewService(db, DefaultCatalog(), nil)}).RegisterRoutes(rt)
	srv := httptest.NewServer(rt)
	t.Cleanup(srv.Close)
	return srv
}

func call(t *testing.T, srv *httptest.Server, method, path, body string) apiResp {
	t.Helper()
	var rd io.Reader
	if body != "" {
		rd = strings.NewReader(body)
	}
	req, _ := http.NewRequest(method, srv.URL+"/api/v1"+path, rd)
	req.Header.Set("Authorization", "Bearer "+httpToken)
	res, err := srv.Client().Do(req)
	if err != nil {
		t.Fatal(err)
	}
	defer res.Body.Close()
	var out apiResp
	if err := json.NewDecoder(res.Body).Decode(&out); err != nil {
		t.Fatalf("%s %s: decode: %v", method, path, err)
	}
	out.Status, out.Header = res.StatusCode, res.Header
	return out
}

func (r apiResp) entity(t *testing.T) Entity {
	t.Helper()
	var e Entity
	if err := json.Unmarshal(r.Data, &e); err != nil {
		t.Fatalf("entity: %v (%s)", err, r.Data)
	}
	return e
}

func expect(t *testing.T, r apiResp, status int, code string) {
	t.Helper()
	if r.Status != status {
		t.Fatalf("status %d, want %d (error %+v, data %s)", r.Status, status, r.Error, r.Data)
	}
	if code == "" && r.Error != nil || code != "" && (r.Error == nil || r.Error.Code != code) {
		t.Fatalf("error %+v, want code %q", r.Error, code)
	}
}

func TestHTTPCatalogEndpoints(t *testing.T) {
	srv := newTestServer(t)
	for path, min := range map[string]int{"/registry/types": 17, "/registry/capabilities": 13, "/registry/relation-kinds": 7} {
		r := call(t, srv, "GET", path, "")
		expect(t, r, 200, "")
		var list []map[string]any
		if err := json.Unmarshal(r.Data, &list); err != nil || len(list) < min {
			t.Fatalf("%s: %d items, err %v", path, len(list), err)
		}
	}
}

func TestHTTPEntityLifecycle(t *testing.T) {
	srv := newTestServer(t)

	r := call(t, srv, "POST", "/registry/entities", `{"name":"Сервер (тест)","type":"server","tags":["home"]}`)
	expect(t, r, 201, "")
	server := r.entity(t)
	if r.Header.Get("Location") != "/api/v1/registry/entities/"+server.ID {
		t.Fatalf("Location = %q", r.Header.Get("Location"))
	}

	r = call(t, srv, "POST", "/registry/entities", `{"name":"","type":"website"}`)
	expect(t, r, 422, "VALIDATION_FAILED")
	f := r.Error.Details["fields"].(map[string]any)
	if f["name"] == nil || f["address"] == nil {
		t.Fatalf("field details = %v", f)
	}
	expect(t, call(t, srv, "POST", "/registry/entities", `{"name":"x","type":"server","password":"hunter2"}`), 400, "BAD_REQUEST")
	expect(t, call(t, srv, "POST", "/registry/entities", `not json`), 400, "BAD_REQUEST")

	r = call(t, srv, "GET", "/registry/entities/"+server.ID, "")
	expect(t, r, 200, "")
	expect(t, call(t, srv, "GET", "/registry/entities/00000000-0000-4000-8000-000000000000", ""), 404, "NOT_FOUND")
	expect(t, call(t, srv, "GET", "/registry/entities/not-a-uuid", ""), 404, "NOT_FOUND")

	r = call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"revision":1,"name":"Домашний сервер","address":"192.0.2.5"}`)
	expect(t, r, 200, "")
	if e := r.entity(t); e.Revision != 2 || *e.Address != "192.0.2.5" {
		t.Fatalf("patched = %+v", e)
	}
	r = call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"revision":1,"name":"Чужая правка"}`)
	expect(t, r, 409, "CONFLICT")
	if r.Error.Details["reason"] != "revision_mismatch" || r.Error.Details["currentRevision"] != float64(2) {
		t.Fatalf("conflict details = %v", r.Error.Details)
	}
	r = call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"revision":2,"address":null}`)
	expect(t, r, 200, "")
	if r.entity(t).Address != nil {
		t.Fatal("address not cleared by null")
	}
	expect(t, call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"revision":3,"status":"ONLINE"}`), 400, "BAD_REQUEST")
	expect(t, call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"name":"no revision"}`), 422, "VALIDATION_FAILED")
	expect(t, call(t, srv, "PATCH", "/registry/entities/"+server.ID, `{"revision":3,"name":null}`), 422, "VALIDATION_FAILED")

	r = call(t, srv, "PUT", "/registry/entities/"+server.ID+"/capabilities", `{"revision":3,"capabilities":["power.wake","network.ping"]}`)
	expect(t, r, 200, "")
	if e := r.entity(t); !equal(e.Capabilities, []string{"network.ping", "power.wake"}) || e.Revision != 4 {
		t.Fatalf("caps = %+v", e)
	}
	expect(t, call(t, srv, "PUT", "/registry/entities/"+server.ID+"/capabilities", `{"revision":4}`), 422, "VALIDATION_FAILED")

	r = call(t, srv, "POST", "/registry/entities/"+server.ID+"/archive", `{"revision":4}`)
	expect(t, r, 200, "")
	if !r.entity(t).Archived {
		t.Fatal("not archived")
	}
	expect(t, call(t, srv, "POST", "/registry/entities/"+server.ID+"/archive", `{"revision":5}`), 409, "CONFLICT")
	r = call(t, srv, "POST", "/registry/entities/"+server.ID+"/restore", `{"revision":5}`)
	expect(t, r, 200, "")
	if r.entity(t).Archived {
		t.Fatal("not restored")
	}
}

func TestHTTPListQuery(t *testing.T) {
	srv := newTestServer(t)
	for _, body := range []string{
		`{"name":"Основной ПК","type":"computer","tags":["home"]}`,
		`{"name":"Сервер","type":"server","tags":["home"]}`,
		`{"name":"Сайт","type":"website","address":"https://example.org"}`,
	} {
		expect(t, call(t, srv, "POST", "/registry/entities", body), 201, "")
	}
	page := func(query string) Page {
		r := call(t, srv, "GET", "/registry/entities"+query, "")
		expect(t, r, 200, "")
		var p Page
		if err := json.Unmarshal(r.Data, &p); err != nil {
			t.Fatal(err)
		}
		return p
	}
	if p := page(""); p.Total != 3 || p.Limit != 50 || p.Offset != 0 {
		t.Fatalf("default page = %+v", p)
	}
	if p := page("?type=computer&type=website"); p.Total != 2 {
		t.Fatalf("multi type = %d", p.Total)
	}
	if p := page("?tag=home&q=%D1%81%D0%B5%D1%80%D0%B2%D0%B5%D1%80"); p.Total != 1 || p.Items[0].Name != "Сервер" {
		t.Fatalf("tag+q = %+v", p.Items)
	}
	if p := page("?capability=monitoring.http"); p.Total != 1 {
		t.Fatalf("capability = %d", p.Total)
	}
	if p := page("?limit=1&offset=1"); len(p.Items) != 1 || p.Total != 3 {
		t.Fatalf("paging = %+v", p)
	}
	if p := page("?archived=true"); p.Total != 0 || p.Items == nil {
		t.Fatalf("archived = %+v (items must be [] not null)", p)
	}
	r := call(t, srv, "GET", "/registry/entities?limit=abc&archived=maybe", "")
	expect(t, r, 422, "VALIDATION_FAILED")
}

func TestHTTPRelations(t *testing.T) {
	srv := newTestServer(t)
	bot := call(t, srv, "POST", "/registry/entities", `{"name":"PICO","type":"telegram_bot"}`).entity(t)
	host := call(t, srv, "POST", "/registry/entities", `{"name":"Сервер","type":"server"}`).entity(t)

	r := call(t, srv, "POST", "/registry/entities/"+bot.ID+"/relations", `{"kind":"runs_on","targetId":"`+host.ID+`"}`)
	expect(t, r, 201, "")
	var rel Relation
	_ = json.Unmarshal(r.Data, &rel)
	if rel.FromID != bot.ID || rel.ToID != host.ID || rel.Kind != "runs_on" {
		t.Fatalf("relation = %+v", rel)
	}
	expect(t, call(t, srv, "POST", "/registry/entities/"+host.ID+"/relations", `{"kind":"runs_on","targetId":"`+bot.ID+`"}`), 409, "CONFLICT")
	expect(t, call(t, srv, "POST", "/registry/entities/"+bot.ID+"/relations", `{"kind":"runs_on","targetId":"`+host.ID+`"}`), 409, "CONFLICT")
	expect(t, call(t, srv, "POST", "/registry/entities/"+bot.ID+"/relations", `{"kind":"nope","targetId":"`+host.ID+`"}`), 422, "VALIDATION_FAILED")

	r = call(t, srv, "GET", "/registry/entities/"+host.ID+"/relations", "")
	expect(t, r, 200, "")
	var views []RelationView
	_ = json.Unmarshal(r.Data, &views)
	if len(views) != 1 || views[0].Direction != "incoming" || views[0].Peer.Name != "PICO" {
		t.Fatalf("views = %+v", views)
	}
	expect(t, call(t, srv, "DELETE", "/registry/relations/"+rel.ID, ""), 200, "")
	expect(t, call(t, srv, "DELETE", "/registry/relations/"+rel.ID, ""), 404, "NOT_FOUND")
	expect(t, call(t, srv, "GET", "/registry/entities/00000000-0000-4000-8000-000000000000/relations", ""), 404, "NOT_FOUND")
}

func TestHTTPRequiresAuth(t *testing.T) {
	srv := newTestServer(t)
	res, err := srv.Client().Get(srv.URL + "/api/v1/registry/entities")
	if err != nil {
		t.Fatal(err)
	}
	res.Body.Close()
	if res.StatusCode != 401 {
		t.Fatalf("status %d", res.StatusCode)
	}
}
