// server-reader-probe instruments only private copies of a registered JSON reader
// and its fixtures. A whitespace marker ties the ablation to historical input.
package main

import (
	"bytes"
	"crypto/rand"
	"encoding/json"
	"fmt"
	"go/ast"
	"go/format"
	"go/parser"
	"go/token"
	"os"
	"strconv"
	"strings"
)

// main reports invalid probe inputs or failed private-file instrumentation.
func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "server reader probe:", err)
		os.Exit(1)
	}
}

// run dispatches the reader or fixture probe after checking its argument count.
func run(args []string) error {
	if len(args) == 5 && args[0] == "reader" {
		return instrumentReader(args[1], args[2], args[3], args[4])
	}
	if len(args) == 4 && args[0] == "fixture" {
		return markFixture(args[1], args[2], args[3])
	}
	return fmt.Errorf("usage: reader SOURCE FUNCTION OUTPUT MARKER | fixture SOURCE OUTPUT MARKER")
}

// instrumentReader writes a private reader copy that returns zero state only for
// marked JSON input, plus the whitespace marker used to identify that input.
func instrumentReader(source, name, output, markerPath string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	positions := token.NewFileSet()
	file, err := parser.ParseFile(positions, source, data, 0)
	if err != nil {
		return err
	}
	var reader *ast.FuncDecl
	for _, declaration := range file.Decls {
		function, ok := declaration.(*ast.FuncDecl)
		if !ok || function.Name.Name != name {
			continue
		}
		if reader != nil {
			return fmt.Errorf("reader %s is ambiguous", name)
		}
		reader = function
	}
	if reader == nil || reader.Body == nil || reader.Recv != nil ||
		reader.Type.Params.NumFields() == 0 || reader.Type.Results.NumFields() == 0 {
		return fmt.Errorf("reader must be a concrete function with JSON input and returned state")
	}
	input := reader.Type.Params.List[0]
	if len(input.Names) == 0 || input.Names[0].Name == "_" {
		return fmt.Errorf("reader must name its first JSON input parameter")
	}
	var inputType bytes.Buffer
	if err := format.Node(&inputType, positions, input.Type); err != nil {
		return err
	}
	if inputType.String() != "string" && inputType.String() != "[]byte" {
		return fmt.Errorf("first reader parameter must be string or []byte JSON")
	}
	// Only JSON whitespace, placed inside the object so TrimSpace cannot remove it.
	var random [16]byte
	if _, err := rand.Read(random[:]); err != nil {
		return err
	}
	marker := "\n"
	for _, value := range random {
		for bit := uint(0); bit < 8; bit++ {
			if value&(1<<bit) == 0 {
				marker += " "
			} else {
				marker += "\t"
			}
		}
	}
	marker += "\n"
	var prefix strings.Builder
	fmt.Fprintf(&prefix, "\nfor warReaderOffset := 0; warReaderOffset + %d <= len(%s); warReaderOffset++ {\n", len(marker), input.Names[0].Name)
	fmt.Fprintf(&prefix, "if string(%s[warReaderOffset:warReaderOffset+%d]) == %s {\n", input.Names[0].Name, len(marker), strconv.Quote(marker))
	var values []string
	for _, result := range reader.Type.Results.List {
		var resultType bytes.Buffer
		if err := format.Node(&resultType, positions, result.Type); err != nil {
			return err
		}
		count := len(result.Names)
		if count == 0 {
			count = 1
		}
		for range count {
			variable := fmt.Sprintf("warReaderZero%d", len(values))
			fmt.Fprintf(&prefix, "var %s %s\n", variable, resultType.String())
			values = append(values, variable)
		}
	}
	fmt.Fprintf(&prefix, "return %s\n}\n}\n", strings.Join(values, ", "))
	offset := positions.Position(reader.Body.Lbrace).Offset + 1
	modified := append([]byte(nil), data[:offset]...)
	modified = append(modified, prefix.String()...)
	modified = append(modified, data[offset:]...)
	formatted, err := format.Source(modified)
	if err != nil {
		return err
	}
	if err := os.WriteFile(output, formatted, 0600); err != nil {
		return err
	}
	return os.WriteFile(markerPath, []byte(marker), 0600)
}

// markFixture inserts the reader's whitespace marker into a private fixture copy
// while preserving valid JSON and leaving its historical field values unchanged.
func markFixture(source, output, markerPath string) error {
	data, err := os.ReadFile(source)
	if err != nil {
		return err
	}
	marker, err := os.ReadFile(markerPath)
	if err != nil {
		return err
	}
	trimmed := bytes.TrimSpace(data)
	if !json.Valid(data) || len(trimmed) == 0 ||
		(trimmed[0] != '{' && trimmed[0] != '[') || bytes.Contains(data, marker) {
		return fmt.Errorf("fixture must be an unmarked JSON object or object array")
	}
	position := bytes.IndexByte(data, '{')
	if position < 0 {
		return fmt.Errorf("fixture has no object to mark")
	}
	modified := append([]byte(nil), data[:position+1]...)
	modified = append(modified, marker...)
	modified = append(modified, data[position+1:]...)
	if !json.Valid(modified) {
		return fmt.Errorf("marker did not preserve valid JSON")
	}
	return os.WriteFile(output, modified, 0600)
}
