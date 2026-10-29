package remote

import "net/http"

func (m *Module) gwRegistration(w http.ResponseWriter, r *http.Request) error {
	var in RegistrationInput
	if err := decode(r, &in); err != nil {
		return err
	}
	out, err := m.svc.Registration(r.Context(), in, clientAddr(r))
	if err != nil {
		return apiError(err)
	}
	w.Header().Set("Cache-Control", "no-store")
	return ok(w, r, out)
}

func (m *Module) registrations(w http.ResponseWriter, r *http.Request) error {
	out, err := m.svc.Registrations(r.Context())
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, out)
}
func (m *Module) approveRegistration(w http.ResponseWriter, r *http.Request) error {
	out, err := m.svc.DecideRegistration(r.Context(), r.PathValue("id"), true)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, out)
}
func (m *Module) rejectRegistration(w http.ResponseWriter, r *http.Request) error {
	out, err := m.svc.DecideRegistration(r.Context(), r.PathValue("id"), false)
	if err != nil {
		return apiError(err)
	}
	return ok(w, r, out)
}
