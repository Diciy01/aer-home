package remotegw

import (
	"context"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

// legKey addresses the host legs of one session channel.
type legKey struct{ session, channel string }

// hostLeg is a parked host agent connection waiting for a client leg.
type hostLeg struct {
	conn   net.Conn
	entity string
	// watcher state: a read that returns before pairing means the agent
	// went away; stopWatch unblocks it at pairing.
	gone      chan struct{}
	watchDone chan struct{}
	taking    atomic.Bool
	early     []byte
}

// watch notices a parked leg that closed, spoke out of turn or stayed
// unused past its deadline. Only this goroutine closes gone.
func (l *hostLeg) watch(onGone func()) {
	defer close(l.watchDone)
	buf := make([]byte, 1)
	n, err := l.conn.Read(buf)
	if l.taking.Load() && n == 0 && isTimeout(err) {
		return // taken over for pairing
	}
	if n > 0 && l.taking.Load() {
		l.early = append(l.early, buf[:n]...)
		return
	}
	close(l.gone)
	onGone()
}

func isTimeout(err error) bool {
	ne, ok := err.(net.Error)
	return ok && ne.Timeout()
}

// takeOver stops the watcher; false when the leg is already gone.
func (l *hostLeg) takeOver() bool {
	l.taking.Store(true)
	_ = l.conn.SetReadDeadline(time.Unix(1, 0))
	<-l.watchDone
	select {
	case <-l.gone:
		return false
	default:
	}
	_ = l.conn.SetReadDeadline(time.Time{})
	return true
}

// Read returns watcher bytes first (never expected in practice).
func (l *hostLeg) Read(p []byte) (int, error) {
	if len(l.early) > 0 {
		n := copy(p, l.early)
		l.early = l.early[n:]
		return n, nil
	}
	return l.conn.Read(p)
}
func (l *hostLeg) Write(p []byte) (int, error) { return l.conn.Write(p) }
func (l *hostLeg) Close() error                { return l.conn.Close() }

var _ io.ReadWriteCloser = (*hostLeg)(nil)

// hub pairs client legs with parked host legs.
type hub struct {
	mu     sync.Mutex
	legs   map[legKey][]*hostLeg
	notify map[legKey]chan struct{}
}

func newHub() *hub {
	return &hub{legs: map[legKey][]*hostLeg{}, notify: map[legKey]chan struct{}{}}
}

// parked counts the waiting legs of a session channel.
func (h *hub) parked(k legKey) int {
	h.mu.Lock()
	defer h.mu.Unlock()
	return len(h.legs[k])
}

// park adds a host leg; it is dropped (and closed) when it goes away or
// stays unused past ttl.
func (h *hub) park(k legKey, l *hostLeg, ttl time.Duration) {
	l.gone, l.watchDone = make(chan struct{}), make(chan struct{})
	_ = l.conn.SetReadDeadline(time.Now().Add(ttl))
	h.mu.Lock()
	h.legs[k] = append(h.legs[k], l)
	if ch := h.notify[k]; ch != nil {
		close(ch)
		delete(h.notify, k)
	}
	h.mu.Unlock()
	go l.watch(func() {
		h.remove(k, l)
		l.conn.Close()
	})
}

func (h *hub) remove(k legKey, l *hostLeg) bool {
	h.mu.Lock()
	defer h.mu.Unlock()
	list := h.legs[k]
	for i, x := range list {
		if x == l {
			h.legs[k] = append(list[:i], list[i+1:]...)
			if len(h.legs[k]) == 0 {
				delete(h.legs, k)
			}
			return true
		}
	}
	return false
}

// take waits (until ctx ends) for a live parked host leg and removes it.
func (h *hub) take(ctx context.Context, k legKey) *hostLeg {
	for {
		h.mu.Lock()
		var l *hostLeg
		if list := h.legs[k]; len(list) > 0 {
			l = list[0]
			h.legs[k] = list[1:]
			if len(h.legs[k]) == 0 {
				delete(h.legs, k)
			}
		}
		var ch chan struct{}
		if l == nil {
			ch = h.notify[k]
			if ch == nil {
				ch = make(chan struct{})
				h.notify[k] = ch
			}
		}
		h.mu.Unlock()
		if l != nil {
			if l.takeOver() {
				return l
			}
			continue // went away meanwhile; try the next one
		}
		select {
		case <-ch:
		case <-ctx.Done():
			return nil
		}
	}
}

// dropSession closes every parked leg of the sessions not in keep.
func (h *hub) dropExcept(keep map[string]bool) {
	h.mu.Lock()
	var drop []*hostLeg
	for k, list := range h.legs {
		if !keep[k.session] {
			drop = append(drop, list...)
			delete(h.legs, k)
		}
	}
	h.mu.Unlock()
	for _, l := range drop {
		l.conn.Close()
	}
}

// sessions lists sessions with parked legs.
func (h *hub) sessions() []string {
	h.mu.Lock()
	defer h.mu.Unlock()
	seen := map[string]bool{}
	out := []string{}
	for k := range h.legs {
		if !seen[k.session] {
			seen[k.session] = true
			out = append(out, k.session)
		}
	}
	return out
}

// closeAll closes every parked leg.
func (h *hub) closeAll() { h.dropExcept(map[string]bool{}) }
