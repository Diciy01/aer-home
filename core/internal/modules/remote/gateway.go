package remote

import (
	"context"
	"net/http"
	"strings"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/modules/monitoring"
)

// Routes of remote access clients (owner) and of the Remote Gateway's
// service API (ADR-017). The Gateway authenticates with its own agent
// credential (kind "gateway") and passes the remote client's credential in
// HeaderClient; Core decides everything, the Gateway only relays.

const (
	// HeaderClient carries a remote client's credential (Gateway → Core).
	HeaderClient = "X-AER-Remote-Client"
	// HeaderAgent carries a host agent's credential for its relay leg.
	HeaderAgent = "X-AER-Remote-Agent"
	// HeaderAddr is the client's address as the Gateway saw it (audit).
	HeaderAddr = "X-AER-Client-Addr"
)

func (m *Module) registerClientRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/remote/clients", m.clients)
	r.Handle(http.MethodPost, "/remote/clients", m.createClient)
	r.Handle(http.MethodPut, "/remote/clients/{id}", m.updateClient)
	r.Handle(http.MethodPost, "/remote/clients/{id}/pairing", m.repairClient)
	r.Handle(http.MethodPost, "/remote/clients/{id}/revoke", m.revokeClient)

	gw := httpapi.Authorize("gateway", m.gatewayAuthorizer)
	r.Handle(http.MethodPost, "/remote/gw/pair", m.gwPair, gw)
	r.Handle(http.MethodGet, "/remote/gw/client/hosts", m.gwHosts, gw)
	r.Handle(http.MethodPost, "/remote/gw/client/sessions", m.gwCreate, gw)
	r.Handle(http.MethodGet, "/remote/gw/client/sessions/{id}", m.gwSession, gw)
	r.Handle(http.MethodPost, "/remote/gw/client/sessions/{id}/grant", m.gwGrant, gw)
	r.Handle(http.MethodPost, "/remote/gw/client/sessions/{id}/tickets", m.gwTicket, gw)
	r.Handle(http.MethodPost, "/remote/gw/client/sessions/{id}/end", m.gwEnd, gw)
	r.Handle(http.MethodPost, "/remote/gw/tunnel/claim", m.gwClaim, gw)
	r.Handle(http.MethodPost, "/remote/gw/tunnel/host", m.gwHostLeg, gw)
	r.Handle(http.MethodPost, "/remote/gw/tunnel/event", m.gwTunnelEvent, gw)
	r.Handle(http.MethodPost, "/remote/gw/alive", m.gwAlive, gw)
}

// gatewayAuthorizer accepts only agent credentials of kind "gateway".
func (m *Module) gatewayAuthorizer(r *http.Request) (*http.Request, bool) {
	ar, ok := m.svc.mon.AgentAuthorizer(r)
	if !ok {
		return r, false
	}
	a, _ := monitoring.AgentFromContext(ar.Context())
	return ar, a.Kind == "gateway"
}

func (m *Module) clients(w http.ResponseWriter, r *http.Request) error {
	c, err := m.svc.Clients(r.Context())
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, c)
}

func (m *Module) createClient(w http.ResponseWriter, r *http.Request) error {
	var in ClientInput
	if err := decode(r, &in); err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-store")
	p, err := m.svc.CreateClient(r.Context(), in)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, p)
	return nil
}

func (m *Module) updateClient(w http.ResponseWriter, r *http.Request) error {
	var in ClientInput
	if err := decode(r, &in); err != nil {
		return err
	}
	c, err := m.svc.UpdateClient(r.Context(), r.PathValue("id"), in)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, c)
}

func (m *Module) repairClient(w http.ResponseWriter, r *http.Request) error {
	w.Header().Set("Cache-Control", "no-store")
	p, err := m.svc.RepairClient(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, p)
}

func (m *Module) revokeClient(w http.ResponseWriter, r *http.Request) error {
	c, err := m.svc.RevokeClient(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, c)
}

// ---- Gateway service API ----

