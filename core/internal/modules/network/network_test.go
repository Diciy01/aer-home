package network

import (
	"context"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"aerhome/core/internal/foundation/config"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// TEST DATA: every router, TV and Sunshine here is a local stub (httptest
// on 127.0.0.1). No real device is contacted.

type clock struct {
	mu sync.Mutex
	t  time.Time
}

func (c *clock) now() time.Time { c.mu.Lock(); defer c.mu.Unlock(); return c.t }
func (c *clock) add(d time.Duration) {
	c.mu.Lock()
	c.t = c.t.Add(d)
	c.mu.Unlock()
}

type fx struct {
	ctx context.Context
	reg *registry.Service
	mon *monitoring.Service
	svc *Service
	clk *clock
}

func newFx(t *testing.T, cfg config.Network) *fx {
	t.Helper()
	ctx := context.Background()
	db, err := storage.Open(ctx, filepath.Join(t.TempDir(), "t.db"))
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { db.Close() })
	clk := &clock{t: time.Now().UTC().Truncate(time.Second)}
	mcfg := config.DefaultMonitoring()
	mcfg.Docker.Enabled = false
	rm, _ := registry.Factory(registry.DefaultCatalog())(module.Deps{DB: db})
	reg := rm.(*registry.Module).Writer()
	mm, _ := monitoring.Factory(func() registry.Reader { return reg }, clk.now)(module.Deps{DB: db, Config: config.Config{Monitoring: mcfg}})
	for _, m := range []module.Module{rm, mm} {
		if _, err := storage.Migrate(ctx, db, m.Name(), m.Migrations()); err != nil {
			t.Fatal(err)
		}
	}
	if _, err := storage.Migrate(ctx, db, Name, migrations); err != nil {
		t.Fatal(err)
	}
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	mon := mm.(*monitoring.Module).Service()
	return &fx{ctx: ctx, reg: reg, mon: mon, svc: NewService(db, reg, mon, cfg, mcfg, nil, clk.now), clk: clk}
}

func baseCfg() config.Network {
	c := config.DefaultNetwork()
	c.TimeoutSec = 2
	return c
}

func (f *fx) entity(t *testing.T, name, typ string, addr ...string) registry.Entity {
	t.Helper()
	in := registry.NewEntity{Name: name, Type: typ}
	if len(addr) > 0 {
		in.Address = &addr[0]
	}
	e, err := f.reg.Create(f.ctx, in)
	if err != nil {
		t.Fatal(err)
	}
	return e
}

func (f *fx) overview(t *testing.T) Overview {
	t.Helper()
	o, err := f.svc.Overview(f.ctx)
	if err != nil {
		t.Fatal(err)
	}
	return o
}

func (f *fx) active(t *testing.T, key string) []monitoring.Incident {
	p, err := f.mon.Incidents(f.ctx, monitoring.IncidentFilter{Status: "active"})
	if err != nil {
		t.Fatal(err)
	}
	var out []monitoring.Incident
	for _, i := range p.Items {
		if i.Key == key {
			out = append(out, i)
		}
	}
	return out
}

func (f *fx) logs(t *testing.T) []monitoring.LogEntry {
	p, err := f.mon.Logs(f.ctx, monitoring.LogFilter{Source: "net.", Limit: 100})
	if err != nil {
		t.Fatal(err)
	}
	return p.Items
}

func listener(t *testing.T) string {
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { ln.Close() })
	go func() {
		for {
			c, err := ln.Accept()
			if err != nil {
				return
			}
			c.Close()
		}
	}()
	return ln.Addr().String()
}

// ---- Sunshine stub ----

type sunshineStub struct {
	mu    sync.Mutex
	state string
	code  int
	body  string
	hits  int
}

