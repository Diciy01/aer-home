package logging

import (
	"context"
	"io"
	"log/slog"
	"strings"
	"testing"
)

func TestSinkForwardsWarnings(t *testing.T) {
	base, _ := New(io.Discard, "debug", "text")
	s := NewSink(2)
	l := Module(WithSink(base, s), "registry")
	l.Info("not forwarded")
	l.Warn("disk slow", "path", "/data")
	l.ErrorContext(Quiet(context.Background()), "from the consumer itself")
	l.Error("second")
	l.Error("third — buffer full")
	r := <-s.Records()
	if r.Message != "disk slow" || r.Source != "core.registry" || r.Level != slog.LevelWarn || !strings.Contains(string(r.Fields), "/data") {
		t.Fatalf("%+v", r)
	}
	if r2 := <-s.Records(); r2.Message != "second" {
		t.Fatalf("%+v", r2)
	}
	if s.Dropped() != 1 {
		t.Fatalf("dropped %d", s.Dropped())
	}
}
