// Trusted regression import metadata is data, never executable authority.
package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"regexp"
	"strings"
)

type classEntry struct {
	Base     string `json:"base"`
	Class    string `json:"class"`
	Icon     string `json:"icon"`
	Abstract bool   `json:"is_abstract"`
	Tool     bool   `json:"is_tool"`
	Language string `json:"language"`
	Path     string `json:"path"`
}

var declaration = regexp.MustCompile(`(?m)^class_name[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:#[^\n]*)?$`)
var baseDeclaration = regexp.MustCompile(`(?m)^extends[ \t]+([A-Za-z_][A-Za-z0-9_]*)[ \t]*(?:#[^\n]*)?$`)

func regularBytes(path string) ([]byte, error) {
	info, err := os.Lstat(path)
	if err != nil {
		return nil, err
	}
	if !info.Mode().IsRegular() || info.Size() > 16*1024*1024 {
		return nil, fmt.Errorf("invalid metadata or source file")
	}
	return os.ReadFile(path)
}

// ConfigFile's StringName prefix is the only non-JSON syntax admitted.
// Object constructors, resources, trailing fields and ambiguous variants fail.
func decodeCache(data []byte) ([]classEntry, error) {
	data = bytes.TrimSpace(data)
	if !bytes.HasPrefix(data, []byte("list=")) {
		return nil, fmt.Errorf("missing class list")
	}
	data = data[5:]
	var normalized bytes.Buffer
	quoted, escaped := false, false
	for i := 0; i < len(data); i++ {
		c := data[i]
		if !quoted && c == '&' {
			if i+1 >= len(data) || data[i+1] != '"' {
				return nil, fmt.Errorf("invalid StringName")
			}
			continue
		}
		normalized.WriteByte(c)
		if escaped {
			escaped = false
			continue
		}
		if quoted && c == '\\' {
			escaped = true
			continue
		}
		if c == '"' {
			quoted = !quoted
		}
	}
	decoder := json.NewDecoder(bytes.NewReader(normalized.Bytes()))
	decoder.DisallowUnknownFields()
	var rows []json.RawMessage
	if err := decoder.Decode(&rows); err != nil {
		return nil, err
	}
	var extra any
	if err := decoder.Decode(&extra); err != io.EOF {
		return nil, fmt.Errorf("trailing class metadata")
	}
	entries := make([]classEntry, 0, len(rows))
	allowed := map[string]bool{"base": true, "class": true, "icon": true, "is_abstract": true, "is_tool": true, "language": true, "path": true}
	for _, row := range rows {
		fields := json.NewDecoder(bytes.NewReader(row))
		first, err := fields.Token()
		if err != nil || first != json.Delim('{') {
			return nil, fmt.Errorf("invalid class object")
		}
		seen := map[string]bool{}
		for fields.More() {
			key, err := fields.Token()
			if err != nil {
				return nil, err
			}
			name, ok := key.(string)
			if !ok || !allowed[name] || seen[name] {
				return nil, fmt.Errorf("unknown or duplicate class field")
			}
			seen[name] = true
			var value json.RawMessage
			if err := fields.Decode(&value); err != nil {
				return nil, err
			}
			if bytes.Equal(value, []byte("null")) {
				return nil, fmt.Errorf("null class field")
			}
		}
		if len(seen) != len(allowed) {
			return nil, fmt.Errorf("incomplete class metadata")
		}
		var entry classEntry
		if err := json.Unmarshal(row, &entry); err != nil {
			return nil, err
		}
		entries = append(entries, entry)
	}
	return entries, nil
}

func validateCache(project string) error {
	entries, err := decodeCacheFile(filepath.Join(project, ".godot", "global_script_class_cache.cfg"))
	if err != nil {
		return err
	}
	reserved := map[string]classEntry{}
	err = filepath.WalkDir(filepath.Join(project, "tests"), func(path string, entry os.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if entry.IsDir() || !strings.HasSuffix(path, ".gd") {
			return nil
		}
		data, err := regularBytes(path)
		if err != nil {
			return err
		}
		match := declaration.FindSubmatch(data)
		if match == nil {
			return nil
		}
		base := baseDeclaration.FindSubmatch(data)
		if base == nil {
			return fmt.Errorf("unsupported trusted class base")
		}
		name := string(match[1])
		if _, exists := reserved[name]; exists {
			return fmt.Errorf("duplicate trusted class")
		}
		relative, err := filepath.Rel(project, path)
		if err != nil {
			return err
		}
		reserved[name] = classEntry{Class: name, Base: string(base[1]), Language: "GDScript", Path: "res://" + filepath.ToSlash(relative)}
		return nil
	})
	if err != nil {
		return err
	}
	seen := map[string]bool{}
	for _, entry := range entries {
		if entry.Class == "" || seen[entry.Class] {
			return fmt.Errorf("empty or duplicate imported class")
		}
		seen[entry.Class] = true
		relative := strings.TrimPrefix(entry.Path, "res://")
		if relative == entry.Path || filepath.ToSlash(filepath.Clean(relative)) != relative || filepath.IsAbs(relative) || strings.HasPrefix(relative, ".") || !strings.HasSuffix(relative, ".gd") {
			return fmt.Errorf("imported class escaped source paths")
		}
		// Reject symlinked components, including paths back into the writable cache.
		current := project
		for _, part := range strings.Split(relative, "/") {
			current = filepath.Join(current, part)
			info, err := os.Lstat(current)
			if err != nil {
				return err
			}
			if info.Mode()&os.ModeSymlink != 0 {
				return fmt.Errorf("symlinked imported class")
			}
		}
		source, err := regularBytes(current)
		if err != nil {
			return err
		}
		match := declaration.FindSubmatch(source)
		if match == nil || string(match[1]) != entry.Class || entry.Language != "GDScript" {
			return fmt.Errorf("imported class disagrees with immutable source")
		}
		if expected, exists := reserved[entry.Class]; exists {
			if entry != expected {
				return fmt.Errorf("trusted harness class mapping was rewritten")
			}
		}
	}
	for name := range reserved {
		if !seen[name] {
			return fmt.Errorf("trusted harness class missing from import cache")
		}
	}
	return nil
}

func decodeCacheFile(path string) ([]classEntry, error) {
	data, err := regularBytes(path)
	if err != nil {
		return nil, err
	}
	return decodeCache(data)
}

func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: trusted-regression-cache <immutable-client>")
		os.Exit(2)
	}
	if err := validateCache(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, "trusted import cache refused:", err)
		os.Exit(1)
	}
	fmt.Println("trusted import cache verified")
}
