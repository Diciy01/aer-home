package registry

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"
	"sort"
	"strconv"

	"aerhome/core/internal/foundation/httpapi"
)

func (m *Module) RegisterRoutes(r *httpapi.Router) {
	r.Handle(http.MethodGet, "/registry/types", m.listTypes)
	r.Handle(http.MethodGet, "/registry/capabilities", m.listCapabilities)
	r.Handle(http.MethodGet, "/registry/relation-kinds", m.listRelationKinds)
	r.Handle(http.MethodGet, "/registry/entities", m.listEntities)
	r.Handle(http.MethodPost, "/registry/entities", m.createEntity)
	r.Handle(http.MethodGet, "/registry/entities/{id}", m.getEntity)
	r.Handle(http.MethodPatch, "/registry/entities/{id}", m.updateEntity)
	r.Handle(http.MethodPost, "/registry/entities/{id}/archive", m.archiveEntity)
	r.Handle(http.MethodPost, "/registry/entities/{id}/restore", m.restoreEntity)
	r.Handle(http.MethodPut, "/registry/entities/{id}/capabilities", m.setCapabilities)
	r.Handle(http.MethodGet, "/registry/entities/{id}/relations", m.listRelations)
	r.Handle(http.MethodPost, "/registry/entities/{id}/relations", m.addRelation)
	r.Handle(http.MethodDelete, "/registry/relations/{id}", m.deleteRelation)
}

// apiError maps domain errors onto the Foundation error envelope.
func apiError(err error) error {
	var ve *ValidationError
	var ce *ConflictError
	switch {
	case errors.As(err, &ve):
		return httpapi.NewError(http.StatusUnprocessableEntity, httpapi.CodeValidationFailed, "Проверьте введённые данные").
			WithDetails(map[string]any{"fields": ve.Fields})
	case errors.As(err, &ce):
		details := map[string]any{"reason": ce.Reason}
		if ce.CurrentRevision > 0 {
			details["currentRevision"] = ce.CurrentRevision
		}
		return httpapi.NewError(http.StatusConflict, httpapi.CodeConflict, ce.Message).WithDetails(details)
	case errors.Is(err, ErrNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Объект не найден")
	case errors.Is(err, ErrRelationNotFound):
		return httpapi.NewError(http.StatusNotFound, httpapi.CodeNotFound, "Связь не найдена")
	}
	return err
}

func (m *Module) listTypes(w http.ResponseWriter, r *http.Request) error {
	httpapi.WriteData(w, r, http.StatusOK, m.svc.Catalog().Types())
	return nil
}

func (m *Module) listCapabilities(w http.ResponseWriter, r *http.Request) error {
	httpapi.WriteData(w, r, http.StatusOK, m.svc.Catalog().Capabilities())
	return nil
}

func (m *Module) listRelationKinds(w http.ResponseWriter, r *http.Request) error {
	httpapi.WriteData(w, r, http.StatusOK, m.svc.Catalog().RelationKinds())
	return nil
}

func (m *Module) listEntities(w http.ResponseWriter, r *http.Request) error {
	q := r.URL.Query()
	f := ListFilter{
		Query:      q.Get("q"),
		Types:      q["type"],
		Tag:        q.Get("tag"),
		Capability: q.Get("capability"),
		ParentID:   q.Get("parentId"),
		Archived:   ArchivedFilter(q.Get("archived")),
	}
	v := &ValidationError{}
	f.Limit = intParam(v, q.Get("limit"), "limit")
	f.Offset = intParam(v, q.Get("offset"), "offset")
	if err := v.orNil(); err != nil {
		return apiError(err)
	}
	page, err := m.svc.List(r.Context(), f)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, page)
	return nil
}

func intParam(v *ValidationError, raw, field string) int {
	if raw == "" {
		return 0
	}
	n, err := strconv.Atoi(raw)
	if err != nil {
		v.add(field, field+" должен быть целым числом")
	}
	return n
}

func (m *Module) createEntity(w http.ResponseWriter, r *http.Request) error {
	var in NewEntity
	if err := httpapi.DecodeJSON(r, &in); err != nil {
		return err
	}
	e, err := m.svc.Create(r.Context(), in)
	if err != nil {
		return apiError(err)
	}
	w.Header().Set("Location", httpapi.Prefix+"/registry/entities/"+e.ID)
	httpapi.WriteData(w, r, http.StatusCreated, e)
	return nil
}

func (m *Module) getEntity(w http.ResponseWriter, r *http.Request) error {
	e, err := m.svc.Get(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, e)
	return nil
}

var patchFields = []string{"revision", "name", "type", "description", "icon", "tags", "parentId",
	"discovery", "address", "secretRefs", "attributes"}

func (m *Module) updateEntity(w http.ResponseWriter, r *http.Request) error {
	var raw map[string]json.RawMessage
	if err := httpapi.DecodeJSON(r, &raw); err != nil {
		return err
	}
	p, err := parsePatch(raw)
	if err != nil {
		return err
	}
	e, err := m.svc.Update(r.Context(), r.PathValue("id"), p)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, e)
	return nil
}

