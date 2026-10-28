package remotehost

import (
	"net"
	"runtime"
	"strconv"
	"testing"
	"time"
)

// Real loopback connections (IPv4 and, when available, IPv6) are counted on
// the listening side only, and drop back to zero when closed.
func TestEstablishedCountsRealConnections(t *testing.T) {
	if runtime.GOOS != "linux" && runtime.GOOS != "windows" {
		t.Skip("no TCP table reader on " + runtime.GOOS)
	}
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer ln.Close()
	port := ln.Addr().(*net.TCPAddr).Port
	var ln6 net.Listener
	if l, err := net.Listen("tcp", net.JoinHostPort("::1", strconv.Itoa(port))); err == nil {
		ln6 = l
		defer ln6.Close()
	}
	if n := established(port); n != 0 {
		t.Fatalf("idle port: %d", n)
	}
	var conns []net.Conn
	dial := func(addr string, l net.Listener) {
		c, err := net.Dial("tcp", addr)
		if err != nil {
			t.Fatal(err)
		}
		s, err := l.Accept()
		if err != nil {
			t.Fatal(err)
		}
		conns = append(conns, c, s)
	}
	dial(ln.Addr().String(), ln)
	dial(ln.Addr().String(), ln)
	want := 2
	if ln6 != nil {
		dial(ln6.Addr().String(), ln6)
		want = 3
	}
	if n := waitCount(port, want); n != want {
		t.Fatalf("established(%d) = %d, want %d", port, n, want)
	}
	for _, c := range conns {
		c.Close()
	}
	if n := waitCount(port, 0); n != 0 {
		t.Fatalf("after close: %d", n)
	}
}

func waitCount(port, want int) int {
	n := established(port)
	for i := 0; i < 50 && n != want; i++ {
		time.Sleep(20 * time.Millisecond)
		n = established(port)
	}
	return n
}
