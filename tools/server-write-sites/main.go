// server-write-sites inventories references to the server's persistence boundaries.
package main

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io"
	"os"
	"path"
	"strconv"
)

// main makes an incomplete inventory a failing guard input.
func main() {
	if err := run(os.Args[1:], os.Stdout); err != nil {
		fmt.Fprintln(os.Stderr, "server write sites:", err)
		os.Exit(1)
	}
}

// run publishes sites only after the entire source file has parsed successfully.
func run(args []string, output io.Writer) error {
	if len(args) != 1 {
		return fmt.Errorf("usage: server-write-sites SOURCE")
	}
	source, err := os.ReadFile(args[0])
	if err != nil {
		return err
	}
	sites, err := writeSites(args[0], source)
	if err != nil {
		return err
	}
	for _, site := range sites {
		if _, err := fmt.Fprintln(output, site); err != nil {
			return err
		}
	}
	return nil
}

// writeSites ignores collection values and inventories method values as well
// as direct calls. It deliberately does not infer schemas from serialized data.
func writeSites(filename string, source []byte) ([]string, error) {
	file, err := parser.ParseFile(token.NewFileSet(), filename, source, 0)
	if err != nil {
		return nil, err
	}
	imports := make(map[string]string)
	for _, spec := range file.Imports {
		name, err := strconv.Unquote(spec.Path.Value)
		if err != nil {
			return nil, err
		}
		alias := path.Base(name)
		if spec.Name != nil {
			alias = spec.Name.Name
		}
		if alias == "." && (name == runtimePath || name == playerstatePath) {
			return nil, fmt.Errorf("dot import hides persistence boundary in %s", filename)
		}
		imports[alias] = name
	}
	var sites []string
	counts := make(map[string]int)
	for _, decl := range file.Decls {
		owner := "package"
		if function, ok := decl.(*ast.FuncDecl); ok {
			owner = function.Name.Name
			if function.Recv != nil && len(function.Recv.List) == 1 {
				receiver := function.Recv.List[0].Type
				if pointer, ok := receiver.(*ast.StarExpr); ok {
					receiver = pointer.X
				}
				// Generic receivers retain their named type rather than type arguments.
				if indexed, ok := receiver.(*ast.IndexExpr); ok {
					receiver = indexed.X
				}
				if indexed, ok := receiver.(*ast.IndexListExpr); ok {
					receiver = indexed.X
				}
				name, ok := receiver.(*ast.Ident)
				if !ok {
					return nil, fmt.Errorf("unsupported receiver in %s", filename)
				}
				owner = name.Name + "." + owner
			}
		}
		ast.Inspect(decl, func(node ast.Node) bool {
			selector, ok := node.(*ast.SelectorExpr)
			if !ok {
				return true
			}
			packagePath := ""
			if name, ok := selector.X.(*ast.Ident); ok && name.Obj == nil {
				packagePath = imports[name.Name]
			}
			kind := ""
			switch {
			case selector.Sel.Name == "StorageWrite" && packagePath != runtimePath:
				kind = "StorageWrite"
			case selector.Sel.Name == "RecordWrite" && packagePath == playerstatePath:
				kind = "RecordWrite"
			}
			if kind != "" {
				key := filename + "|" + owner + "|" + kind
				counts[key]++
				sites = append(sites, fmt.Sprintf("%s|%d", key, counts[key]))
			}
			return true
		})
	}
	return sites, nil
}

const (
	runtimePath     = "github.com/heroiclabs/nakama-common/runtime"
	playerstatePath = "github.com/devantler-tech/world-at-ruin/server/playerstate"
)