func clientAddr(r *http.Request) string {
	a := strings.TrimSpace(r.Header.Get(HeaderAddr))
	if len(a) > 64 {
		a = a[:64]
	}
	return a
}

func (m *Module) client(r *http.Request) (Client, error) {
	return m.svc.AuthenticateClient(r.Context(), r.Header.Get(HeaderClient), clientAddr(r))
}

func (m *Module) gwPair(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Code       string `json:"code"`
		DeviceName string `json:"deviceName"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-store")
	p, err := m.svc.Pair(r.Context(), in.Code, in.DeviceName, clientAddr(r))
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, p)
}

// withClient runs h for an authenticated remote client.
func (m *Module) withClient(w http.ResponseWriter, r *http.Request, h func(context.Context, Client) (any, error)) error {
	c, err := m.client(r)
	if err != nil {
		return apiError(err)
	}
	v, err := h(r.Context(), c)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, v)
}

func (m *Module) gwHosts(w http.ResponseWriter, r *http.Request) error {
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		h, err := m.svc.ClientHosts(ctx, c)
		return map[string]any{"client": map[string]any{"id": c.ID, "name": c.Name}, "hosts": h}, err
	})
}

func (m *Module) gwCreate(w http.ResponseWriter, r *http.Request) error {
	var in NewSession
	if err := decode(r, &in); err != nil {
		return err
	}
	key := r.Header.Get("Idempotency-Key")
	if len(key) > 100 {
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Idempotency-Key до 100 символов")
	}
	c, err := m.client(r)
	if err != nil {
		return apiError(err)
	}
	x, err := m.svc.ClientCreate(r.Context(), c, in, key)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, x)
	return nil
}

func (m *Module) gwSession(w http.ResponseWriter, r *http.Request) error {
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		return m.svc.ClientSession(ctx, c, r.PathValue("id"))
	})
}

func (m *Module) gwGrant(w http.ResponseWriter, r *http.Request) error {
	w.Header().Set("Cache-Control", "no-store")
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		return m.svc.ClientGrant(ctx, c, r.PathValue("id"))
	})
}

func (m *Module) gwTicket(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Channel string `json:"channel"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	w.Header().Set("Cache-Control", "no-store")
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		t, err := m.svc.ClientTicket(ctx, c, r.PathValue("id"), in.Channel)
		return map[string]any{"ticket": t, "ttlSec": m.svc.cfg.GrantTTLSec}, err
	})
}

func (m *Module) gwEnd(w http.ResponseWriter, r *http.Request) error {
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		return m.svc.ClientEnd(ctx, c, r.PathValue("id"))
	})
}

func (m *Module) gwClaim(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Ticket string `json:"ticket"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		return m.svc.ClaimTicket(ctx, c, in.Ticket)
	})
}

func (m *Module) gwHostLeg(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		SessionID string `json:"sessionId"`
		Channel   string `json:"channel"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	a, found := m.svc.mon.Authenticate(r.Context(), r.Header.Get(HeaderAgent))
	if !found || a.Kind != "remote" {
		return httpapi.NewError(http.StatusUnauthorized, httpapi.CodeUnauthorized, "Учётные данные агента хоста не приняты")
	}
	c, err := m.svc.HostLeg(r.Context(), a.EntityID, in.SessionID, in.Channel)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, c)
}

func (m *Module) gwTunnelEvent(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		SessionID string `json:"sessionId"`
		Kind      string `json:"kind"`
		Message   string `json:"message"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if err := m.svc.TunnelEvent(r.Context(), in.SessionID, in.Kind, monitoring.Redact(in.Message)); err != nil {
		return apiError(err)
	}
	return ok(w, r, map[string]any{})
}

func (m *Module) gwAlive(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Sessions []string `json:"sessions"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if len(in.Sessions) > 256 {
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Не больше 256 сеансов")
	}
	return ok(w, r, map[string]any{"active": m.svc.Alive(r.Context(), in.Sessions)})
}
