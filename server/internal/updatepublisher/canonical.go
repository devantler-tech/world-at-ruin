// Package updatepublisher implements offline update-publication tooling.
// No game or server composition imports this package.
package updatepublisher

import (
	"bytes"
	"encoding/json"
	"errors"
	"io"
	"math/big"
	"slices"
	"strconv"
	"strings"
	"unicode/utf16"
	"unicode/utf8"
)

const MaxDocumentBytes = 1 << 20
const maxSafeInteger = 9007199254740992

// Canonicalize uses the client's bounded integer-only RFC8785 domain.
func Canonicalize(raw []byte) ([]byte, error) {
	v, err := parseJSON(raw)
	if err != nil {
		return nil, err
	}
	var out strings.Builder
	if err := writeCanonical(&out, v); err != nil {
		return nil, err
	}
	return []byte(out.String()), nil
}
func parseJSON(raw []byte) (any, error) {
	if len(raw) > MaxDocumentBytes || !utf8.Valid(raw) {
		return nil, errors.New("JSON size or UTF-8 is invalid")
	}
	if err := checkEscapedUnicode(raw); err != nil {
		return nil, err
	}
	d := json.NewDecoder(bytes.NewReader(raw))
	d.UseNumber()
	v, err := readValue(d, 0)
	if err != nil {
		return nil, err
	}
	if _, err := d.Token(); !errors.Is(err, io.EOF) {
		return nil, errors.New("JSON has trailing input")
	}
	return v, nil
}
func readValue(d *json.Decoder, depth int) (any, error) {
	if depth > 64 {
		return nil, errors.New("JSON nesting exceeds 64 levels")
	}
	token, err := d.Token()
	if err != nil {
		return nil, errors.New("invalid JSON")
	}
	switch v := token.(type) {
	case json.Delim:
		switch v {
		case '{':
			obj := map[string]any{}
			for d.More() {
				k, err := d.Token()
				if err != nil {
					return nil, errors.New("invalid JSON key")
				}
				name, ok := k.(string)
				if !ok {
					return nil, errors.New("invalid JSON key")
				}
				if _, seen := obj[name]; seen {
					return nil, errors.New("duplicate JSON key")
				}
				value, err := readValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				obj[name] = value
			}
			end, err := d.Token()
			if err != nil || end != json.Delim('}') {
				return nil, errors.New("invalid JSON object")
			}
			return obj, nil
		case '[':
			values := []any{}
			for d.More() {
				value, err := readValue(d, depth+1)
				if err != nil {
					return nil, err
				}
				values = append(values, value)
			}
			end, err := d.Token()
			if err != nil || end != json.Delim(']') {
				return nil, errors.New("invalid JSON array")
			}
			return values, nil
		default:
			return nil, errors.New("unexpected JSON delimiter")
		}
	case json.Number:
		number := string(v)
		if len(number) > 128 {
			return nil, errors.New("number spelling exceeds the bounded signing domain")
		}
		if at := strings.LastIndexAny(number, "eE"); at >= 0 {
			exp, err := strconv.ParseInt(number[at+1:], 10, 32)
			if err != nil || exp < -1024 || exp > 1024 {
				return nil, errors.New("number exponent exceeds the bounded signing domain")
			}
		}
		r, ok := new(big.Rat).SetString(number)
		if !ok || !r.IsInt() || r.Num().Cmp(big.NewInt(maxSafeInteger)) > 0 || r.Num().Cmp(big.NewInt(-maxSafeInteger)) < 0 {
			return nil, errors.New("number is outside the shared exact integer domain")
		}
		return json.Number(r.Num().String()), nil
	default:
		return token, nil
	}
}

// Go replaces lone surrogate escapes; reject them before decoding can hide them.
func checkEscapedUnicode(raw []byte) error {
	inside := false
	for i := 0; i < len(raw); i++ {
		if raw[i] == '"' {
			inside = !inside
			continue
		}
		if !inside || raw[i] != '\\' {
			continue
		}
		i++
		if i >= len(raw) {
			return errors.New("invalid string escape")
		}
		if raw[i] != 'u' {
			continue
		}
		if i+4 >= len(raw) {
			return errors.New("invalid Unicode escape")
		}
		value, err := strconv.ParseUint(string(raw[i+1:i+5]), 16, 16)
		if err != nil {
			return errors.New("invalid Unicode escape")
		}
		i += 4
		if value >= 0xdc00 && value <= 0xdfff {
			return errors.New("unpaired Unicode surrogate")
		}
		if value < 0xd800 || value > 0xdbff {
			continue
		}
		if i+6 >= len(raw) || raw[i+1] != '\\' || raw[i+2] != 'u' {
			return errors.New("unpaired Unicode surrogate")
		}
		low, err := strconv.ParseUint(string(raw[i+3:i+7]), 16, 16)
		if err != nil || low < 0xdc00 || low > 0xdfff {
			return errors.New("unpaired Unicode surrogate")
		}
		i += 6
	}
	return nil
}
func writeCanonical(out *strings.Builder, v any) error {
	switch value := v.(type) {
	case nil:
		out.WriteString("null")
	case bool:
		out.WriteString(strconv.FormatBool(value))
	case string:
		quote(out, value)
	case json.Number:
		out.WriteString(string(value))
	case []any:
		out.WriteByte('[')
		for i, child := range value {
			if i > 0 {
				out.WriteByte(',')
			}
			if err := writeCanonical(out, child); err != nil {
				return err
			}
		}
		out.WriteByte(']')
	case map[string]any:
		keys := make([]string, 0, len(value))
		for key := range value {
			keys = append(keys, key)
		}
		slices.SortFunc(keys, func(a, b string) int { return slices.Compare(utf16.Encode([]rune(a)), utf16.Encode([]rune(b))) })
		out.WriteByte('{')
		for i, key := range keys {
			if i > 0 {
				out.WriteByte(',')
			}
			quote(out, key)
			out.WriteByte(':')
			if err := writeCanonical(out, value[key]); err != nil {
				return err
			}
		}
		out.WriteByte('}')
	default:
		return errors.New("unsupported signing value")
	}
	return nil
}
func quote(out *strings.Builder, v string) {
	out.WriteByte('"')
	for _, r := range v {
		switch r {
		case '"':
			out.WriteString("\\\"")
		case '\\':
			out.WriteString("\\\\")
		case '\b':
			out.WriteString("\\b")
		case '\t':
			out.WriteString("\\t")
		case '\n':
			out.WriteString("\\n")
		case '\f':
			out.WriteString("\\f")
		case '\r':
			out.WriteString("\\r")
		default:
			if r < 0x20 {
				const hex = "0123456789abcdef"
				out.WriteString("\\u00")
				out.WriteByte(hex[r>>4])
				out.WriteByte(hex[r&15])
			} else {
				out.WriteRune(r)
			}
		}
	}
	out.WriteByte('"')
}
func object(raw []byte) (map[string]any, error) {
	v, err := parseJSON(raw)
	if err != nil {
		return nil, err
	}
	obj, ok := v.(map[string]any)
	if !ok {
		return nil, errors.New("document must be a JSON object")
	}
	return obj, nil
}
func encode(v any) ([]byte, error) {
	raw, err := json.Marshal(v)
	if err != nil {
		return nil, errors.New("document cannot be encoded")
	}
	return Canonicalize(raw)
}