func (s *sunshineStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.hits++
	if r.URL.Path != "/serverinfo" || r.Method != http.MethodGet {
		http.NotFound(w, r)
		return
	}
	if s.code != 0 {
		w.WriteHeader(s.code)
		return
	}
	if s.body != "" {
		io.WriteString(w, s.body)
		return
	}
	// Same shape as a real Sunshine reply; private fields hold fixtures.
	fmt.Fprintf(w, `<?xml version="1.0" encoding="utf-8"?><root status_code="200"><hostname>stub-host</hostname>`+
		`<appversion>7.1.431.-1</appversion><GfeVersion>3.23.0.74</GfeVersion><uniqueid>0123456789ABCDEF</uniqueid>`+
		`<HttpsPort>47984</HttpsPort><ExternalPort>47989</ExternalPort><MaxLumaPixelsHEVC>0</MaxLumaPixelsHEVC>`+
		`<mac>00:00:5e:00:53:01</mac><LocalIP>192.0.2.10</LocalIP><ServerCodecModeSupport>257</ServerCodecModeSupport>`+
		`<PairStatus>0</PairStatus><currentgame>%s</currentgame><state>%s</state></root>`,
		map[bool]string{true: "881448767", false: "0"}[strings.HasSuffix(s.state, "BUSY")], s.state)
}

func (s *sunshineStub) set(fn func(*sunshineStub)) { s.mu.Lock(); fn(s); s.mu.Unlock() }

func TestSunshineStatesAndPrivacy(t *testing.T) {
	stub := &sunshineStub{state: "SUNSHINE_SERVER_FREE"}
	srv := httptest.NewServer(stub)
	defer srv.Close()
	web := listener(t)
	cfg := baseCfg()
	cfg.Sunshine = []config.SunshineInstance{{ID: "pc", Name: "Sunshine (тест)", ServerInfoURL: srv.URL, WebURL: "https://" + web}}
	f := newFx(t, cfg)
	tv := f.entity(t, "ТВ (тест)", "television")
	f.svc.cfg.Sunshine[0].TVEntityID = tv.ID

	f.svc.RunChecks(f.ctx)
	o := f.overview(t)
	sh := o.Sunshine[0]
	if sh.Check.Status != StatusUp || *sh.Check.Details.Streaming || sh.Check.Details.Version != "7.1.431.-1" ||
		!*sh.Check.Details.WebReachable || sh.Check.LatencyMs == nil || sh.Check.LastOK == nil {
		t.Fatalf("free: %+v %+v", sh.Check, sh.Check.Details)
	}
	if sh.TV == nil || sh.TV.Status == StatusUp {
		t.Fatalf("TV is separate and not proven up by Sunshine: %+v", sh.TV)
	}
	// Private fields of the reply are never stored.
	var raw string
	_ = f.svc.db.QueryRow(`SELECT details || reason FROM net_checks WHERE key = 'sunshine:pc'`).Scan(&raw)
	for _, secret := range []string{"stub-host", "0123456789ABCDEF", "00:00:5e:00:53:01", "192.0.2.10"} {
		if strings.Contains(raw, secret) {
			t.Fatalf("stored %q", secret)
		}
	}
	stub.set(func(s *sunshineStub) { s.state = "SUNSHINE_SERVER_BUSY" })
	f.svc.RunChecks(f.ctx)
	if d := f.overview(t).Sunshine[0].Check.Details; !*d.Streaming || *d.CurrentApp != 881448767 {
		t.Fatalf("busy: %+v", d)
	}

	// 401 (wrong port: the authenticated web API) → check error, one incident.
	stub.set(func(s *sunshineStub) { s.code = http.StatusUnauthorized })
	f.svc.RunChecks(f.ctx) // 1 of 2: still up, waiting for confirmation
	if c := f.overview(t).Sunshine[0].Check; c.Status != StatusUp || !strings.Contains(c.Reason, "подтверждения") {
		t.Fatalf("unconfirmed: %+v", c)
	}
	f.svc.RunChecks(f.ctx)
	f.svc.RunChecks(f.ctx)
	c := f.overview(t).Sunshine[0].Check
	if c.Status != StatusError || !strings.Contains(c.Reason, "47989") {
		t.Fatalf("401: %+v", c)
	}
	if inc := f.active(t, "network:sunshine:pc"); len(inc) != 1 || inc[0].Occurrences != 1 {
		t.Fatalf("one incident, no repeats per check: %+v", inc)
	}
	// Garbage → error with a clear reason.
	stub.set(func(s *sunshineStub) { s.code = 0; s.body = "<html>router login</html>" })
	f.svc.RunChecks(f.ctx)
	if c := f.overview(t).Sunshine[0].Check; c.Status != StatusError || !strings.Contains(c.Reason, "не похож") {
		t.Fatalf("garbage: %+v", c)
	}
	// Recovery resolves the incident and logs it.
	stub.set(func(s *sunshineStub) { s.body = ""; s.state = "SUNSHINE_SERVER_FREE" })
	f.svc.RunChecks(f.ctx)
	if c := f.overview(t).Sunshine[0].Check; c.Status != StatusUp {
		t.Fatalf("recovered: %+v", c)
	}
	if len(f.active(t, "network:sunshine:pc")) != 0 {
		t.Fatal("incident not resolved")
	}
	logs := f.logs(t)
	if len(logs) < 2 || !strings.Contains(logs[0].Message, "работает") || logs[0].Source != "net.sunshine" {
		t.Fatalf("logs: %+v", logs)
	}
	// Server gone: port closed → down.
	srv.Close()
	f.svc.RunChecks(f.ctx)
	f.svc.RunChecks(f.ctx)
	if c := f.overview(t).Sunshine[0].Check; c.Status != StatusDown || !strings.Contains(c.Reason, "не отвечает") {
		t.Fatalf("closed: %+v", c)
	}
}

