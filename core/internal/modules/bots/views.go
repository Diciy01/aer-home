package bots

import (
	"context"
	"errors"
	"slices"
	"strings"
	"time"

	"aerhome/core/internal/modules/monitoring"
	"aerhome/core/internal/modules/registry"
)

// ListFilter selects bots for the list view.
type ListFilter struct {
	Query    string
	Status   string
	Runtime  string
	Category string
	Archived string // "false" (default) | "true" | "all"
}

// listTTL: concurrent clients and polls within this window share one
// computed list (SQLite has one connection; a list costs ~1 ms per bot).
const listTTL = 2 * time.Second

type listEntry struct {
	at   time.Time
	bots []Bot
	err  error
	done chan struct{}
}

// List returns bots with their live state. The base list per archive mode
// is computed once per listTTL (single flight); filters apply on top.
func (s *Service) List(ctx context.Context, f ListFilter) ([]Bot, error) {
	mode := f.Archived
	if mode != "true" && mode != "all" {
		mode = "false"
	}
	base, err := s.baseList(ctx, mode)
	if err != nil {
		return nil, err
	}
	q := strings.ToLower(strings.TrimSpace(f.Query))
	out := []Bot{}
	for _, b := range base {
		switch {
		case f.Runtime != "" && b.Runtime != f.Runtime,
			f.Category != "" && !strings.EqualFold(b.Category, f.Category),
			f.Status != "" && string(b.Status) != f.Status,
			q != "" && !matches(q, b):
			continue
		}
		out = append(out, b)
	}
	return out, nil
}

func (s *Service) baseList(ctx context.Context, mode string) ([]Bot, error) {
	s.mu.Lock()
	if e := s.lists[mode]; e != nil {
		s.mu.Unlock()
		<-e.done
		if e.err == nil && s.now().Sub(e.at) < listTTL {
			return e.bots, nil
		}
		s.mu.Lock()
		if s.lists[mode] == e {
			delete(s.lists, mode)
		}
		if again := s.lists[mode]; again != nil { // another caller already started a fresh one
			s.mu.Unlock()
			<-again.done
			return again.bots, again.err
		}
	}
	e := &listEntry{done: make(chan struct{})}
	s.lists[mode] = e
	s.mu.Unlock()
	e.bots, e.err = s.computeList(ctx, registry.ArchivedFilter(mode))
	e.at = s.now()
	close(e.done)
	return e.bots, e.err
}

// invalidateList drops cached lists after a change made through Bots.
func (s *Service) invalidateList() {
	s.mu.Lock()
	for k, e := range s.lists {
		select {
		case <-e.done:
			delete(s.lists, k)
		default: // in flight: it will be refreshed on the next TTL check
		}
	}
	s.mu.Unlock()
}

func (s *Service) computeList(ctx context.Context, mode registry.ArchivedFilter) ([]Bot, error) {
	cs, err := s.configs(ctx, "")
	if err != nil {
		return nil, err
	}
	// One Registry listing instead of a Get per bot.
	entities := map[string]registry.Entity{}
	for offset := 0; ; offset += 200 {
		p, err := s.reg.List(ctx, registry.ListFilter{Types: BotTypes, Archived: mode, Limit: 200, Offset: offset})
		if err != nil {
			return nil, err
		}
		for _, e := range p.Items {
			entities[e.ID] = e
		}
		if len(p.Items) < 200 {
			break
		}
	}
	out := []Bot{}
	for _, c := range cs {
		e, ok := entities[c.EntityID]
		if !ok {
			continue // other archive mode, or deleted outside Bots (orphaned config)
		}
		b, err := s.view(ctx, e, c, false)
		if err != nil {
			return nil, err
		}
		out = append(out, b)
	}
	return out, nil
}

