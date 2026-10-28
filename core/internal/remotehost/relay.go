package remotehost

import (
	"context"
	"io"
	"net"
	"net/http"
	"net/url"
	"strconv"
	"sync"
	"time"

	"aerhome/core/internal/remoteengine"
)

// Relay legs (ADR-017): for a session that comes through the Gateway the
// agent parks outgoing aer-tunnel/1 legs; when the Gateway pairs one with
// a client it sends SignalGo, the agent connects the leg to the local
// service (RDP or the file channel on 127.0.0.1) and parks the next leg.
// The host needs no inbound port for these sessions.

const maxSplicedLegs = 4

func (a *Agent) gatewayClient() *http.Client {
	tr := http.DefaultTransport.(*http.Transport).Clone()
	tr.ForceAttemptHTTP2 = false
	if a.cfg.GatewayCertSHA256 != "" {
		tr.TLSClientConfig = remoteengine.PinnedTLS(a.cfg.GatewayCertSHA256)
	}
	return &http.Client{Transport: tr}
}

// relay keeps one parked leg for (session, channel) until ctx ends.
func (a *Agent) relay(ctx context.Context, sessionID, channel string, localPort int) {
	hc := a.gatewayClient()
	u := a.cfg.GatewayURL + "/gw/v1/agent/tunnel?" + url.Values{"session": {sessionID}, "channel": {channel}}.Encode()
	local := net.JoinHostPort("127.0.0.1", strconv.Itoa(localPort))
	var active sync.WaitGroup
	slots := make(chan struct{}, maxSplicedLegs)
	backoff := time.Second
	defer active.Wait()
	for ctx.Err() == nil {
		select {
		case slots <- struct{}{}:
		case <-ctx.Done():
			return
		}
		leg, err := a.park(ctx, hc, u)
		if err != nil {
			<-slots
			if ctx.Err() != nil {
				return
			}
			a.log.Warn("relay leg", "channel", channel, "err", err)
			select {
			case <-ctx.Done():
				return
			case <-time.After(backoff):
			}
			backoff = min(2*backoff, 10*time.Second)
			continue
		}
		backoff = time.Second
		active.Add(1)
		go func() {
			defer active.Done()
			defer func() { <-slots }()
			a.serveLeg(ctx, leg, local)
		}()
		// Next leg only once this one was paired (or failed): serveLeg
		// signals by returning from the wait below.
		if !leg.wait(ctx) {
			continue
		}
	}
}

// parkedLeg is a dialled leg; paired is closed once the Gateway signalled.
type parkedLeg struct {
	rwc    io.ReadWriteCloser
	paired chan bool
}

func (l *parkedLeg) wait(ctx context.Context) bool {
	select {
	case ok := <-l.paired:
		return ok
	case <-ctx.Done():
		return false
	}
}

func (a *Agent) park(ctx context.Context, hc *http.Client, u string) (*parkedLeg, error) {
	tok, err := a.token()
	if err != nil {
		return nil, err
	}
	dctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	rwc, err := remoteengine.Dial(dctx, hc, u, http.Header{"Authorization": {"Bearer " + tok}})
	if err != nil {
		return nil, err
	}
	return &parkedLeg{rwc: rwc, paired: make(chan bool, 1)}, nil
}

// serveLeg waits for SignalGo, then splices the leg with the local service.
func (a *Agent) serveLeg(ctx context.Context, leg *parkedLeg, local string) {
	stop := make(chan struct{})
	go func() {
		select {
		case <-ctx.Done():
			leg.rwc.Close()
		case <-stop:
		}
	}()
	defer close(stop)
	b := make([]byte, 1)
	if _, err := io.ReadFull(leg.rwc, b); err != nil || b[0] != remoteengine.SignalGo {
		leg.rwc.Close()
		leg.paired <- false // parked leg expired or the Gateway closed it: park again
		return
	}
	leg.paired <- true
	d := net.Dialer{Timeout: 5 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", local)
	if err != nil {
		a.log.Warn("relay: local service", "addr", local, "err", err)
		leg.rwc.Close()
		return
	}
	remoteengine.Splice(leg.rwc, conn, 0, ctx.Done())
}