func TestFailingCheckLogsAreThrottled(t *testing.T) {
	stub := &sunshineStub{code: http.StatusInternalServerError}
	srv := httptest.NewServer(stub)
	defer srv.Close()
	cfg := baseCfg()
	cfg.Sunshine = []config.SunshineInstance{{ID: "pc", ServerInfoURL: srv.URL}}
	f := newFx(t, cfg)
	for range 10 { // 10 failing checks within 5 min → 1 log line
		f.svc.RunChecks(f.ctx)
		f.clk.add(20 * time.Second)
	}
	if n := len(f.logs(t)); n != 1 {
		t.Fatalf("log lines: %d", n)
	}
	f.clk.add(5 * time.Minute)
	f.svc.RunChecks(f.ctx)
	if n := len(f.logs(t)); n != 2 {
		t.Fatalf("after 5 min: %d", n)
	}
}

// ---- internet ----

func TestInternetUpDownDNSAndUnconfigured(t *testing.T) {
	f := newFx(t, baseCfg())
	f.svc.RunChecks(f.ctx)
	o := f.overview(t)
	if o.Internet.Status != StatusUnconfigured || o.Summary.Level != "unconfigured" {
		t.Fatalf("unconfigured: %+v %+v", o.Internet, o.Summary)
	}
	if len(f.logs(t)) != 0 || len(f.active(t, "network:internet")) != 0 {
		t.Fatal("unconfigured must not log or alarm")
	}

	cfg := baseCfg()
	cfg.Internet.Targets = []string{listener(t), "127.0.0.1:1"} // second: refused — still an answer
	f = newFx(t, cfg)
	f.svc.RunChecks(f.ctx)
	o = f.overview(t)
	if o.Internet.Status != StatusUp || o.Internet.LatencyMs == nil || len(o.Internet.Details.Targets) != 2 || o.Summary.Level != "ok" {
		t.Fatalf("up: %+v %+v", o.Internet, o.Summary)
	}
	// The link drops: every dial times out.
	f.svc.dial = func(ctx context.Context, _, _ string) (net.Conn, error) {
		<-ctx.Done()
		return nil, ctx.Err()
	}
	f.svc.cfg.TimeoutSec = 1
	f.svc.RunChecks(f.ctx)
	f.svc.RunChecks(f.ctx)
	o = f.overview(t)
	if o.Internet.Status != StatusDown || o.Summary.Level != "critical" || o.Summary.Title != "Нет доступа в интернет" {
		t.Fatalf("down: %+v %+v", o.Internet, o.Summary)
	}
	if inc := f.active(t, "network:internet"); len(inc) != 1 || inc[0].EntityID != nil || inc[0].Severity != monitoring.SeverityCritical {
		t.Fatalf("incident: %+v", inc)
	}
	// DNS failure is a check error, not proof the link is down.
	f.svc.dial = func(context.Context, string, string) (net.Conn, error) {
		return nil, &net.DNSError{Err: "no such host", Name: "example.invalid"}
	}
	f.svc.RunChecks(f.ctx)
	if c := f.overview(t).Internet; c.Status != StatusError || !strings.Contains(c.Reason, "DNS") {
		t.Fatalf("dns: %+v", c)
	}
	// Back: resolved, last OK updated.
	f.svc.dial = (&net.Dialer{}).DialContext
	f.svc.RunChecks(f.ctx)
	if c := f.overview(t).Internet; c.Status != StatusUp || len(f.active(t, "network:internet")) != 0 {
		t.Fatalf("recovered: %+v", c)
	}
	// Stale: no check for more than three intervals.
	f.clk.add(time.Duration(4*cfg.IntervalSec) * time.Second)
	if c := f.overview(t).Internet; !c.Stale {
		t.Fatalf("stale: %+v", c)
	}
}