func matches(q string, b Bot) bool {
	hay := strings.ToLower(strings.Join(append([]string{b.Name, b.Description, b.Type, b.Category, b.Runtime, b.Notes}, b.Tags...), " "))
	for _, term := range strings.Fields(q) {
		if !strings.Contains(hay, term) {
			return false
		}
	}
	return true
}

// Get returns the full bot page.
func (s *Service) Get(ctx context.Context, id string) (Detail, error) {
	c, err := s.config(ctx, id)
	if err != nil {
		return Detail{}, err
	}
	e, err := s.reg.Get(ctx, id)
	if errors.Is(err, registry.ErrNotFound) {
		return Detail{}, ErrNotFound
	}
	if err != nil {
		return Detail{}, err
	}
	b, err := s.view(ctx, e, c, true)
	if err != nil {
		return Detail{}, err
	}
	d := Detail{Bot: b, Dependencies: []EntityRef{}, Crashes: []monitoring.Incident{}, Restarts: []monitoring.Event{}}
	if rels, err := s.reg.Relations(ctx, id); err == nil {
		for _, r := range rels {
			if r.Direction != "outgoing" || r.Kind != "depends_on" {
				continue
			}
			d.Dependencies = append(d.Dependencies, s.ref(ctx, r.Peer, r.Kind))
		}
	}
	if p, err := s.mon.Incidents(ctx, monitoring.IncidentFilter{EntityID: id, Limit: 50}); err == nil {
		for _, in := range p.Items {
			for _, pre := range []string{"availability:", "bot_process:", "container:", "n8n_failed:", "bot_api:"} {
				if strings.HasPrefix(in.Key, pre) {
					d.Crashes = append(d.Crashes, in)
					break
				}
			}
		}
		if len(d.Crashes) > 20 {
			d.Crashes = d.Crashes[:20]
		}
	}
	if ev, err := s.mon.EventsOfKinds(ctx, id, []string{"bot_restarted", "bot_started", "bot_stopped", "bot_crashed", "container_state"}, 30); err == nil {
		d.Restarts = ev
	}
	d.Actions = s.actionsFor(&d.Bot)
	d.Integration = s.integration(&d.Bot)
	return d, nil
}

func (s *Service) ref(ctx context.Context, p registry.EntitySummary, kind string) EntityRef {
	r := EntityRef{ID: p.ID, Name: p.Name, Type: p.Type, Relation: kind, Status: monitoring.StatusUnknown}
	if st, err := s.mon.State(ctx, p.ID); err == nil {
		r.Status, r.Reason = st.Status, st.Reason
	}
	return r
}

