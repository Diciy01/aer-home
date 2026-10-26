package httpapi

import (
	"encoding/json"
	"errors"
	"io"
	"net/http"
)

// DecodeJSON strictly decodes a JSON request body into dst: unknown fields,
// trailing data and oversized bodies are rejected with API errors.
func DecodeJSON(r *http.Request, dst any) error {
	dec := json.NewDecoder(r.Body)
	dec.DisallowUnknownFields()
	if err := dec.Decode(dst); err != nil {
		var tooLarge *http.MaxBytesError
		switch {
		case errors.As(err, &tooLarge):
			return NewError(http.StatusRequestEntityTooLarge, CodePayloadTooLarge, "request body is too large")
		case errors.Is(err, io.EOF):
			return NewError(http.StatusBadRequest, CodeBadRequest, "request body is empty")
		default:
			return NewError(http.StatusBadRequest, CodeBadRequest, "invalid JSON body: "+err.Error())
		}
	}
	if dec.More() {
		return NewError(http.StatusBadRequest, CodeBadRequest, "request body has trailing data")
	}
	return nil
}
