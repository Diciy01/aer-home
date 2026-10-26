package registry

import (
	"bytes"
	"encoding/json"
	"net/url"
	"regexp"
	"sort"
	"strings"
	"unicode"
	"unicode/utf8"
)

const (
	maxName        = 120
	maxDescription = 2000
	maxAddress     = 512
	maxTags        = 20
	maxSecretRefs  = 10
	maxAttributes  = 32 << 10
	maxAttrKey     = 64
	maxLabel       = 60
)

var (
	iconPattern      = regexp.MustCompile(`^[a-z0-9_./-]{1,64}$`)
	tagPattern       = regexp.MustCompile(`^[\p{L}\p{N}_.:-]{1,32}$`)
	secretNamePat    = regexp.MustCompile(`^[a-z0-9_.-]{1,64}$`)
	secretRefPattern = regexp.MustCompile(`^(env|keyring|file|vault):[A-Za-z0-9_./:@-]{1,256}$`)
	// Attribute keys that suggest a secret value; such data belongs in secretRefs.
	secretKeyWords = []string{"password", "passwd", "secret", "token", "apikey", "api_key", "privatekey", "private_key", "credential"}
)

func cleanText(s string) string { return strings.TrimSpace(s) }

func validName(v *ValidationError, name string) string {
	name = cleanText(name)
	switch {
	case name == "":
		v.add("name", "Укажите название")
	case utf8.RuneCountInString(name) > maxName:
		v.add("name", "Название длиннее 120 символов")
	case strings.IndexFunc(name, unicode.IsControl) >= 0:
		v.add("name", "Название содержит управляющие символы")
	}
	return name
}

func validDescription(v *ValidationError, s string) string {
	s = cleanText(s)
	if utf8.RuneCountInString(s) > maxDescription {
		v.add("description", "Описание длиннее 2000 символов")
	}
	return s
}

func validIcon(v *ValidationError, icon string) string {
	icon = cleanText(icon)
	if icon != "" && !iconPattern.MatchString(icon) {
		v.add("icon", "Идентификатор иконки: латиница в нижнем регистре, цифры, . _ / -")
	}
	return icon
}

// validTags lowercases, trims, de-duplicates and sorts tags.
func validTags(v *ValidationError, tags []string) []string {
	seen := map[string]bool{}
	out := []string{}
	for _, t := range tags {
		t = strings.ToLower(cleanText(t))
		if t == "" || seen[t] {
			continue
		}
		if !tagPattern.MatchString(t) {
			v.add("tags", "Тег «"+t+"»: до 32 символов, буквы, цифры, _ . : -")
			continue
		}
		seen[t] = true
		out = append(out, t)
	}
	if len(out) > maxTags {
		v.add("tags", "Не больше 20 тегов")
	}
	sort.Strings(out)
	return out
}

func validDiscovery(v *ValidationError, d Discovery) Discovery {
	if d == "" {
		return DiscoveryManual
	}
	if !discoveries[d] {
		v.add("discovery", "Неизвестный способ обнаружения")
	}
	return d
}

// validAddress accepts host, host:port, IP or URL; it rejects embedded credentials.
func validAddress(v *ValidationError, addr *string, mode AddressMode) *string {
	if addr == nil || cleanText(*addr) == "" {
		if mode == AddressRequired {
			v.add("address", "Для этого типа нужен адрес")
		}
		return nil
	}
	a := cleanText(*addr)
	switch {
	case mode == AddressNone:
		v.add("address", "У этого типа нет адреса подключения")
	case len(a) > maxAddress:
		v.add("address", "Адрес длиннее 512 символов")
	case strings.IndexFunc(a, unicode.IsSpace) >= 0:
		v.add("address", "Адрес не должен содержать пробелов")
	case strings.Contains(a, "://"):
		u, err := url.Parse(a)
		if err != nil || u.Host == "" {
			v.add("address", "Некорректный URL")
		} else if u.User != nil {
			v.add("address", "Не указывайте логин и пароль в адресе — используйте ссылки на секреты")
		}
	case strings.Contains(a, "@"):
		v.add("address", "Не указывайте логин и пароль в адресе — используйте ссылки на секреты")
	}
	return &a
}

func validSecretRefs(v *ValidationError, refs []SecretRef) []SecretRef {
	if len(refs) > maxSecretRefs {
		v.add("secretRefs", "Не больше 10 ссылок на секреты")
	}
	seen := map[string]bool{}
	out := []SecretRef{}
	for _, r := range refs {
		r.Name, r.Ref = cleanText(r.Name), cleanText(r.Ref)
		switch {
		case !secretNamePat.MatchString(r.Name):
			v.add("secretRefs", "Имя ссылки: латиница в нижнем регистре, цифры, _ . -")
		case seen[r.Name]:
			v.add("secretRefs", "Имя ссылки «"+r.Name+"» повторяется")
		case !secretRefPattern.MatchString(r.Ref):
			v.add("secretRefs", "Ссылка должна иметь вид env:NAME, keyring:..., file:... или vault:... — не сам секрет")
		}
		seen[r.Name] = true
		out = append(out, r)
	}
	return out
}

// validAttributes requires a JSON object without secret-looking keys.
func validAttributes(v *ValidationError, raw json.RawMessage) json.RawMessage {
	if len(bytes.TrimSpace(raw)) == 0 || string(bytes.TrimSpace(raw)) == "null" {
		return json.RawMessage(`{}`)
	}
	if len(raw) > maxAttributes {
		v.add("attributes", "Дополнительные параметры больше 32 КБ")
		return raw
	}
	var obj map[string]any
	if err := json.Unmarshal(raw, &obj); err != nil {
		v.add("attributes", "Дополнительные параметры должны быть JSON-объектом")
		return raw
	}
	if key := findBadKey(obj); key != "" {
		v.add("attributes", "Параметр «"+key+"» похож на секрет — сохраните его как ссылку на секрет")
	}
	compact, _ := json.Marshal(obj)
	return compact
}

func findBadKey(value any) string {
	switch val := value.(type) {
	case map[string]any:
		for k, inner := range val {
			if len(k) > maxAttrKey || k == "" {
				return k
			}
			lk := strings.ToLower(strings.ReplaceAll(k, "-", "_"))
			for _, w := range secretKeyWords {
				if strings.Contains(lk, w) {
					return k
				}
			}
			if bad := findBadKey(inner); bad != "" {
				return bad
			}
		}
	case []any:
		for _, inner := range val {
			if bad := findBadKey(inner); bad != "" {
				return bad
			}
		}
	}
	return ""
}

func validRelationLabel(v *ValidationError, kind, label string) string {
	label = cleanText(label)
	if utf8.RuneCountInString(label) > maxLabel {
		v.add("label", "Подпись длиннее 60 символов")
	}
	if kind == "custom" && label == "" {
		v.add("label", "Для своей связи нужна подпись")
	}
	return label
}

// searchText is the lowercased haystack for Unicode-aware search
// (SQLite LIKE folds ASCII case only, names are often Cyrillic).
func searchText(name, description string, address *string, tags []string) string {
	parts := []string{name, description}
	if address != nil {
		parts = append(parts, *address)
	}
	parts = append(parts, tags...)
	return strings.ToLower(strings.Join(parts, "\n"))
}
