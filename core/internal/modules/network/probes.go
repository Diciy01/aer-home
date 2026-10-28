package network

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/xml"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"strings"
	"syscall"
	"time"
)

// result is what one probe found out (before failure confirmation).
type result struct {
	ok      bool
	status  Status // when !ok: down (no answer) or error (answer we cannot use)
	reason  string
	latency *time.Duration
	details *Details
}

func ms(d *time.Duration) *float64 {
	if d == nil {
		return nil
	}
	v := float64(d.Microseconds()) / 1000
	return &v
}

func shortErr(err error) string {
	var dns *net.DNSError
	switch {
	case err == nil:
		return "нет ответа"
	case errors.Is(err, errTLS):
		return "TCP принят, но TLS не установлен — вероятно, соединение принял локальный VPN/прокси, а не сервер"
	case errors.As(err, &dns):
		return "имя не разрешается (DNS)"
	case errors.Is(err, context.DeadlineExceeded), strings.Contains(err.Error(), "timeout"):
		return "тайм-аут"
	case errors.Is(err, syscall.ECONNREFUSED):
		return "соединение отклонено"
	case errors.Is(err, syscall.EHOSTUNREACH):
		return "хост недостижим"
	case errors.Is(err, syscall.ENETUNREACH):
		return "нет маршрута в сеть"
	case errors.Is(err, syscall.ECONNRESET):
		return "соединение сброшено"
	}
	return "сетевая ошибка"
}

// Dialer abstracts TCP connects (tests use the real loopback anyway).
type Dialer func(ctx context.Context, network, addr string) (net.Conn, error)

// splitTarget: "tls://host:port" or "host:443" → TLS handshake; "tcp://…"
// or another port → TCP connect only.
func splitTarget(t string) (addr string, useTLS bool) {
	switch {
	case strings.HasPrefix(t, "tls://"):
		return strings.TrimPrefix(t, "tls://"), true
	case strings.HasPrefix(t, "tcp://"):
		return strings.TrimPrefix(t, "tcp://"), false
	}
	_, port, _ := net.SplitHostPort(t)
	return t, port == "443"
}

// reach proves one target. A TCP accept alone can come from a local VPN or
// transparent proxy (TUN) that answers for every address, so TLS targets
// must also finish a handshake — only a real server on the far side can.
// The certificate is not verified (nothing is sent; IPs have no name).
func reach(ctx context.Context, dial Dialer, target string) (time.Duration, error) {
	addr, useTLS := splitTarget(target)
	start := time.Now()
	c, err := dial(ctx, "tcp", addr)
	if err != nil {
		return 0, err
	}
	defer c.Close()
	if !useTLS {
		return time.Since(start), nil
	}
	host, _, _ := net.SplitHostPort(addr)
	cfg := &tls.Config{MinVersion: tls.VersionTLS12, InsecureSkipVerify: true} //nolint:gosec // liveness only
	if net.ParseIP(host) == nil {
		cfg.ServerName = host
	}
	tc := tls.Client(c, cfg)
	if dl, ok := ctx.Deadline(); ok {
		_ = c.SetDeadline(dl)
	}
	if err := tc.HandshakeContext(ctx); err != nil {
		return 0, errTLS
	}
	return time.Since(start), nil
}

var errTLS = errors.New("tls handshake failed")

