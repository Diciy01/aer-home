package remotegw

import (
	"context"
	"io"
	"net"
	"testing"
	"time"
)

func TestHubParkTakeExpire(t *testing.T) {
	h := newHub()
	k := legKey{"s1", "rdp"}

	// Nothing parked: take gives up when ctx ends.
	ctx, cancel := context.WithTimeout(context.Background(), 50*time.Millisecond)
	if h.take(ctx, k) != nil {
		t.Fatal("took a leg from nowhere")
	}
	cancel()

	// A parked leg is handed to a waiting client.
	a, b := net.Pipe()
	got := make(chan *hostLeg, 1)
	go func() { got <- h.take(context.Background(), k) }()
	time.Sleep(20 * time.Millisecond)
	h.park(k, &hostLeg{conn: a}, time.Minute)
	l := <-got
	if l == nil || h.parked(k) != 0 {
		t.Fatal("waiting take did not get the parked leg")
	}
	go func() { _, _ = b.Write([]byte("x")) }()
	buf := make([]byte, 1)
	if _, err := io.ReadFull(l, buf); err != nil || buf[0] != 'x' {
		t.Fatalf("leg unusable after takeover: %v", err)
	}
	l.Close()

	// The agent hangs up while parked: the leg disappears.
	c, d := net.Pipe()
	h.park(k, &hostLeg{conn: c}, time.Minute)
	d.Close()
	deadline := time.Now().Add(2 * time.Second)
	for h.parked(k) != 0 && time.Now().Before(deadline) {
		time.Sleep(10 * time.Millisecond)
	}
	if h.parked(k) != 0 {
		t.Fatal("dead parked leg kept")
	}

	// Unused past its TTL: closed, so the agent parks a fresh one.
	e, f := net.Pipe()
	h.park(k, &hostLeg{conn: e}, 50*time.Millisecond)
	if _, err := f.Read(buf); err == nil {
		t.Fatal("expired parked leg not closed")
	}
	if h.parked(k) != 0 {
		t.Fatal("expired leg still listed")
	}

	// Ending a session drops its parked legs only.
	g1, g2 := net.Pipe()
	o1, o2 := net.Pipe()
	defer g2.Close()
	defer o2.Close()
	h.park(k, &hostLeg{conn: g1}, time.Minute)
	other := legKey{"s2", "rdp"}
	h.park(other, &hostLeg{conn: o1}, time.Minute)
	h.dropExcept(map[string]bool{"s2": true})
	if h.parked(k) != 0 || h.parked(other) != 1 {
		t.Fatalf("dropExcept: %d %d", h.parked(k), h.parked(other))
	}
}
