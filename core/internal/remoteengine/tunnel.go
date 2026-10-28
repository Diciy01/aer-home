package remoteengine

import (
	"bufio"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
)

// Protocol is the HTTP/1.1 Upgrade token of a relay leg. After "101
// Switching Protocols" the connection is an opaque byte stream inside the
// outer TLS; what flows in it (RDP, HTTPS of the file channel) has its
// own end-to-end TLS with the host's pinned certificate.
const Protocol = "aer-tunnel/1"

// HeaderTicket carries the client leg's one-time ticket.
const HeaderTicket = "X-AER-Ticket"

// SignalGo is the byte the Gateway writes to a parked host leg when a
// client leg is paired with it: the agent then dials its local service.
const SignalGo byte = 0x01

// TunnelError is a refused upgrade (the Gateway's error envelope).
type TunnelError struct {
	Status  int
	Code    string
	Message string
}

func (e *TunnelError) Error() string {
	return fmt.Sprintf("tunnel refused: %d %s %s", e.Status, e.Code, e.Message)
}

// IsUpgrade reports whether r asks for an aer-tunnel/1 leg.
func IsUpgrade(r *http.Request) bool {
	return r.Method == http.MethodGet && strings.EqualFold(r.Header.Get("Upgrade"), Protocol) &&
		headerHasToken(r.Header, "Connection", "upgrade")
}

func headerHasToken(h http.Header, name, token string) bool {
	for _, v := range h.Values(name) {
		for _, t := range strings.Split(v, ",") {
			if strings.EqualFold(strings.TrimSpace(t), token) {
				return true
			}
		}
	}
	return false
}

// Dial opens a relay leg: an Upgrade request with the given headers
// (credential, ticket). ctx bounds only the handshake. The http.Client's
// Timeout is not applied (it would cut a long session); its Transport —
// with the pinned TLS config — is.
func Dial(ctx context.Context, hc *http.Client, url string, hdr http.Header) (io.ReadWriteCloser, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	for k, v := range hdr {
		req.Header[k] = append([]string(nil), v...)
	}
	req.Header.Set("Connection", "Upgrade")
	req.Header.Set("Upgrade", Protocol)
	var tr http.RoundTripper
	if hc != nil {
		tr = hc.Transport
	}
	res, err := (&http.Client{Transport: tr, CheckRedirect: noRedirect}).Do(req)
	if err != nil {
		return nil, err
	}
	if res.StatusCode != http.StatusSwitchingProtocols {
		defer res.Body.Close()
		te := &TunnelError{Status: res.StatusCode, Code: "UNAVAILABLE", Message: http.StatusText(res.StatusCode)}
		var env struct {
			Error *struct {
				Code    string `json:"code"`
				Message string `json:"message"`
			} `json:"error"`
		}
		if json.NewDecoder(io.LimitReader(res.Body, 64<<10)).Decode(&env) == nil && env.Error != nil {
			te.Code, te.Message = env.Error.Code, env.Error.Message
		}
		return nil, te
	}
	rwc, ok := res.Body.(io.ReadWriteCloser)
	if !ok || !strings.EqualFold(res.Header.Get("Upgrade"), Protocol) {
		res.Body.Close()
		return nil, errors.New("tunnel: server did not switch to " + Protocol)
	}
	return rwc, nil
}

func noRedirect(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }

// Accept answers an Upgrade request with 101 and takes over the
// connection. The caller owns the returned conn.
func Accept(w http.ResponseWriter) (net.Conn, error) {
	hj, ok := w.(http.Hijacker)
	if !ok {
		return nil, errors.New("tunnel: connection cannot be taken over (HTTP/2?)")
	}
	conn, brw, err := hj.Hijack()
	if err != nil {
		return nil, err
	}
	_ = conn.SetDeadline(time.Time{})
	if _, err := brw.WriteString("HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: " + Protocol + "\r\n\r\n"); err == nil {
		err = brw.Flush()
	}
	if err != nil {
		conn.Close()
		return nil, err
	}
	return &bufConn{Conn: conn, r: brw.Reader}, nil
}

// bufConn reads what the HTTP server already buffered before the takeover.
type bufConn struct {
	net.Conn
	r *bufio.Reader
}

func (c *bufConn) Read(p []byte) (int, error) { return c.r.Read(p) }

// Splice copies both ways until either side ends, an error occurs, nothing
// moves for idle (0: no limit) or stop is closed; both sides are closed.
// It returns the bytes copied a→b and b→a.
func Splice(a, b io.ReadWriteCloser, idle time.Duration, stop <-chan struct{}) (aToB, bToA int64) {
	var last atomic.Int64
	last.Store(time.Now().UnixNano())
	var once sync.Once
	done := make(chan struct{})
	closeBoth := func() {
		once.Do(func() {
			close(done)
			a.Close()
			b.Close()
		})
	}
	var wg sync.WaitGroup
	pump := func(dst io.Writer, src io.Reader, n *int64) {
		defer wg.Done()
		defer closeBoth()
		buf := make([]byte, 32<<10)
		for {
			k, err := src.Read(buf)
			if k > 0 {
				last.Store(time.Now().UnixNano())
				if _, werr := dst.Write(buf[:k]); werr != nil {
					return
				}
				atomic.AddInt64(n, int64(k))
			}
			if err != nil {
				return
			}
		}
	}
	wg.Add(2)
	go pump(b, a, &aToB)
	go pump(a, b, &bToA)
	go func() {
		var tick <-chan time.Time
		if idle > 0 {
			t := time.NewTicker(max(idle/4, 10*time.Millisecond))
			defer t.Stop()
			tick = t.C
		}
		for {
			select {
			case <-done:
				return
			case <-stop:
				closeBoth()
				return
			case <-tick:
				if time.Since(time.Unix(0, last.Load())) > idle {
					closeBoth()
					return
				}
			}
		}
	}()
	wg.Wait()
	return atomic.LoadInt64(&aToB), atomic.LoadInt64(&bToA)
}
