package httpapi

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func decode(body string, limit int64) error {
	req := httptest.NewRequest(http.MethodPost, "/", strings.NewReader(body))
	req.Body = http.MaxBytesReader(httptest.NewRecorder(), req.Body, limit)
	var dst struct {
		Name string `json:"name"`
	}
	return DecodeJSON(req, &dst)
}

func TestDecodeJSON(t *testing.T) {
	cases := map[string]struct {
		body  string
		limit int64
		code  Code
	}{
		"ok":            {`{"name":"x"}`, 1024, ""},
		"unknown field": {`{"name":"x","token":"y"}`, 1024, CodeBadRequest},
		"empty":         {``, 1024, CodeBadRequest},
		"trailing":      {`{"name":"x"} {}`, 1024, CodeBadRequest},
		"malformed":     {`{"name":`, 1024, CodeBadRequest},
		"too large":     {`{"name":"` + strings.Repeat("a", 100) + `"}`, 16, CodePayloadTooLarge},
	}
	for name, tc := range cases {
		t.Run(name, func(t *testing.T) {
			err := decode(tc.body, tc.limit)
			if tc.code == "" {
				if err != nil {
					t.Fatalf("unexpected error %v", err)
				}
				return
			}
			var apiErr *Error
			if !errors.As(err, &apiErr) || apiErr.Code != tc.code {
				t.Fatalf("want %s, got %v", tc.code, err)
			}
		})
	}
}
