package scene

import (
	"encoding/json"
	"errors"
	"net/http"

	"aerhome/core/internal/foundation/httpapi"
	"aerhome/core/internal/foundation/module"
	"aerhome/core/internal/foundation/storage"
)

// Name is the module name used in config and schema_migrations.
const Name = "scene"

// Module plugs scene storage into Core.
type Module struct{ svc *Service }

var _ module.Module = (*Module)(nil)

// Factory builds the module.
func Factory() module.Factory {
	return func(deps module.Deps) (module.Module, error) {
		return &Module{svc: NewService(deps.DB, nil)}, nil
	}
}

func (m *Module) Name() string                    { return Name }
func (m *Module) Migrations() []storage.Migration { return migrations }

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/scenes", m.list)
	r.Handle(http.MethodPost, "/scenes", m.create)
	r.Handle(http.MethodGet, "/scenes/{id}", m.get)
	r.Handle(http.MethodPut, "/scenes/{id}", m.replace)
}

func apiError(err error) error {
	var ve *ValidationError
	var ce *ConflictError
	switch {
	case errors.As(err, &ve):
		fields := map[string]string{}
		for k, v := range ve.Issues {
			if k == "" {
				k = "document"
			}
			fields[k] = v
		}
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed,
			"Сцена не прошла проверку схемы").WithDetails(map[string]any{"fields": fields})
	case errors.As(err, &ce):
		details := map[string]any{"reason": ce.Reason}
		if ce.CurrentRevision > 0 {
			details["currentRevision"] = ce.CurrentRevision
		}
		return httpapi.NewError(http.StatusConflict, httpapi.CodeConflict, ce.Message).WithDetails(details)
	case errors.Is(err, ErrNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Сцена не найдена")
	}
	return err
}

func (m *Module) list(w http.ResponseWriter, r *http.Request) error {
	list, err := m.svc.List(r.Context())
	if err != nil {
		return err
	}
	httpapi.WriteData(w, r, http.StatusOK, list)
	return nil
}

func (m *Module) get(w http.ResponseWriter, r *http.Request) error {
	rec, err := m.svc.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, rec)
	return nil
}

func (m *Module) create(w http.ResponseWriter, r *http.Request) error {
	var raw json.RawMessage
	if err := httpapi.DecodeJSON(r, &raw); err != nil {
		return err
	}
	rec, err := m.svc.Create(r.Context(), raw)
	if err != nil {
		return apiError(err)
	}
	w.Header().Set("Location", httpapi.Prefix+"/scenes/"+rec.ID)
	httpapi.WriteData(w, r, http.StatusCreated, rec)
	return nil
}

func (m *Module) replace(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Revision int             `json:"revision"`
		Document json.RawMessage `json:"document"`
	}
	if err := httpapi.DecodeJSON(r, &body); err != nil {
		return err
	}
	if body.Revision < 1 || len(body.Document) == 0 {
		return apiError(&ValidationError{Issues{"revision": "Укажите revision и document"}})
	}
	rec, err := m.svc.Replace(r.Context(), r.PathValue("id"), body.Revision, body.Document)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, rec)
	return nil
}
