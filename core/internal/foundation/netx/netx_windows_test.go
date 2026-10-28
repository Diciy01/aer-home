package netx

import (
	"bufio"
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"testing"
	"time"

	"golang.org/x/sys/windows"
)

// servePipe answers one HTTP request on a fresh named pipe, like the Docker
// Engine does on \\.\pipe\docker_engine.
func servePipe(t *testing.T, name string) {
	t.Helper()
	p, _ := windows.UTF16PtrFromString(name)
	h, err := windows.CreateNamedPipe(p, windows.PIPE_ACCESS_DUPLEX,
		windows.PIPE_TYPE_BYTE|windows.PIPE_READMODE_BYTE|windows.PIPE_WAIT, 1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	go func() {
		f := os.NewFile(uintptr(h), name)
		defer f.Close()
		if err := windows.ConnectNamedPipe(h, nil); err != nil && err != windows.ERROR_PIPE_CONNECTED {
			return
		}
		req, err := http.ReadRequest(bufio.NewReader(f))
		if err != nil {
			return
		}
		body := `{"path":"` + req.URL.Path + `"}`
		fmt.Fprintf(f, "HTTP/1.1 200 OK\r\nContent-Length: %d\r\nConnection: close\r\n\r\n%s", len(body), body)
	}()
}

func TestDialPipeHTTP(t *testing.T) {
	name := fmt.Sprintf(`%saer-netx-test-%d`, PipePrefix, os.Getpid())
	servePipe(t, name)
	tr := &http.Transport{DialContext: func(ctx context.Context, _, _ string) (net.Conn, error) {
		return DialLocal(ctx, name)
	}}
	c := &http.Client{Transport: tr, Timeout: 5 * time.Second}
	resp, err := c.Get("http://docker/v1.41/version")
	if err != nil {
		t.Fatal(err)
	}
	defer resp.Body.Close()
	b, _ := io.ReadAll(resp.Body)
	if string(b) != `{"path":"/v1.41/version"}` {
		t.Fatalf("body %q", b)
	}
}

func TestPipeDeadline(t *testing.T) {
	name := fmt.Sprintf(`%saer-netx-silent-%d`, PipePrefix, os.Getpid())
	p, _ := windows.UTF16PtrFromString(name)
	h, err := windows.CreateNamedPipe(p, windows.PIPE_ACCESS_DUPLEX, windows.PIPE_TYPE_BYTE|windows.PIPE_WAIT, 1, 4096, 4096, 0, nil)
	if err != nil {
		t.Fatal(err)
	}
	defer windows.CloseHandle(h)
	c, err := DialLocal(context.Background(), name)
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	c.SetReadDeadline(time.Now().Add(100 * time.Millisecond))
	start := time.Now()
	if _, err := c.Read(make([]byte, 1)); err == nil {
		t.Fatal("read from a silent pipe returned data")
	}
	if d := time.Since(start); d > 3*time.Second {
		t.Fatalf("deadline ignored: %s", d)
	}
}