// probeInternet: the link works if any explicit target answers. For TCP
// targets a refused connection is an answer from the remote host.
func probeInternet(ctx context.Context, dial Dialer, targets []string, timeout time.Duration) result {
	if len(targets) == 0 {
		return result{status: StatusUnconfigured, reason: "Не настроено: укажите цели network.internet.targets в конфигурации Core"}
	}
	type one struct {
		i   int
		err error
		d   time.Duration
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	ch := make(chan one, len(targets))
	for i, t := range targets {
		go func() {
			d, err := reach(ctx, dial, t)
			ch <- one{i, err, d}
		}()
	}
	res := make([]TargetResult, len(targets))
	var best *time.Duration
	dnsOnly := true
	for range targets {
		o := <-ch
		r := TargetResult{Target: targets[o.i]}
		_, isTLS := splitTarget(targets[o.i])
		if o.err == nil || (!isTLS && errors.Is(o.err, syscall.ECONNREFUSED)) {
			d := o.d
			r.OK, r.LatencyMs = true, ms(&d)
			if best == nil || d < *best {
				best = &d
			}
		} else {
			r.Error = shortErr(o.err)
			var dns *net.DNSError
			dnsOnly = dnsOnly && errors.As(o.err, &dns)
		}
		res[o.i] = r
	}
	det := &Details{Targets: res}
	if best != nil {
		return result{ok: true, reason: fmt.Sprintf("Интернет доступен: ответили %d из %d целей", countOK(res), len(res)), latency: best, details: det}
	}
	if dnsOnly {
		return result{status: StatusError, reason: "Имена целей не разрешаются (DNS) — проверка не смогла дойти до интернета", details: det}
	}
	return result{status: StatusDown, reason: "Ни одна цель не ответила: " + res[0].Error, details: det}
}

func countOK(r []TargetResult) int {
	n := 0
	for _, x := range r {
		if x.OK {
			n++
		}
	}
	return n
}

// lanHost accepts only literal private, loopback or link-local IPs: the
// read-only adapters must never be pointed at the internet.
func lanHost(u *url.URL) bool {
	ip := net.ParseIP(u.Hostname())
	return ip != nil && (ip.IsPrivate() || ip.IsLoopback() || ip.IsLinkLocalUnicast())
}

func readLimited(r io.Reader, n int64) ([]byte, error) {
	b, err := io.ReadAll(io.LimitReader(r, n+1))
	if int64(len(b)) > n {
		return nil, errors.New("ответ слишком большой")
	}
	return b, err
}

// ---- Sunshine (GameStream serverinfo, unauthenticated HTTP) ----

// serverInfo reads only these fields; hostname, MAC, LocalIP and uniqueid
// are present in the reply but never parsed or stored.
type serverInfo struct {
	XMLName     xml.Name `xml:"root"`
	StatusCode  string   `xml:"status_code,attr"`
	State       string   `xml:"state"`
	AppVersion  string   `xml:"appversion"`
	CurrentGame string   `xml:"currentgame"`
}

func serverInfoURL(base string) string {
	u, _ := url.Parse(base)
	if !strings.HasSuffix(u.Path, "/serverinfo") {
		u.Path = strings.TrimRight(u.Path, "/") + "/serverinfo"
	}
	return u.String()
}

func probeSunshine(ctx context.Context, client *http.Client, dial Dialer, infoURL, webURL string) result {
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, serverInfoURL(infoURL), nil)
	req.Header.Set("User-Agent", "AER-HOME-network/1")
	start := time.Now()
	resp, err := client.Do(req)
	if err != nil {
		if errors.Is(err, syscall.ECONNREFUSED) {
			return result{status: StatusDown, reason: "Sunshine не отвечает: порт закрыт (сервер не запущен?)"}
		}
		return result{status: StatusDown, reason: "Sunshine не отвечает: " + shortErr(err)}
	}
	defer resp.Body.Close()
	took := time.Since(start)
	det := &Details{}
	if webURL != "" {
		det.WebReachable = webReachable(ctx, dial, webURL)
	}
	switch {
	case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
		return result{status: StatusError, latency: &took, details: det,
			reason: fmt.Sprintf("Сервер ответил HTTP %d: serverinfo требует авторизацию — проверьте адрес (нужен HTTP-порт GameStream, обычно 47989)", resp.StatusCode)}
	case resp.StatusCode != http.StatusOK:
		return result{status: StatusError, latency: &took, details: det, reason: fmt.Sprintf("Неожиданный ответ HTTP %d", resp.StatusCode)}
	}
	body, err := readLimited(resp.Body, 64<<10)
	var si serverInfo
	if err == nil {
		err = xml.Unmarshal(body, &si)
	}
	if err != nil || si.State == "" {
		return result{status: StatusError, latency: &took, details: det, reason: "Ответ не похож на Sunshine serverinfo (нет поля state)"}
	}
	if si.StatusCode != "" && si.StatusCode != "200" {
		return result{status: StatusError, latency: &took, details: det, reason: "Sunshine вернул status_code " + si.StatusCode}
	}
	busy := strings.HasSuffix(si.State, "_BUSY")
	det.Streaming, det.Version = &busy, si.AppVersion
	if n, err := strconv.Atoi(strings.TrimSpace(si.CurrentGame)); err == nil {
		det.CurrentApp = &n
	}
	reason := "Sunshine работает, стрима нет"
	if busy {
		reason = "Sunshine работает, идёт стрим"
	}
	return result{ok: true, reason: reason, latency: &took, details: det}
}

