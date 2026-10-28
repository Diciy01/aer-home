package remotegw

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net"
	"net/http"
	"net/url"
	"os"
	"regexp"
	"strings"
	"sync"
	"time"

	"aerhome/core/internal/remoteengine"
)

// Version of the Gateway.
const Version = "0.1.0"

// Gateway is the running AER Remote Gateway.
type Gateway struct {
	cfg  Config
	log  *slog.Logger
	core *http.Client
	lim  *limiter
	hub  *hub
	now  func() time.Time

	mu         sync.Mutex
	tunnels    map[*tunnel]struct{}
	coreLostAt time.Time
}

type tunnel struct {
	session, channel, client string
	stop                     chan struct{}
	once                     sync.Once
}

func (t *tunnel) close() { t.once.Do(func() { close(t.stop) }) }

// New builds a Gateway for a validated config (certificate is created
// when needed).
func New(cfg Config, log *slog.Logger) (*Gateway, error) {
	if log == nil {
		log = slog.New(slog.DiscardHandler)
	}
	if err := EnsureCert(&cfg); err != nil {
		return nil, fmt.Errorf("tls certificate: %w", err)
	}
	g := &Gateway{cfg: cfg, log: log, core: &http.Client{Timeout: 40 * time.Second}, hub: newHub(), now: time.Now,
		tunnels: map[*tunnel]struct{}{}}
	g.lim = newLimiter(cfg, func() time.Time { return g.now() })
	return g, nil
}

// TLSConfig is the server TLS configuration (HTTP/1.1 only: tunnels need
// connection takeover).
func (g *Gateway) TLSConfig() (*tls.Config, error) {
	cert, err := tls.LoadX509KeyPair(g.cfg.TLSCert, g.cfg.TLSKey)
	if err != nil {
		return nil, err
	}
	return &tls.Config{MinVersion: tls.VersionTLS12, Certificates: []tls.Certificate{cert}, NextProtos: []string{"http/1.1"}}, nil
}

// Fingerprint of the Gateway certificate (what clients pin).
func (g *Gateway) Fingerprint() (string, error) {
	raw, err := os.ReadFile(g.cfg.TLSCert)
	if err != nil {
		return "", err
	}
	return remoteengine.FingerprintPEM(string(raw))
}

// Server returns the HTTP server (callers run ServeTLS / Serve on a TLS listener).
func (g *Gateway) Server() (*http.Server, error) {
	tc, err := g.TLSConfig()
	if err != nil {
		return nil, err
	}
	return &http.Server{Addr: g.cfg.ListenAddr, Handler: g.Handler(), TLSConfig: tc,
		TLSNextProto:      map[string]func(*http.Server, *tls.Conn, http.Handler){},
		ReadHeaderTimeout: 10 * time.Second, IdleTimeout: 90 * time.Second, MaxHeaderBytes: 16 << 10,
		ErrorLog: slog.NewLogLogger(g.log.Handler(), slog.LevelDebug)}, nil
}

// Run serves until ctx ends, then closes every tunnel.
func (g *Gateway) Run(ctx context.Context) error {
	srv, err := g.Server()
	if err != nil {
		return err
	}
	ln, err := net.Listen("tcp", g.cfg.ListenAddr)
	if err != nil {
		return err
	}
	go g.Maintain(ctx)
	errc := make(chan error, 1)
	go func() { errc <- srv.Serve(tls.NewListener(ln, srv.TLSConfig)) }()
	select {
	case <-ctx.Done():
	case err := <-errc:
		return err
	}
	sctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	_ = srv.Shutdown(sctx)
	g.closeAll()
	return nil
}

func (g *Gateway) closeAll() {
	g.mu.Lock()
	for t := range g.tunnels {
		t.close()
	}
	g.mu.Unlock()
	g.hub.closeAll()
}

// Maintain closes tunnels of ended sessions, all tunnels when Core is
// lost for too long, and forgets stale limiter entries.
func (g *Gateway) Maintain(ctx context.Context) {
	t := time.NewTicker(time.Duration(g.cfg.AliveCheckSec) * time.Second)
	defer t.Stop()
	report := time.NewTicker(time.Minute)
	defer report.Stop()
	g.ReportInfo(ctx)
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
			g.CheckAlive(ctx)
			g.lim.gc()
		case <-report.C:
			g.ReportInfo(ctx)
		}
	}
}

