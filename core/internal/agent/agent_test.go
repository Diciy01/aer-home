package agent

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"
)

func TestParseProcStatAndCPU(t *testing.T) {
	a, err := ParseProcStat("cpu  100 0 100 700 100 0 0 0 0 0\ncpu0 1 2 3 4")
	if err != nil || a.Total != 1000 || a.Idle != 800 {
		t.Fatalf("%+v %v", a, err)
	}
	b, _ := ParseProcStat("cpu  150 0 150 800 100 0 0 0 0 0")
	if p, ok := CPUPercent(a, b); !ok || p != 50 {
		t.Fatalf("cpu %% = %v", p)
	}
	if _, ok := CPUPercent(b, b); ok {
		t.Fatal("no time passed → no value")
	}
}

func TestParseMeminfoNetDevMountsOSRelease(t *testing.T) {
	m := ParseMeminfo("MemTotal:       16000 kB\nMemAvailable:    4000 kB\nVmRSS:\t  9000 kB\n")
	if m["MemTotal"] != 16000*1024 || m["VmRSS"] != 9000*1024 {
		t.Fatalf("%v", m)
	}
	nd := ParseNetDev(`Inter-|   Receive
 face |bytes    packets errs drop fifo frame compressed multicast|bytes    packets errs drop fifo colls carrier compressed
    lo: 100 1 0 0 0 0 0 0 100 1 0 0 0 0 0 0
  eth0: 5000 10 1 2 0 0 0 0 7000 9 3 4 0 0 0 0
veth12: 1 1 0 0 0 0 0 0 1 1 0 0 0 0 0 0`)
	if len(nd) != 1 || nd["eth0"].RX != 5000 || nd["eth0"].TX != 7000 || nd["eth0"].Errors != 10 {
		t.Fatalf("%+v", nd)
	}
	mp := ParseMounts("/dev/a / ext4 rw 0 0\nproc /proc proc rw 0 0\n/dev/b /mnt/My\\040Disk ntfs3 rw 0 0\n/dev/loop0 /snap/x squashfs ro 0 0\ntmpfs /run tmpfs rw 0 0\n")
	if strings.Join(mp, "|") != "/|/mnt/My Disk" {
		t.Fatalf("%v", mp)
	}
	if ParseOSRelease("NAME=x\nPRETTY_NAME=\"Ubuntu 24.04 LTS\"\n") != "Ubuntu 24.04 LTS" {
		t.Fatal("os-release")
	}
}

func TestParseJournal(t *testing.T) {
	in := `{"MESSAGE":"disk error","PRIORITY":"3","__REALTIME_TIMESTAMP":"1761566400000000","_SYSTEMD_UNIT":"smartd.service","__CURSOR":"c1"}
{"MESSAGE":"info line","PRIORITY":"6","__REALTIME_TIMESTAMP":"1761566400000000","__CURSOR":"c2"}
{"MESSAGE":[1,2,3],"PRIORITY":"2","__CURSOR":"c3"}
{"MESSAGE":"kernel oops","PRIORITY":"2","__REALTIME_TIMESTAMP":"1761566401000000","_TRANSPORT":"kernel","__CURSOR":"c4"}
not json`
	got := ParseJournalJSON(in)
	if len(got) != 2 || got[0].Line.Level != "error" || got[0].Line.Source != "journal/smartd.service" || got[1].Line.Level != "critical" || got[1].Cursor != "c4" {
		t.Fatalf("%+v", got)
	}
}

func TestParseWindowsFormats(t *testing.T) {
	sc := "SERVICE_NAME: Spooler\r\n        TYPE               : 110  WIN32_OWN_PROCESS\r\n        STATE              : 4  RUNNING\r\n"
	if r, st, err := ParseSCQuery(sc); err != nil || !r || st != "RUNNING" {
		t.Fatalf("%v %s %v", r, st, err)
	}
	if r, _, _ := ParseSCQuery("STATE : 1  STOPPED"); r {
		t.Fatal("stopped")
	}
	if _, _, err := ParseSCQuery("[SC] OpenService FAILED 1060"); err == nil {
		t.Fatal("missing service must be an error")
	}
	xmlIn := `<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="disk"/><EventID>7</EventID><Level>2</Level>
<TimeCreated SystemTime="2026-10-27T10:00:00.000000000Z"/><EventRecordID>1500</EventRecordID><Channel>System</Channel></System>
<RenderingInfo Culture="ru-RU"><Message>Устройство \Device\Harddisk0 имеет плохой блок.</Message></RenderingInfo></Event>
<Event xmlns="http://schemas.microsoft.com/win/2004/08/events/event"><System><Provider Name="x"/><EventID>1</EventID><Level>4</Level>
<TimeCreated SystemTime="2026-10-27T10:00:01Z"/><EventRecordID>1501</EventRecordID><Channel>System</Channel></System></Event>`
	lines, maxID, err := ParseWevtutilXML(xmlIn)
	if err != nil || len(lines) != 1 || maxID != 1500 || lines[0].Level != "error" || !strings.Contains(lines[0].Message, "плохой блок") {
		t.Fatalf("%+v %d %v", lines, maxID, err)
	}
	r := ParseNvidiaSMI("37, 61\n5, 40\n")
	if len(r) != 2 || r[0].Util != 37 || r[0].Temp != 61 {
		t.Fatalf("%+v", r)
	}
}

