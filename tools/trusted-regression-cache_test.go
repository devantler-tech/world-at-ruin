package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestTrustedCacheRejectsRedirection checks missing, ambiguous and redirected metadata.
func TestTrustedCacheRejectsRedirection(t *testing.T) {
	project := t.TempDir()
	for _, dir := range []string{"tests", "scripts", ".godot"} {
		if err := os.Mkdir(filepath.Join(project, dir), 0700); err != nil {
			t.Fatal(err)
		}
	}
	write := func(path, body string) {
		t.Helper()
		if err := os.WriteFile(filepath.Join(project, path), []byte(body), 0600); err != nil {
			t.Fatal(err)
		}
	}
	write("tests/support.gd", "class_name TrustedSupport\nextends RefCounted\n")
	write("scripts/product.gd", "class_name Product\nextends RefCounted\n")
	entry := func(name, path string) string {
		return `{"base": &"RefCounted","class": &"` + name + `","icon":"","is_abstract":false,"is_tool":false,"language": &"GDScript","path":"res://` + path + `"}`
	}
	valid := "list=[" + entry("TrustedSupport", "tests/support.gd") + "," + entry("Product", "scripts/product.gd") + "]"
	write(".godot/global_script_class_cache.cfg", valid)
	if err := validateCache(project); err != nil {
		t.Fatalf("valid cache: %v", err)
	}
	write(".godot/evil.gd", "class_name TrustedSupport\nextends RefCounted\n")
	for name, bad := range map[string]string{
		"redirect":        strings.ReplaceAll(valid, "tests/support.gd", "scripts/product.gd"),
		"cache redirect":  strings.ReplaceAll(valid, "tests/support.gd", ".godot/evil.gd"),
		"duplicate":       "list=[" + entry("TrustedSupport", "tests/support.gd") + "," + entry("TrustedSupport", "tests/support.gd") + "]",
		"missing":         "list=[" + entry("Product", "scripts/product.gd") + "]",
		"tool":            strings.Replace(valid, `"is_tool":false`, `"is_tool":true`, 1),
		"unknown":         strings.Replace(valid, `"icon":""`, `"icon":"","script":"unsafe"`, 1),
		"case alias":      strings.Replace(valid, `"class": &"TrustedSupport"`, `"class": &"TrustedSupport","Class":"Product"`, 1),
		"duplicate field": strings.Replace(valid, `"path":"res://tests/support.gd"`, `"path":"res://tests/support.gd","path":"res://scripts/product.gd"`, 1),
		"missing field":   strings.Replace(valid, `"is_tool":false,`, ``, 1),
		"constructor":     `list=[Object("Script")]`,
		"trailing":        valid + "\nlist=[]",
	} {
		t.Run(name, func(t *testing.T) {
			write(".godot/global_script_class_cache.cfg", bad)
			if err := validateCache(project); err == nil {
				t.Fatal("poisoned cache accepted")
			}
		})
	}
	write(".godot/global_script_class_cache.cfg", valid)
	if err := os.Remove(filepath.Join(project, "scripts/product.gd")); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../tests/support.gd", filepath.Join(project, "scripts/product.gd")); err != nil {
		t.Fatal(err)
	}
	if err := validateCache(project); err == nil {
		t.Fatal("source symlink accepted")
	}
}