// webReachable: TCP connect to the web UI port (no TLS, no credentials).
func webReachable(ctx context.Context, dial Dialer, raw string) *bool {
	u, err := url.Parse(raw)
	if err != nil {
		return nil
	}
	port := u.Port()
	if port == "" {
		port = map[string]string{"https": "443", "http": "80"}[u.Scheme]
	}
	c, err := dial(ctx, "tcp", net.JoinHostPort(u.Hostname(), port))
	ok := err == nil
	if ok {
		c.Close()
	}
	return &ok
}

// ---- Router: UPnP IGD (read-only Get* actions only) ----

const (
	svcWANIP     = "urn:schemas-upnp-org:service:WANIPConnection:"
	svcWANPPP    = "urn:schemas-upnp-org:service:WANPPPConnection:"
	svcWANCommon = "urn:schemas-upnp-org:service:WANCommonInterfaceConfig:"
)

type upnpService struct {
	Type    string `xml:"serviceType"`
	Control string `xml:"controlURL"`
}

// collectServices walks the description (devices nest) for <service>.
func collectServices(body []byte) (services []upnpService, base string, err error) {
	dec := xml.NewDecoder(bytes.NewReader(body))
	for {
		tok, err := dec.Token()
		if err == io.EOF {
			return services, base, nil
		}
		if err != nil {
			return nil, "", err
		}
		se, ok := tok.(xml.StartElement)
		if !ok {
			continue
		}
		switch se.Name.Local {
		case "URLBase":
			var v string
			if err := dec.DecodeElement(&v, &se); err == nil {
				base = strings.TrimSpace(v)
			}
		case "service":
			var s upnpService
			if err := dec.DecodeElement(&s, &se); err == nil {
				services = append(services, s)
			}
		}
	}
}

func soapCall(ctx context.Context, client *http.Client, control, service, action string, out any) error {
	body := `<?xml version="1.0"?><s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" ` +
		`s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/"><s:Body><u:` + action + ` xmlns:u="` + service +
		`"></u:` + action + `></s:Body></s:Envelope>`
	req, _ := http.NewRequestWithContext(ctx, http.MethodPost, control, strings.NewReader(body))
	req.Header.Set("Content-Type", `text/xml; charset="utf-8"`)
	req.Header.Set("SOAPAction", `"`+service+`#`+action+`"`)
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	b, err := readLimited(resp.Body, 64<<10)
	if err != nil {
		return err
	}
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("%s: HTTP %d", action, resp.StatusCode)
	}
	var env struct {
		Body struct {
			Inner []byte `xml:",innerxml"`
		} `xml:"Body"`
	}
	if err := xml.Unmarshal(b, &env); err != nil {
		return fmt.Errorf("%s: некорректный SOAP-ответ", action)
	}
	wrapped := append(append([]byte("<x>"), env.Body.Inner...), "</x>"...)
	return xml.Unmarshal(wrapped, out)
}