// view joins Registry, the config, Monitoring state, the runtime adapter and jobs.
func (s *Service) view(ctx context.Context, e registry.Entity, c Config, full bool) (Bot, error) {
	now := s.now().UTC()
	b := Bot{Config: c, Name: e.Name, Type: e.Type, Description: e.Description, Tags: e.Tags, Archived: e.Archived,
		EntityRevision: e.Revision, Status: monitoring.StatusUnknown}
	if b.Tags == nil {
		b.Tags = []string{}
	}
	st, err := s.mon.State(ctx, e.ID)
	if err != nil && !errors.Is(err, monitoring.ErrEntityMissing) {
		return b, err
	}
	b.Status, b.StatusReason, b.LastContactAt, b.OpenIncidents = st.Status, st.Reason, st.LastContactAt, st.OpenIncidents
	b.Heartbeat = HeartbeatInfo{IntervalSec: c.HeartbeatIntervalSec, TimeoutSec: c.HeartbeatTimeoutSec}
	var newest *monitoring.Agent
	for i := range st.Agents {
		a := &st.Agents[i]
		if a.RevokedAt != nil {
			continue
		}
		b.Heartbeat.Credentials++
		if a.LastSeenAt != nil && (b.Heartbeat.LastSeenAt == nil || a.LastSeenAt.After(*b.Heartbeat.LastSeenAt)) {
			b.Heartbeat.LastSeenAt = a.LastSeenAt
			newest = a
		}
	}
	if newest != nil {
		b.Heartbeat.Active = now.Sub(*newest.LastSeenAt) <= time.Duration(c.HeartbeatTimeoutSec)*time.Second
		if newest.Info != nil {
			b.Heartbeat.Library = newest.Info.Version
		}
		if bs := newest.Bot; bs != nil {
			b.Version, b.LastError, b.LastErrorAt, b.LastSuccessAt, b.APIOK = bs.Version, monitoring.Redact(bs.LastError), bs.LastErrorAt, bs.LastSuccessAt, bs.APIOK
			if b.Heartbeat.Active {
				b.StartedAt = bs.StartedAt
			}
		}
	}
	if _, adapter, ok := s.controllerOf(c); ok {
		rt := s.runtimeState(ctx, c, adapter, full)
		b.RuntimeState = &rt
		switch {
		case rt.State == "stopped":
			b.StartedAt = nil // a stopped process has no uptime, whatever the last heartbeat said
		case b.StartedAt == nil && rt.State == "running":
			b.StartedAt = rt.Since
		}
	}
	if b.StartedAt != nil {
		up := int64(now.Sub(*b.StartedAt).Seconds())
		b.UptimeSec = &up
	}
	for _, m := range st.KeyMetrics {
		if m.Value == nil || now.Sub(m.At) > 5*time.Minute {
			continue // a stale value is not the current load
		}
		switch m.Metric {
		case "process.cpu_percent", "docker.cpu_percent":
			if b.CPUPercent == nil || m.Metric == "process.cpu_percent" {
				b.CPUPercent = m.Value
			}
		case "process.rss_bytes", "docker.mem_bytes":
			if b.MemBytes == nil || m.Metric == "process.rss_bytes" {
				b.MemBytes = m.Value
			}
		}
	}
	if rels, err := s.reg.Relations(ctx, e.ID); err == nil {
		for _, r := range rels {
			if r.Direction == "outgoing" && slices.Contains(placementKinds, r.Kind) {
				ref := EntityRef{ID: r.Peer.ID, Name: r.Peer.Name, Type: r.Peer.Type, Relation: r.Kind}
				if full {
					ref = s.ref(ctx, r.Peer, r.Kind)
				}
				b.Host = &ref
				break
			}
		}
	}
	if err := s.jobSummary(ctx, &b); err != nil {
		return b, err
	}
	return b, nil
}

// runtimeState asks the adapter; list views use a short cache so a page of
// bots does not run a systemctl/Docker call per card on every refresh.
func (s *Service) runtimeState(ctx context.Context, c Config, a Controller, fresh bool) RuntimeState {
	ctl, _, _ := s.controllerOf(c)
	if a.Kind() != "process" && !fresh {
		s.mu.Lock()
		cached, ok := s.rtCache[ctl.ID]
		s.mu.Unlock()
		if ok && s.now().Sub(cached.at) < 15*time.Second {
			return cached.st
		}
	}
	st := a.State(ctx, ctl)
	s.mu.Lock()
	s.rtCache[ctl.ID] = cachedRuntime{st: st, at: s.now()}
	s.mu.Unlock()
	return st
}

func (s *Service) integration(b *Bot) *IntegrationInfo {
	switch {
	case b.N8NInstanceID != "":
		return s.n8n.integration(b.Config)
	case b.Type == "telegram_bot" || b.Runtime == "telegram":
		info := &IntegrationInfo{Kind: "telegram", Label: "Telegram", Status: "unknown",
			Reason: "Состояние API Telegram сообщает сам бот через heartbeat; токен для этого не нужен"}
		if b.APIOK != nil {
			info.Status = "unavailable"
			if *b.APIOK {
				info.Status = "ok"
			}
		}
		if b.TelegramTokenID != "" {
			info.Reason += ". Проверка getMe: файл токена «" + b.TelegramTokenID + "» на сервере"
		}
		return info
	}
	return nil
}
