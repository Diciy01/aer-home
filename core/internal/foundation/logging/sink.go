package logging

import (
	"context"
	"encoding/json"
	"log/slog"
	"sync/atomic"
	"time"
)

// Record is a Core log record forwarded to the centralized log (M05).
type Record struct {
	At      time.Time
	Level   slog.Level
	Source  string
	Message string
	Fields  json.RawMessage
}

// Sink forwards warning+ records to a consumer set later (the Monitoring
// module). Forwarding never blocks: when the buffer is full, records are
// dropped and counted. Records produced while consuming are not forwarded
// again (no feedback loop).
type Sink struct {
	ch      chan Record
	dropped atomic.Int64
}

// NewSink creates a sink with a bounded buffer.
func NewSink(buffer int) *Sink { return &Sink{ch: make(chan Record, buffer)} }

// Records is consumed by exactly one reader.
func (s *Sink) Records() <-chan Record { return s.ch }

// Dropped counts records lost to a full buffer.
func (s *Sink) Dropped() int64 { return s.dropped.Load() }

type sinkHandler struct {
	inner  slog.Handler
	sink   *Sink
	attrs  []slog.Attr
	groups []string
}

// WithSink wraps l so that records at Warn and above are also sent to s.
func WithSink(l *slog.Logger, s *Sink) *slog.Logger {
	return slog.New(&sinkHandler{inner: l.Handler(), sink: s})
}

type quietKey struct{}

// Quiet marks a context whose log records must not be forwarded (used by
// the consumer itself).
func Quiet(ctx context.Context) context.Context { return context.WithValue(ctx, quietKey{}, true) }

func (h *sinkHandler) Enabled(ctx context.Context, l slog.Level) bool { return h.inner.Enabled(ctx, l) }

func (h *sinkHandler) Handle(ctx context.Context, r slog.Record) error {
	err := h.inner.Handle(ctx, r)
	if r.Level < slog.LevelWarn || ctx.Value(quietKey{}) != nil {
		return err
	}
	fields := map[string]any{}
	source := "core"
	add := func(a slog.Attr) {
		if a.Key == "module" {
			source = "core." + a.Value.String()
			return
		}
		fields[a.Key] = a.Value.String()
	}
	for _, a := range h.attrs {
		add(a)
	}
	r.Attrs(func(a slog.Attr) bool { add(a); return true })
	raw, _ := json.Marshal(fields)
	select {
	case h.sink.ch <- Record{At: r.Time, Level: r.Level, Source: source, Message: r.Message, Fields: raw}:
	default:
		h.sink.dropped.Add(1)
	}
	return err
}

func (h *sinkHandler) WithAttrs(as []slog.Attr) slog.Handler {
	return &sinkHandler{inner: h.inner.WithAttrs(as), sink: h.sink, attrs: append(append([]slog.Attr(nil), h.attrs...), as...), groups: h.groups}
}

func (h *sinkHandler) WithGroup(name string) slog.Handler {
	return &sinkHandler{inner: h.inner.WithGroup(name), sink: h.sink, attrs: h.attrs, groups: append(h.groups, name)}
}