// parsePatch distinguishes "field absent" from "field: null" (clear).
func parsePatch(raw map[string]json.RawMessage) (EntityPatch, error) {
	allowed := setOf(patchFields)
	var unknown []string
	for k := range raw {
		if !allowed[k] {
			unknown = append(unknown, k)
		}
	}
	if len(unknown) > 0 {
		sort.Strings(unknown)
		return EntityPatch{}, httpapi.NewError(http.StatusBadRequest, httpapi.CodeBadRequest,
			"unknown fields in patch").WithDetails(map[string]any{"fields": unknown})
	}
	v := &ValidationError{}
	var p EntityPatch
	isNull := func(b json.RawMessage) bool { return string(b) == "null" }
	decode := func(field string, dst any) bool {
		b, ok := raw[field]
		if !ok {
			return false
		}
		if isNull(b) {
			v.add(field, "Поле не может быть null")
			return false
		}
		if err := json.Unmarshal(b, dst); err != nil {
			v.add(field, "Неверный формат поля")
			return false
		}
		return true
	}
	decode("revision", &p.Revision)
	if _, ok := raw["revision"]; !ok {
		v.add("revision", "Укажите текущую версию записи")
	}
	var s string
	if decode("name", &s) {
		p.Name = ptr(s)
	}
	if decode("type", &s) {
		p.Type = ptr(s)
	}
	if decode("description", &s) {
		p.Description = ptr(s)
	}
	if decode("icon", &s) {
		p.Icon = ptr(s)
	}
	var tags []string
	if decode("tags", &tags) {
		p.Tags = &tags
	}
	var d Discovery
	if decode("discovery", &d) {
		p.Discovery = &d
	}
	var refs []SecretRef
	if decode("secretRefs", &refs) {
		p.SecretRefs = &refs
	}
	if b, ok := raw["attributes"]; ok {
		attrs := json.RawMessage(b)
		p.Attributes = &attrs
	}
	for field, dst := range map[string]***string{"parentId": &p.ParentID, "address": &p.Address} {
		b, ok := raw[field]
		if !ok {
			continue
		}
		var val *string
		if !isNull(b) {
			var str string
			if err := json.Unmarshal(b, &str); err != nil {
				v.add(field, "Неверный формат поля")
				continue
			}
			val = &str
		}
		*dst = &val
	}
	if err := v.orNil(); err != nil {
		return EntityPatch{}, apiError(err)
	}
	return p, nil
}

func ptr[T any](v T) *T { return &v }

type revisionBody struct {
	Revision int `json:"revision"`
}

func (m *Module) archiveEntity(w http.ResponseWriter, r *http.Request) error {
	return m.archiveOrRestore(w, r, m.svc.Archive)
}

func (m *Module) restoreEntity(w http.ResponseWriter, r *http.Request) error {
	return m.archiveOrRestore(w, r, m.svc.Restore)
}

func (m *Module) archiveOrRestore(w http.ResponseWriter, r *http.Request,
	op func(ctx context.Context, id string, revision int) (Entity, error)) error {
	var body revisionBody
	if err := httpapi.DecodeJSON(r, &body); err != nil {
		return err
	}
	e, err := op(r.Context(), r.PathValue("id"), body.Revision)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, e)
	return nil
}

func (m *Module) setCapabilities(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Revision     int      `json:"revision"`
		Capabilities []string `json:"capabilities"`
	}
	if err := httpapi.DecodeJSON(r, &body); err != nil {
		return err
	}
	if body.Capabilities == nil {
		return apiError(&ValidationError{Fields: map[string]string{"capabilities": "Укажите список возможностей (может быть пустым)"}})
	}
	e, err := m.svc.SetCapabilities(r.Context(), r.PathValue("id"), body.Revision, body.Capabilities)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, e)
	return nil
}

func (m *Module) listRelations(w http.ResponseWriter, r *http.Request) error {
	rels, err := m.svc.Relations(r.Context(), r.PathValue("id"))
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, rels)
	return nil
}

func (m *Module) addRelation(w http.ResponseWriter, r *http.Request) error {
	var body struct {
		Kind     string `json:"kind"`
		TargetID string `json:"targetId"`
		Label    string `json:"label"`
	}
	if err := httpapi.DecodeJSON(r, &body); err != nil {
		return err
	}
	rel, err := m.svc.AddRelation(r.Context(), r.PathValue("id"), body.Kind, body.TargetID, body.Label)
	if err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusCreated, rel)
	return nil
}

func (m *Module) deleteRelation(w http.ResponseWriter, r *http.Request) error {
	id := r.PathValue("id")
	if err := m.svc.DeleteRelation(r.Context(), id); err != nil {
		return apiError(err)
	}
	httpapi.WriteData(w, r, http.StatusOK, map[string]string{"id": id})
	return nil
}