// ReportInfo tells Core the Gateway's certificate fingerprint and version
// (shown to the owner for comparison at pairing).
func (g *Gateway) ReportInfo(ctx context.Context) {
	fp, err := g.Fingerprint()
	if err != nil {
		return
	}
	if _, _, err := g.coreCall(ctx, http.MethodPost, "/remote/gw/info", map[string]string{"certSha256": fp, "version": Version}, nil, nil); err != nil {
		g.log.Warn("report to core", "err", err)
	}
}

// CheckAlive asks Core which tunnelled sessions are still running.
func (g *Gateway) CheckAlive(ctx context.Context) {
	g.mu.Lock()
	ids := map[string]bool{}
	for t := range g.tunnels {
		ids[t.session] = true
	}
	g.mu.Unlock()
	for _, s := range g.hub.sessions() {
		ids[s] = true
	}
	if len(ids) == 0 {
		return
	}
	list := make([]string, 0, len(ids))
	for id := range ids {
		list = append(list, id)
	}
	var res struct {
		Active []string `json:"active"`
	}
	st, _, err := g.coreCall(ctx, http.MethodPost, "/remote/gw/alive", map[string]any{"sessions": list}, nil, &res)
	if err != nil || st != http.StatusOK {
		g.mu.Lock()
		if g.coreLostAt.IsZero() {
			g.coreLostAt = g.now()
		}
		lost := g.now().Sub(g.coreLostAt) > time.Duration(g.cfg.CoreLossSec)*time.Second
		g.mu.Unlock()
		if lost {
			g.log.Warn("core unreachable: closing all tunnels")
			g.closeAll()
		}
		return
	}
	keep := map[string]bool{}
	for _, id := range res.Active {
		keep[id] = true
	}
	g.mu.Lock()
	g.coreLostAt = time.Time{}
	for t := range g.tunnels {
		if !keep[t.session] {
			g.log.Info("tunnel closed: session ended", "session", t.session)
			t.close()
		}
	}
	g.mu.Unlock()
	g.hub.dropExcept(keep)
}

// ---- Core client ----

func (g *Gateway) token() (string, error) {
	b, err := os.ReadFile(g.cfg.TokenFile)
	return strings.TrimSpace(string(b)), err
}

// coreCall calls Core's API with the Gateway credential and returns the
// status and the raw data or error object.
func (g *Gateway) coreCall(ctx context.Context, method, path string, body any, hdr http.Header, out any) (int, json.RawMessage, error) {
	tok, err := g.token()
	if err != nil {
		return 0, nil, fmt.Errorf("gateway credential: %w", err)
	}
	var rd io.Reader
	if body != nil {
		b, _ := json.Marshal(body)
		rd = bytes.NewReader(b)
	}
	req, err := http.NewRequestWithContext(ctx, method, strings.TrimRight(g.cfg.CoreURL, "/")+"/api/v1"+path, rd)
	if err != nil {
		return 0, nil, err
	}
	for k, v := range hdr {
		req.Header[k] = v
	}
	req.Header.Set("Authorization", "Bearer "+tok)
	req.Header.Set("Content-Type", "application/json")
	res, err := g.core.Do(req)
	if err != nil {
		return 0, nil, err
	}
	defer res.Body.Close()
	var env struct {
		Data  json.RawMessage `json:"data"`
		Error json.RawMessage `json:"error"`
	}
	if err := json.NewDecoder(io.LimitReader(res.Body, 4<<20)).Decode(&env); err != nil {
		return res.StatusCode, nil, fmt.Errorf("core %s: HTTP %d", path, res.StatusCode)
	}
	if res.StatusCode >= 300 {
		return res.StatusCode, env.Error, nil
	}
	if out != nil {
		if err := json.Unmarshal(env.Data, out); err != nil {
			return res.StatusCode, nil, err
		}
	}
	return res.StatusCode, env.Data, nil
}

// ---- HTTP ----

const apiPrefix = "/gw/v1"

