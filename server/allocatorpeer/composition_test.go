package allocatorpeer

import (
	"errors"
	"go/parser"
	"go/token"
	"io/fs"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

const packagePath = "github.com/devantler-tech/world-at-ruin/server/allocatorpeer"

// Examine every production Go source; require real entrypoints so the walk
// cannot silently succeed from an empty or wrong working directory.
func uncomposed(root string) error {
	required := map[string]bool{"cmd/zone/main.go": false, "cmd/nakama/main.go": false, "nakamaruntime/module.go": false, "agonesresources/adapter.go": false}
	err := filepath.WalkDir(root, func(path string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		relative, err := filepath.Rel(root, path)
		if err != nil {
			return err
		}
		if entry.IsDir() {
			if relative == "allocatorpeer" {
				return filepath.SkipDir
			}
			return nil
		}
		if !strings.HasSuffix(path, ".go") || strings.HasSuffix(path, "_test.go") {
			return nil
		}
		if _, exists := required[filepath.ToSlash(relative)]; exists {
			required[filepath.ToSlash(relative)] = true
		}
		data, err := fs.ReadFile(os.DirFS(root), filepath.ToSlash(relative))
		if err != nil {
			return err
		}
		return rejectComposition(data)
	})
	if err != nil {
		return err
	}
	for _, found := range required {
		if !found {
			return errors.New("allocator peer: missing production entrypoint")
		}
	}
	return nil
}

func rejectComposition(data []byte) error {
	source, err := parser.ParseFile(token.NewFileSet(), "composition.go", data, parser.ImportsOnly)
	if err != nil {
		return err
	}
	for _, imported := range source.Imports {
		path, err := strconv.Unquote(imported.Path.Value)
		if err != nil {
			return err
		}
		if path == packagePath {
			return errors.New("allocator peer: production activation requires separate delivery")
		}
	}
	return nil
}

func TestProductionDoesNotActivatePeerTransport(t *testing.T) {
	if err := uncomposed(".."); err != nil {
		t.Fatal(err)
	}
}

func TestCompositionGuardControls(t *testing.T) {
	if err := uncomposed(t.TempDir()); err == nil {
		t.Fatal("empty production walk passed")
	}
	for _, literal := range []string{strconv.Quote(packagePath), "`" + packagePath + "`", "\"\\x67" + packagePath[1:] + "\""} {
		for _, alias := range []string{"", "renamed ", ". ", "_ "} {
			if rejectComposition([]byte("package fixture\nimport "+alias+literal)) == nil {
				t.Fatal("activated import passed")
			}
		}
	}
	if err := rejectComposition([]byte("package fixture\nimport \"fmt\"")); err != nil {
		t.Fatal(err)
	}
}