// fakeCore records reports and can be switched off or set to reject.
type fakeCore struct {
	mu      sync.Mutex
	down    bool
	reject  bool
	reports []Report
	auth    []string
}

func (f *fakeCore) handler(w http.ResponseWriter, r *http.Request) {
	f.mu.Lock()
	defer f.mu.Unlock()
	if f.down {
		w.WriteHeader(http.StatusServiceUnavailable)
		return
	}
	if f.reject {
		w.WriteHeader(http.StatusUnauthorized)
		return
	}
	f.auth = append(f.auth, r.Header.Get("Authorization"))
	var rep Report
	_ = json.NewDecoder(r.Body).Decode(&rep)
	f.reports = append(f.reports, rep)
	_, _ = w.Write([]byte(`{"data":{}}`))
}

type staticSource struct{ n int }

func (staticSource) Name() string { return "static" }
func (s staticSource) Collect(now time.Time) ([]Sample, []LogLine) {
	var out []Sample
	for i := 0; i < s.n; i++ {
		out = append(out, measured("cpu.usage", "", float64(i), now))
	}
	return out, []LogLine{{At: now, Level: "warning", Message: "w"}}
}

func newTestAgent(t *testing.T, url string, queue int) *Agent {
	t.Helper()
	tok := filepath.Join(t.TempDir(), "agent.token")
	if err := os.WriteFile(tok, []byte("aer1.11111111-1111-4111-8111-111111111111."+strings.Repeat("ab", 32)+"\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	cfg := DefaultConfig()
	cfg.CoreURL, cfg.TokenFile, cfg.QueueSamples, cfg.QueueLogs = url, tok, queue, 10
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	return New(cfg, []Source{staticSource{n: 40}}, func() Info { return Info{Version: Version, OS: "test"} }, nil)
}

func TestQueueBoundedReconnectAndDroppedCounts(t *testing.T) {
	fc := &fakeCore{down: true}
	hs := httptest.NewServer(http.HandlerFunc(fc.handler))
	defer hs.Close()
	a := newTestAgent(t, hs.URL, 100)
	for i := 0; i < 5; i++ { // Core down: keep collecting
		a.Collect()
		if err := a.Flush(context.Background()); err == nil {
			t.Fatal("send must fail while Core is down")
		}
	}
	s, l, ds, dl := a.Queued()
	if s != 100 || l != 5 || ds != 100 || dl != 0 {
		t.Fatalf("bounded queue: samples=%d logs=%d dropped=%d/%d", s, l, ds, dl)
	}
	fc.mu.Lock()
	fc.down = false
	fc.mu.Unlock()
	if err := a.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if s, _, ds, _ := a.Queued(); s != 0 || ds != 0 {
		t.Fatalf("flushed: %d %d", s, ds)
	}
	if len(fc.reports) != 1 || fc.reports[0].Dropped.Samples != 100 || len(fc.reports[0].Samples) != 100 {
		t.Fatalf("report: %d reports, dropped %d", len(fc.reports), fc.reports[0].Dropped.Samples)
	}
	if !strings.HasPrefix(fc.auth[0], "Bearer aer1.") {
		t.Fatal("token goes in the Authorization header")
	}
	fc.mu.Lock()
	fc.reject = true
	fc.mu.Unlock()
	a.Collect()
	if err := a.Flush(context.Background()); !errors.Is(err, errRejected) {
		t.Fatalf("revoked credential: %v", err)
	}
}

func TestLargeQueueIsSentInChunks(t *testing.T) {
	fc := &fakeCore{}
	hs := httptest.NewServer(http.HandlerFunc(fc.handler))
	defer hs.Close()
	a := newTestAgent(t, hs.URL, 5000)
	for i := 0; i < 60; i++ {
		a.Collect()
	}
	if err := a.Flush(context.Background()); err != nil {
		t.Fatal(err)
	}
	if len(fc.reports) != 3 || len(fc.reports[0].Samples) != 1000 {
		t.Fatalf("2400 samples → 3 chunks, got %d", len(fc.reports))
	}
}

func TestConfigValidation(t *testing.T) {
	c := DefaultConfig()
	c.TokenFile = "/x"
	c.CoreURL = "http://user:pass@core:8787"
	if c.Validate() == nil {
		t.Fatal("credentials in URL must be rejected")
	}
	c.CoreURL = "http://192.0.2.10:8787"
	if c.Validate() != nil || !c.insecureRemote() {
		t.Fatal("plain HTTP to LAN is allowed with a warning")
	}
	c.CoreURL = "http://127.0.0.1:8787"
	if c.insecureRemote() {
		t.Fatal("loopback is fine")
	}
	c.IntervalSec = 1
	if c.Validate() == nil {
		t.Fatal("interval bounds")
	}
}
