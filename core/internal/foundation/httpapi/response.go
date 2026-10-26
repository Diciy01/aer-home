// Package httpapi provides the unified REST envelope, error model, routing and
// middleware shared by every Core module. See docs/adr/ADR-007-api-envelope-and-auth.md.
package httpapi

import (
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
)

// APIVersion is the path version served under /api/v1.
const APIVersion = "v1"

// Code is a stable, machine-readable error code. Clients branch on Code, never on Message.
type Code string

const (
	CodeBadRequest         Code = "BAD_REQUEST"
	CodeValidationFailed   Code = "VALIDATION_FAILED"
	CodeUnauthorized       Code = "UNAUTHORIZED"
	CodeForbidden          Code = "FORBIDDEN"
	CodeNotFound           Code = "NOT_FOUND"
	CodeMethodNotAllowed   Code = "METHOD_NOT_ALLOWED"
	CodeConflict           Code = "CONFLICT"
	CodePayloadTooLarge    Code = "PAYLOAD_TOO_LARGE"
	CodeUnsupported        Code = "UNSUPPORTED"
	CodePermissionRequired Code = "PERMISSION_REQUIRED"
	CodeUnavailable        Code = "UNAVAILABLE"
	CodeInternal           Code = "INTERNAL"
)

// Error is the error body returned to clients.
type Error struct {
	Status  int            `json:"-"`
	Code    Code           `json:"code"`
	Message string         `json:"message"`
	Details map[string]any `json:"details,omitempty"`
}

func (e *Error) Error() string { return fmt.Sprintf("%s (%d): %s", e.Code, e.Status, e.Message) }

// NewError builds an API error.
func NewError(status int, code Code, message string) *Error {
	return &Error{Status: status, Code: code, Message: message}
}

// WithDetails attaches structured details (never secrets).
func (e *Error) WithDetails(details map[string]any) *Error {
	e.Details = details
	return e
}

// Meta accompanies every response.
type Meta struct {
	RequestID  string `json:"requestId"`
	APIVersion string `json:"apiVersion"`
}

type successBody struct {
	Data any  `json:"data"`
	Meta Meta `json:"meta"`
}

type errorBody struct {
	Error *Error `json:"error"`
	Meta  Meta   `json:"meta"`
}

func metaFor(r *http.Request) Meta {
	return Meta{RequestID: RequestID(r.Context()), APIVersion: APIVersion}
}

// WriteData writes a success envelope.
func WriteData(w http.ResponseWriter, r *http.Request, status int, data any) {
	writeJSON(w, status, successBody{Data: data, Meta: metaFor(r)})
}

// WriteError writes an error envelope. Non-API errors become a generic INTERNAL
// error so internal details never leak to clients; callers log the original.
func WriteError(w http.ResponseWriter, r *http.Request, err error) {
	var apiErr *Error
	if !errors.As(err, &apiErr) {
		apiErr = NewError(http.StatusInternalServerError, CodeInternal, "internal error")
	}
	writeJSON(w, apiErr.Status, errorBody{Error: apiErr, Meta: metaFor(r)})
}

func writeJSON(w http.ResponseWriter, status int, body any) {
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.WriteHeader(status)
	enc := json.NewEncoder(w)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(body)
}
