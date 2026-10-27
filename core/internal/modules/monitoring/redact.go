package monitoring

import (
	"encoding/json"
	"regexp"
	"strings"
	"unicode/utf8"
)

const redacted = "[скрыто]"

// Patterns of secrets that must never be stored: bot tokens, bearer and
// basic credentials, key=value secrets, credentials in URLs, private keys,
// AER agent tokens and long hex/base64 blobs that look like keys.
var secretPatterns = []*regexp.Regexp{
	regexp.MustCompile(`\b\d{6,12}:[A-Za-z0-9_-]{30,}\b`),               // Telegram bot token
	regexp.MustCompile(`(?i)\b(bearer|basic)\s+[A-Za-z0-9._~+/=-]{8,}`), // auth headers
	regexp.MustCompile(`(?i)\b(pass(word|wd)?|pwd|token|secret|api[_-]?key|access[_-]?key|private[_-]?key|session|cookie)\b(\s*["']?\s*[:=]\s*)("[^"]*"|'[^']*'|\S+)`),
	regexp.MustCompile(`(?i)\b([a-z][a-z0-9+.-]*://)[^/\s:@]+:[^/\s@]+@`), // user:pass@ in URLs
	regexp.MustCompile(`-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?(-----END [A-Z ]*PRIVATE KEY-----|$)`),
	regexp.MustCompile(`\baer1\.[0-9a-f-]{36}\.[0-9a-f]{64}\b`), // AER agent token
	regexp.MustCompile(`\b[0-9a-fA-F]{40,}\b`),                  // long hex keys
}

// Redact removes secrets from a log message or field value.
func Redact(s string) string {
	for i, re := range secretPatterns {
		switch i {
		case 1:
			s = re.ReplaceAllString(s, "$1 "+redacted)
		case 2:
			s = re.ReplaceAllString(s, "$1$3"+redacted)
		case 3:
			s = re.ReplaceAllString(s, "$1"+redacted+"@")
		default:
			s = re.ReplaceAllString(s, redacted)
		}
	}
	return s
}

var sensitiveKeys = regexp.MustCompile(`(?i)(pass|pwd|token|secret|key|cookie|session|auth|credential)`)

// RedactFields redacts a JSON object of extra fields: values of sensitive
// keys are dropped entirely, other string values are pattern-redacted.
func RedactFields(raw json.RawMessage) json.RawMessage {
	if len(raw) == 0 || string(raw) == "null" {
		return nil
	}
	var m map[string]any
	if err := json.Unmarshal(raw, &m); err != nil {
		return nil
	}
	if len(m) > 32 {
		return nil
	}
	for k, v := range m {
		if sensitiveKeys.MatchString(k) {
			m[k] = redacted
			continue
		}
		switch t := v.(type) {
		case string:
			m[k] = truncate(Redact(t), 1024)
		case float64, bool, nil:
		default:
			b, _ := json.Marshal(t)
			m[k] = truncate(Redact(string(b)), 1024)
		}
	}
	out, _ := json.Marshal(m)
	return out
}

func truncate(s string, max int) string {
	if utf8.RuneCountInString(s) <= max {
		return s
	}
	r := []rune(s)
	return string(r[:max]) + "…"
}

func cleanMessage(s string) string {
	s = strings.ToValidUTF8(s, "�")
	return truncate(Redact(strings.TrimSpace(s)), 4000)
}