// Handler serves the public Gateway API.
func (g *Gateway) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("GET "+apiPrefix+"/health", g.health)
	mux.HandleFunc("POST "+apiPrefix+"/pair", g.pair)
	mux.HandleFunc("GET "+apiPrefix+"/hosts", g.forward(http.MethodGet, "/remote/gw/client/hosts"))
	mux.HandleFunc("POST "+apiPrefix+"/sessions", g.forward(http.MethodPost, "/remote/gw/client/sessions"))
	mux.HandleFunc("GET "+apiPrefix+"/sessions/{id}", g.forward(http.MethodGet, "/remote/gw/client/sessions/{id}"))
	mux.HandleFunc("POST "+apiPrefix+"/sessions/{id}/grant", g.forward(http.MethodPost, "/remote/gw/client/sessions/{id}/grant"))
	mux.HandleFunc("POST "+apiPrefix+"/sessions/{id}/tickets", g.forward(http.MethodPost, "/remote/gw/client/sessions/{id}/tickets"))
	mux.HandleFunc("POST "+apiPrefix+"/sessions/{id}/end", g.forward(http.MethodPost, "/remote/gw/client/sessions/{id}/end"))
	mux.HandleFunc("GET "+apiPrefix+"/tunnel", g.clientTunnel)
	mux.HandleFunc("GET "+apiPrefix+"/agent/tunnel", g.hostTunnel)
	if g.cfg.AgentProxy {
		mux.HandleFunc(apiPrefix+"/agent/api/v1/", g.agentProxy)
	}
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Cache-Control", "no-store")
		w.Header().Set("X-Content-Type-Options", "nosniff")
		if g.lim.Banned(addrOf(r)) {
			writeErr(w, http.StatusTooManyRequests, "UNAVAILABLE", "Слишком много неудачных попыток — повторите позже")
			return
		}
		mux.ServeHTTP(w, r)
	})
}

func addrOf(r *http.Request) string {
	h, _, err := net.SplitHostPort(r.RemoteAddr)
	if err != nil {
		return r.RemoteAddr
	}
	return h
}

func writeErr(w http.ResponseWriter, status int, code, msg string) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"error": map[string]string{"code": code, "message": msg}})
}

func writeRaw(w http.ResponseWriter, status int, key string, raw json.RawMessage) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	if len(raw) == 0 {
		raw = json.RawMessage("null")
	}
	_ = json.NewEncoder(w).Encode(map[string]json.RawMessage{key: raw})
}

func (g *Gateway) health(w http.ResponseWriter, r *http.Request) {
	writeRaw(w, http.StatusOK, "data", json.RawMessage(`{"status":"ok","service":"aer-remote-gateway"}`))
}

// bearer extracts the caller's credential.
func bearer(r *http.Request) string {
	t, _ := strings.CutPrefix(r.Header.Get("Authorization"), "Bearer ")
	return strings.TrimSpace(t)
}

// clientID is the id part of aerc1.<id>.<secret> (after Core accepted it).
func clientID(cred string) string {
	parts := strings.SplitN(cred, ".", 3)
	if len(parts) != 3 {
		return ""
	}
	return parts[1]
}

// relay answers with Core's status/data/error; 401 counts as a failure.
func (g *Gateway) relay(w http.ResponseWriter, r *http.Request, st int, raw json.RawMessage, err error) {
	if err != nil {
		g.log.Warn("core call failed", "path", r.URL.Path, "err", err)
		writeErr(w, http.StatusBadGateway, "UNAVAILABLE", "AER Core недоступен")
		return
	}
	if st == http.StatusUnauthorized {
		if g.lim.Fail(addrOf(r)) {
			g.log.Warn("address banned after failed authentication", "addr", addrOf(r))
		}
	}
	key := "data"
	if st >= 300 {
		key = "error"
	}
	writeRaw(w, st, key, raw)
}

func readBody(w http.ResponseWriter, r *http.Request) (any, bool) {
	if r.Method != http.MethodPost {
		return nil, true
	}
	raw, err := io.ReadAll(http.MaxBytesReader(w, r.Body, 64<<10))
	if err != nil {
		writeErr(w, http.StatusRequestEntityTooLarge, "PAYLOAD_TOO_LARGE", "Слишком большой запрос")
		return nil, false
	}
	if len(bytes.TrimSpace(raw)) == 0 {
		return map[string]any{}, true
	}
	if !json.Valid(raw) {
		writeErr(w, http.StatusBadRequest, "BAD_REQUEST", "Некорректный JSON")
		return nil, false
	}
	return json.RawMessage(raw), true
}

var idRe = regexp.MustCompile(`^[A-Za-z0-9-]{1,64}$`)

// forward sends a client request to Core with the client's credential.
func (g *Gateway) forward(method, corePath string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		cred := bearer(r)
		if cred == "" {
			g.lim.Fail(addrOf(r))
			writeErr(w, http.StatusUnauthorized, "UNAUTHORIZED", "Нужны учётные данные клиента")
			return
		}
		path := corePath
		if strings.Contains(path, "{id}") {
			id := r.PathValue("id")
			if !idRe.MatchString(id) {
				writeErr(w, http.StatusNotFound, "NOT_FOUND", "Не найдено")
				return
			}
			path = strings.Replace(path, "{id}", url.PathEscape(id), 1)
		}
		body, ok := readBody(w, r)
		if !ok {
			return
		}
		hdr := http.Header{"X-Aer-Remote-Client": {cred}, "X-Aer-Client-Addr": {addrOf(r)}}
		if k := r.Header.Get("Idempotency-Key"); k != "" {
			hdr.Set("Idempotency-Key", k)
		}
		st, raw, err := g.coreCall(r.Context(), method, path, body, hdr, nil)
		g.relay(w, r, st, raw, err)
	}
}

