package remote

import (
	"context"
	"net/http"
)

func (m *Module) gwTrust(w http.ResponseWriter, r *http.Request) error {
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) { return m.svc.DeviceTrust(ctx, c) })
}
func (m *Module) gwTrustEnabled(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Enabled *bool `json:"enabled"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	if in.Enabled == nil {
		return apiError(&ValidationError{Fields: map[string]string{"enabled": "Укажите true или false"}})
	}
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) { return m.svc.SetUnattended(ctx, c, *in.Enabled) })
}
func (m *Module) gwTrustCandidate(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Number string `json:"number"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) { return m.svc.TrustCandidate(ctx, c, in.Number) })
}
func (m *Module) gwTrustGrant(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Number      string `json:"number"`
		Fingerprint string `json:"fingerprint"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) {
		return m.svc.GrantTrust(ctx, c, in.Number, in.Fingerprint)
	})
}
func (m *Module) gwTrustRevoke(w http.ResponseWriter, r *http.Request) error {
	var in struct {
		Number string `json:"number"`
	}
	if err := decode(r, &in); err != nil {
		return err
	}
	return m.withClient(w, r, func(ctx context.Context, c Client) (any, error) { return m.svc.RevokeTrust(ctx, c, in.Number) })
}