func TestSecretsAreRedactedBeforeStorage(t *testing.T) {
	f := newFx(t, baseCfg())
	f.svc.settle(f.ctx, target{key: "internet", kind: "internet", name: "Интернет", severity: monitoring.SeverityCritical},
		result{status: StatusError, reason: "proxy said: password=hunter2secret token=abcdef0123456789"})
	f.svc.settle(f.ctx, target{key: "internet", kind: "internet", name: "Интернет", severity: monitoring.SeverityCritical},
		result{status: StatusError, reason: "proxy said: password=hunter2secret token=abcdef0123456789"})
	c := f.overview(t).Internet
	for _, s := range []string{"hunter2secret", "abcdef0123456789"} {
		if strings.Contains(c.Reason, s) {
			t.Fatalf("reason kept %q", s)
		}
		for _, l := range f.logs(t) {
			if strings.Contains(l.Message, s) {
				t.Fatalf("log kept %q", s)
			}
		}
		for _, i := range f.active(t, "network:internet") {
			if strings.Contains(i.LastMessage+i.Cause, s) {
				t.Fatalf("incident kept %q", s)
			}
		}
	}
}

// ---- router UPnP ----

type upnpStub struct {
	mu        sync.Mutex
	status    string
	link      string
	fault     bool
	evilCtl   bool
	actions   []string
	notFound  bool
	noWANConn bool
}