func (g *Gateway) pair(w http.ResponseWriter, r *http.Request) {
	if !g.lim.Pair(addrOf(r)) {
		writeErr(w, http.StatusTooManyRequests, "UNAVAILABLE", "Слишком много попыток сопряжения — повторите позже")
		return
	}
	body, ok := readBody(w, r)
	if !ok {
		return
	}
	st, raw, err := g.coreCall(r.Context(), http.MethodPost, "/remote/gw/pair", body, http.Header{"X-Aer-Client-Addr": {addrOf(r)}}, nil)
	if err == nil && st == http.StatusOK {
		g.log.Info("client paired", "addr", addrOf(r))
	}
	g.relay(w, r, st, raw, err)
}

// ---- tunnels ----

func (g *Gateway) countTunnels(client string) (total, mine int) {
	g.mu.Lock()
	defer g.mu.Unlock()
	for t := range g.tunnels {
		total++
		if t.client == client {
			mine++
		}
	}
	return
}

func (g *Gateway) event(sessionID, kind, msg string) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_, _, _ = g.coreCall(ctx, http.MethodPost, "/remote/gw/tunnel/event", map[string]string{"sessionId": sessionID, "kind": kind, "message": msg}, nil, nil)
}

// clientTunnel: a client leg with credential + one-time ticket.
func (g *Gateway) clientTunnel(w http.ResponseWriter, r *http.Request) {
	if !remoteengine.IsUpgrade(r) {
		writeErr(w, http.StatusUpgradeRequired, "BAD_REQUEST", "Нужен Upgrade: "+remoteengine.Protocol)
		return
	}
	cred, tk := bearer(r), strings.TrimSpace(r.Header.Get(remoteengine.HeaderTicket))
	if cred == "" || tk == "" || len(tk) > 128 {
		g.lim.Fail(addrOf(r))
		writeErr(w, http.StatusUnauthorized, "UNAUTHORIZED", "Нужны учётные данные клиента и билет")
		return
	}
	total, mine := g.countTunnels(clientID(cred))
	if total >= g.cfg.MaxTunnels || mine >= g.cfg.MaxTunnelsPerClient {
		writeErr(w, http.StatusServiceUnavailable, "UNAVAILABLE", "Достигнут предел одновременных туннелей")
		return
	}
	var claim struct {
		SessionID string `json:"sessionId"`
		Channel   string `json:"channel"`
	}
	st, raw, err := g.coreCall(r.Context(), http.MethodPost, "/remote/gw/tunnel/claim", map[string]string{"ticket": tk},
		http.Header{"X-Aer-Remote-Client": {cred}, "X-Aer-Client-Addr": {addrOf(r)}}, &claim)
	if err != nil || st != http.StatusOK {
		if st == http.StatusForbidden {
			g.lim.Fail(addrOf(r)) // bad tickets count like bad credentials
		}
		g.relay(w, r, st, raw, err)
		return
	}
	ctx, cancel := context.WithTimeout(r.Context(), time.Duration(g.cfg.PairWaitSec)*time.Second)
	host := g.hub.take(ctx, legKey{claim.SessionID, claim.Channel})
	cancel()
	if host == nil {
		g.event(claim.SessionID, "tunnel_refused", "Хост не подключился к Gateway вовремя ("+claim.Channel+")")
		writeErr(w, http.StatusGatewayTimeout, "UNAVAILABLE", "Компьютер не подключился к Gateway вовремя")
		return
	}
	if _, err := host.Write([]byte{remoteengine.SignalGo}); err != nil {
		host.Close()
		writeErr(w, http.StatusBadGateway, "UNAVAILABLE", "Соединение с компьютером прервалось")
		return
	}
	conn, err := remoteengine.Accept(w)
	if err != nil {
		host.Close()
		return
	}
	t := &tunnel{session: claim.SessionID, channel: claim.Channel, client: clientID(cred), stop: make(chan struct{})}
	g.mu.Lock()
	g.tunnels[t] = struct{}{}
	g.mu.Unlock()
	g.log.Info("tunnel opened", "session", t.session, "channel", t.channel, "addr", addrOf(r))
	g.event(t.session, "tunnel_opened", fmt.Sprintf("Туннель «%s» открыт с адреса %s", t.channel, addrOf(r)))
	up, down := remoteengine.Splice(conn, host, time.Duration(g.cfg.IdleTimeoutSec)*time.Second, t.stop)
	g.mu.Lock()
	delete(g.tunnels, t)
	g.mu.Unlock()
	g.log.Info("tunnel closed", "session", t.session, "channel", t.channel, "up", up, "down", down)
	g.event(t.session, "tunnel_closed", fmt.Sprintf("Туннель «%s» закрыт: к хосту %d Б, от хоста %d Б", t.channel, up, down))
}

