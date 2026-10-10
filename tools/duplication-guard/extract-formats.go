//go:build ignore

// Generate the independent extension inventory from the pinned upstream Rust
// table. The data is MIT-licensed; only names/extensions are retained.
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"regexp"
)

func main() {
	if len(os.Args) != 3 {
		panic("usage: extract-formats RUST-TABLE OUTPUT")
	}
	data, err := os.ReadFile(os.Args[1])
	if err != nil {
		panic(err)
	}
	entries := regexp.MustCompile(`name:\s*"([^"]+)",\s*extensions:\s*&\[([^\]]*)\]`).FindAllSubmatch(data, -1)
	if len(entries) != 224 {
		panic(fmt.Sprintf("unexpected upstream format count: %d", len(entries)))
	}
	result := make(map[string]string)
	for _, entry := range entries {
		for _, ext := range regexp.MustCompile(`"([^"]+)"`).FindAllSubmatch(entry[2], -1) {
			result[string(ext[1])] = string(entry[1])
		}
	}
	output, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		panic(err)
	}
	if err := os.WriteFile(os.Args[2], append(output, '\n'), 0o644); err != nil {
		panic(err)
	}
}