func (u *upnpStub) ServeHTTP(w http.ResponseWriter, r *http.Request) {
	u.mu.Lock()
	defer u.mu.Unlock()
	switch r.URL.Path {
	case "/rootDesc.xml":
		if u.notFound {
			http.NotFound(w, r)
			return
		}
		ctl := "/ctl/IPConn"
		if u.evilCtl {
			ctl = "http://203.0.113.5/ctl/IPConn"
		}
		conn := `<service><serviceType>urn:schemas-upnp-org:service:WANIPConnection:1</serviceType><controlURL>` + ctl + `</controlURL></service>`
		if u.noWANConn {
			conn = ""
		}
		fmt.Fprint(w, `<?xml version="1.0"?><root xmlns="urn:schemas-upnp-org:device-1-0"><device>
<deviceType>urn:schemas-upnp-org:device:InternetGatewayDevice:1</deviceType><deviceList><device>
<deviceType>urn:schemas-upnp-org:device:WANDevice:1</deviceType><serviceList><service>
<serviceType>urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1</serviceType><controlURL>/ctl/CmnIfCfg</controlURL></service></serviceList>
<deviceList><device><deviceType>urn:schemas-upnp-org:device:WANConnectionDevice:1</deviceType><serviceList>`+conn+`</serviceList></device></deviceList>
</device></deviceList></device></root>`)
	case "/ctl/IPConn", "/ctl/CmnIfCfg":
		action := r.Header.Get("SOAPAction")
		u.actions = append(u.actions, action)
		if u.fault {
			w.WriteHeader(http.StatusInternalServerError)
			fmt.Fprint(w, `<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><s:Fault/></s:Body></s:Envelope>`)
			return
		}
		var inner string
		switch {
		case strings.Contains(action, "#GetStatusInfo"):
			inner = `<u:GetStatusInfoResponse xmlns:u="urn:schemas-upnp-org:service:WANIPConnection:1"><NewConnectionStatus>` + u.status +
				`</NewConnectionStatus><NewLastConnectionError>ERROR_NONE</NewLastConnectionError><NewUptime>3600</NewUptime></u:GetStatusInfoResponse>`
		case strings.Contains(action, "#GetCommonLinkProperties"):
			inner = `<u:GetCommonLinkPropertiesResponse xmlns:u="urn:schemas-upnp-org:service:WANCommonInterfaceConfig:1"><NewWANAccessType>Ethernet</NewWANAccessType>` +
				`<NewLayer1UpstreamMaxBitRate>100000000</NewLayer1UpstreamMaxBitRate><NewLayer1DownstreamMaxBitRate>300000000</NewLayer1DownstreamMaxBitRate>` +
				`<NewPhysicalLinkStatus>` + u.link + `</NewPhysicalLinkStatus></u:GetCommonLinkPropertiesResponse>`
		default:
			w.WriteHeader(http.StatusInternalServerError)
			return
		}
		fmt.Fprint(w, `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body>`+inner+`</s:Body></s:Envelope>`)
	default:
		http.NotFound(w, r)
	}
}

func TestRouterUPnPReadOnly(t *testing.T) {
	stub := &upnpStub{status: "Connected", link: "Up"}
	srv := httptest.NewServer(stub)
	defer srv.Close()
	f := newFx(t, baseCfg())
	r := f.entity(t, "Роутер (тест)", "router", listener(t))
	other := f.entity(t, "Роутер без API (тест)", "router")
	f.svc.cfg.Routers = []config.NetRouter{{EntityID: r.ID, UPnPURL: srv.URL + "/rootDesc.xml"}}
	f.mon.CheckAll(f.ctx)
	f.svc.RunChecks(f.ctx)
	o := f.overview(t)
	var rv, nv RouterView
	for _, x := range o.Routers {
		if x.Device.EntityID == r.ID {
			rv = x
		} else if x.Device.EntityID == other.ID {
			nv = x
		}
	}
	w := rv.WAN
	if rv.Adapter != "upnp" || w == nil || w.Status != StatusUp || w.Details.Connection != "Connected" || *w.Details.DownMbps != 300 ||
		*w.Details.UptimeSec != 3600 {
		t.Fatalf("wan: %+v %+v", rv, w)
	}
	if rv.Device.Status != StatusUp || rv.Device.LatencyMs == nil {
		t.Fatalf("router reachability/latency from Monitoring: %+v", rv.Device)
	}
	if nv.Adapter != "none" || nv.WAN != nil || !strings.Contains(nv.AdapterNote, "Только доступность") || nv.Device.Status != StatusUnconfigured {
		t.Fatalf("no adapter: %+v", nv)
	}
	for _, a := range stub.actions {
		if !strings.Contains(a, "#Get") {
			t.Fatalf("non-read action %q", a)
		}
	}
	// WAN goes down by the router's own report.
	stub.mu.Lock()
	stub.status, stub.link = "Disconnected", "Down"
	stub.mu.Unlock()
	f.svc.RunChecks(f.ctx)
	f.svc.RunChecks(f.ctx)
	o = f.overview(t)
	for _, x := range o.Routers {
		if x.Device.EntityID == r.ID && (x.WAN.Status != StatusDown || !strings.Contains(x.WAN.Reason, "Disconnected")) {
			t.Fatalf("wan down: %+v", x.WAN)
		}
	}
	if o.Summary.Level != "critical" || len(f.active(t, "network:router:"+r.ID)) != 1 {
		t.Fatalf("summary/incident: %+v", o.Summary)
	}
	// SOAP fault, no description, missing service, control URL off the router.
	for name, mut := range map[string]func(*upnpStub){
		"fault":     func(u *upnpStub) { u.fault = true },
		"404":       func(u *upnpStub) { u.fault, u.notFound = false, true },
		"noservice": func(u *upnpStub) { u.notFound, u.noWANConn = false, true },
		"evil":      func(u *upnpStub) { u.noWANConn, u.evilCtl = false, true },
	} {
		stub.mu.Lock()
		mut(stub)
		stub.mu.Unlock()
		res := probeUPnP(f.ctx, f.svc.http, srv.URL+"/rootDesc.xml")
		if res.ok || res.status != StatusError {
			t.Fatalf("%s: %+v", name, res)
		}
	}
	if res := probeUPnP(f.ctx, f.svc.http, "http://203.0.113.1/rootDesc.xml"); res.status != StatusError || !strings.Contains(res.reason, "домашней сети") {
		t.Fatalf("internet address: %+v", res)
	}
}

