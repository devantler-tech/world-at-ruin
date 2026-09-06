// server-collection-literals emits complete decoded Go string literals that name
// Nakama collections. It does not evaluate identifiers or string expressions.
package main

import (
	"fmt"
	"go/scanner"
	"go/token"
	"io"
	"os"
	"regexp"
	"strconv"
)

var collectionName = regexp.MustCompile("^world_at_ruin_[a-z0-9_]+$")

// main reports an incomplete collection inventory as a failed guard input.
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "server collection literals:", err)
		os.Exit(1)
	}
}

// run scans one source file completely before publishing its decoded names.
func run(args []string, output io.Writer) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: server-collection-literals SOURCE")
	}
	source, err := os.ReadFile(args[0])
	if err != nil {
		return fmt.Errorf("read source: %w", err)
	}
	names, err := collectionLiterals(args[0], source)
	if err != nil {
		return err
	}
	for _, name := range names {
		if _, err := fmt.Fprintln(output, name); err != nil {
			return fmt.Errorf("write collection inventory: %w", err)
		}
	}
	return nil
}

// collectionLiterals decodes string tokens using Go's lexical rules. Comments
// and larger string values are data; lexical errors refuse the whole inventory.
func collectionLiterals(filename string, source []byte) ([]string, error) {
	positions := token.NewFileSet()
	file := positions.AddFile(filename, -1, len(source))
	var lexer scanner.Scanner
	var scanErr error
	lexer.Init(file, source, func(position token.Position, message string) {
		if scanErr == nil {
			scanErr = fmt.Errorf("%s: %s", position, message)
		}
	}, 0)
	var names []string
	for {
		position, kind, literal := lexer.Scan()
		if scanErr != nil {
			return nil, scanErr
		}
		if kind == token.EOF {
			return names, nil
		}
		if kind != token.STRING {
			continue
		}
		value, err := strconv.Unquote(literal)
		if err != nil {
			return nil, fmt.Errorf("%s: decode string: %w", positions.Position(position), err)
		}
		if collectionName.MatchString(value) {
			names = append(names, value)
		}
	}
}