func probeUPnP(ctx context.Context, client *http.Client, descURL string) result {
	du, err := url.Parse(descURL)
	if err != nil || !lanHost(du) {
		return result{status: StatusError, reason: "Адрес UPnP должен быть IP-адресом домашней сети"}
	}
	req, _ := http.NewRequestWithContext(ctx, http.MethodGet, descURL, nil)
	resp, err := client.Do(req)
	if err != nil {
		return result{status: StatusDown, reason: "Описание UPnP недоступно: " + shortErr(err)}
	}
	body, err := readLimited(resp.Body, 256<<10)
	resp.Body.Close()
	if resp.StatusCode != http.StatusOK || err != nil {
		return result{status: StatusError, reason: fmt.Sprintf("Описание UPnP: HTTP %d (UPnP выключен на роутере или другой адрес)", resp.StatusCode)}
	}
	services, base, err := collectServices(body)
	if err != nil {
		return result{status: StatusError, reason: "Описание UPnP не разобрано (некорректный XML)"}
	}
	root := du
	if base != "" {
		if b, err := url.Parse(base); err == nil {
			root = b
		}
	}
	resolve := func(c string) (string, bool) {
		u, err := root.Parse(c)
		if err != nil || u.Hostname() != du.Hostname() || !lanHost(u) {
			return "", false
		}
		return u.String(), true
	}
	var conn, common upnpService
	for _, s := range services {
		switch {
		case conn.Type == "" && (strings.HasPrefix(s.Type, svcWANIP) || strings.HasPrefix(s.Type, svcWANPPP)):
			conn = s
		case common.Type == "" && strings.HasPrefix(s.Type, svcWANCommon):
			common = s
		}
	}
	if conn.Type == "" {
		return result{status: StatusError, reason: "Роутер не предоставляет WANIPConnection/WANPPPConnection по UPnP"}
	}
	ctl, ok := resolve(conn.Control)
	if !ok {
		return result{status: StatusError, reason: "Адрес управления UPnP указывает за пределы роутера — отклонено"}
	}
	start := time.Now()
	var st struct {
		Status string `xml:"GetStatusInfoResponse>NewConnectionStatus"`
		Uptime string `xml:"GetStatusInfoResponse>NewUptime"`
	}
	if err := soapCall(ctx, client, ctl, conn.Type, "GetStatusInfo", &st); err != nil {
		return result{status: StatusError, reason: "UPnP GetStatusInfo: " + err.Error()}
	}
	took := time.Since(start)
	det := &Details{Connection: st.Status}
	if n, err := strconv.ParseInt(strings.TrimSpace(st.Uptime), 10, 64); err == nil {
		det.UptimeSec = &n
	}
	if common.Type != "" {
		if c, ok := resolve(common.Control); ok {
			var lp struct {
				Link string `xml:"GetCommonLinkPropertiesResponse>NewPhysicalLinkStatus"`
				Up   string `xml:"GetCommonLinkPropertiesResponse>NewLayer1UpstreamMaxBitRate"`
				Down string `xml:"GetCommonLinkPropertiesResponse>NewLayer1DownstreamMaxBitRate"`
			}
			if soapCall(ctx, client, c, common.Type, "GetCommonLinkProperties", &lp) == nil {
				det.PhysicalLink = lp.Link
				if v, err := strconv.ParseFloat(lp.Up, 64); err == nil && v > 0 {
					m := v / 1e6
					det.UpMbps = &m
				}
				if v, err := strconv.ParseFloat(lp.Down, 64); err == nil && v > 0 {
					m := v / 1e6
					det.DownMbps = &m
				}
			}
		}
	}
	switch {
	case st.Status == "Connected" && det.PhysicalLink != "Down":
		return result{ok: true, reason: "WAN подключён (по данным роутера, UPnP)", latency: &took, details: det}
	case st.Status == "":
		return result{status: StatusError, reason: "UPnP не сообщил состояние WAN", details: det}
	}
	return result{status: StatusDown, reason: "WAN по данным роутера: " + st.Status + linkNote(det.PhysicalLink), latency: &took, details: det}
}

func linkNote(l string) string {
	if l == "" {
		return ""
	}
	return ", линия: " + l
}