// ---- devices and overview ----

func TestDevicesFromMonitoring(t *testing.T) {
	f := newFx(t, baseCfg())
	sw := f.entity(t, "Коммутатор (тест)", "network_device", listener(t))
	tv := f.entity(t, "ТВ без адреса (тест)", "television")
	f.mon.CheckAll(f.ctx)
	o := f.overview(t)
	if len(o.Devices) != 1 || o.Devices[0].EntityID != sw.ID || o.Devices[0].Status != StatusUp || o.Devices[0].LatencyMs == nil {
		t.Fatalf("devices: %+v", o.Devices)
	}
	if len(o.TVs) != 1 || o.TVs[0].EntityID != tv.ID || o.TVs[0].Status != StatusUnconfigured {
		t.Fatalf("tvs: %+v", o.TVs)
	}
	f.clk.add(10 * time.Minute) // Monitoring silent for long: data is stale
	if o := f.overview(t); !o.Devices[0].Stale {
		t.Fatal("stale device")
	}
	// Manual checks are rate limited.
	if err := f.svc.CheckNow(f.ctx); err != nil {
		t.Fatal(err)
	}
	if err := f.svc.CheckNow(f.ctx); !errors.Is(err, ErrTooSoon) {
		t.Fatalf("rate limit: %v", err)
	}
}

func TestConfigValidation(t *testing.T) {
	bad := []func(*config.Network){
		func(c *config.Network) { c.Internet.Targets = []string{"1.1.1.1"} },
		func(c *config.Network) { c.Internet.Targets = []string{"host:99999"} },
		func(c *config.Network) {
			c.Sunshine = []config.SunshineInstance{{ID: "a", ServerInfoURL: "http://user:pw@127.0.0.1:47989"}}
		},
		func(c *config.Network) {
			c.Sunshine = []config.SunshineInstance{{ID: "A B", ServerInfoURL: "http://127.0.0.1"}}
		},
		func(c *config.Network) {
			c.Sunshine = []config.SunshineInstance{{ID: "a", ServerInfoURL: "http://127.0.0.1"}, {ID: "a", ServerInfoURL: "http://127.0.0.1"}}
		},
		func(c *config.Network) { c.Routers = []config.NetRouter{{EntityID: "router"}} },
		func(c *config.Network) { c.TimeoutSec = 40 },
	}
	for i, m := range bad {
		c := config.DefaultNetwork()
		m(&c)
		if c.Validate() == nil {
			t.Errorf("case %d accepted", i)
		}
	}
	if err := config.DefaultNetwork().Validate(); err != nil {
		t.Fatal(err)
	}
}

func TestDeployExampleLoads(t *testing.T) {
	dir := t.TempDir()
	c, err := config.Load(filepath.Join("..", "..", "..", "..", "deploy", "core-network.example.json"),
		func(k string) (string, bool) { return dir, k == "AER_DATA_DIR" })
	if err != nil || len(c.Network.Sunshine) != 1 || len(c.Network.Internet.Targets) != 2 {
		t.Fatalf("example: %+v %v", c.Network, err)
	}
}