// hostTunnel: a host agent parks a leg for its own relay session.
func (g *Gateway) hostTunnel(w http.ResponseWriter, r *http.Request) {
	if !remoteengine.IsUpgrade(r) {
		writeErr(w, http.StatusUpgradeRequired, "BAD_REQUEST", "Нужен Upgrade: "+remoteengine.Protocol)
		return
	}
	cred := bearer(r)
	session, channel := r.URL.Query().Get("session"), r.URL.Query().Get("channel")
	if cred == "" || !idRe.MatchString(session) || !remoteengine.ValidChannel(channel) {
		g.lim.Fail(addrOf(r))
		writeErr(w, http.StatusUnauthorized, "UNAUTHORIZED", "Нужны учётные данные агента, сеанс и канал")
		return
	}
	k := legKey{session, channel}
	if g.hub.parked(k) >= g.cfg.MaxParkedPerSession {
		writeErr(w, http.StatusTooManyRequests, "CONFLICT", "Уже ожидают подключения")
		return
	}
	var claim struct {
		EntityID string `json:"entityId"`
	}
	st, raw, err := g.coreCall(r.Context(), http.MethodPost, "/remote/gw/tunnel/host", map[string]string{"sessionId": session, "channel": channel},
		http.Header{"X-Aer-Remote-Agent": {cred}}, &claim)
	if err != nil || st != http.StatusOK {
		g.relay(w, r, st, raw, err)
		return
	}
	conn, err := remoteengine.Accept(w)
	if err != nil {
		return
	}
	g.hub.park(k, &hostLeg{conn: conn, entity: claim.EntityID}, time.Duration(g.cfg.ParkTimeoutSec)*time.Second)
}

// agentProxyPaths: the only Core paths a host agent may reach through the
// Gateway (its credential is checked by Core itself).
var agentProxyPaths = []*regexp.Regexp{
	regexp.MustCompile(`^POST /api/v1/remote/agent/hello$`),
	regexp.MustCompile(`^GET /api/v1/remote/agent/commands$`),
	regexp.MustCompile(`^POST /api/v1/remote/agent/sessions/[A-Za-z0-9-]{1,64}/events$`),
	regexp.MustCompile(`^POST /api/v1/monitoring/agent/report$`),
}

var waitRe = regexp.MustCompile(`^[0-9]{1,2}$`)

func (g *Gateway) agentProxy(w http.ResponseWriter, r *http.Request) {
	path := "/api/v1/" + strings.TrimPrefix(r.URL.Path, apiPrefix+"/agent/api/v1/")
	allowed := false
	for _, re := range agentProxyPaths {
		if re.MatchString(r.Method + " " + path) {
			allowed = true
			break
		}
	}
	if !allowed || bearer(r) == "" {
		writeErr(w, http.StatusNotFound, "NOT_FOUND", "Не найдено")
		return
	}
	q := ""
	if r.URL.Path == apiPrefix+"/agent/api/v1/remote/agent/commands" {
		if wait := r.URL.Query().Get("wait"); waitRe.MatchString(wait) {
			q = "?wait=" + wait
		}
	}
	req, err := http.NewRequestWithContext(r.Context(), r.Method, strings.TrimRight(g.cfg.CoreURL, "/")+path+q,
		http.MaxBytesReader(w, r.Body, 256<<10))
	if err != nil {
		writeErr(w, http.StatusBadRequest, "BAD_REQUEST", "Некорректный запрос")
		return
	}
	req.Header.Set("Authorization", r.Header.Get("Authorization"))
	req.Header.Set("Content-Type", "application/json")
	res, err := g.core.Do(req)
	if err != nil {
		writeErr(w, http.StatusBadGateway, "UNAVAILABLE", "AER Core недоступен")
		return
	}
	defer res.Body.Close()
	if res.StatusCode == http.StatusUnauthorized {
		g.lim.Fail(addrOf(r))
	}
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(res.StatusCode)
	_, _ = io.Copy(w, io.LimitReader(res.Body, 4<<20))
}
