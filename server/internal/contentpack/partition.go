// Package contentpack implements experimental local build evidence, not update authorization.
package contentpack

import (
	"crypto/sha256"
	_ "embed"
	"encoding/hex"
	"errors"
	"io/fs"
	"os"
	"path"
	"slices"
	"strings"
)

//go:embed shell-resources.txt
var shellResources string

const MaxResourceBytes = 32 << 20
const MaxPackBytes = 256 << 20

type Resource struct {
	Path   string `json:"path"`
	SHA256 string `json:"sha256"`
	Size   int64  `json:"size"`
}

// Digest identifies exact bytes using lowercase SHA-256.
func Digest(raw []byte) string { sum := sha256.Sum256(raw); return hex.EncodeToString(sum[:]) }

// protected fences exact base owners, all companions and the reserved shell namespace.
func protected(name string) bool {
	name = strings.ToLower(name)
	if strings.HasPrefix(name, "scripts/shell/") {
		return true
	}
	for _, shell := range strings.Fields(shellResources) {
		if name == shell || strings.HasPrefix(name, shell+".") || strings.HasPrefix(name, shell+"/") {
			return true
		}
	}
	return false
}

// contentPath admits only portable, non-shell paths under the reviewed content roots.
func contentPath(name string) bool {
	if !fs.ValidPath(name) || strings.ContainsAny(name, "\\\r\n\t:") || protected(name) {
		return false
	}
	root, _, found := strings.Cut(name, "/")
	return found && slices.Contains([]string{"abilities", "assets", "devlog", "recipes", "registries", "scenes", "scripts", "shaders"}, root)
}

// supported limits source inputs to the actual game formats and provenance metadata.
func supported(name string) bool {
	return slices.Contains([]string{".gd", ".uid", ".tscn", ".tres", ".json", ".svg", ".png", ".glb", ".gdshader", ".gdshaderinc", ".wav", ".ogg", ".mp3", ".ttf", ".otf", ".import", ".remap", ".txt", ".md"}, path.Ext(name))
}

// Partition is cumulative: it chooses every supported content file, rather than a diff.
// The reserved shell namespace and exact owners above are deliberately excluded.
func Partition(source string) ([]Resource, error) {
	root, err := os.OpenRoot(source)
	if err != nil {
		return nil, errors.New("source project cannot be opened")
	}
	result, scanErr := partition(root)
	return result, errors.Join(scanErr, root.Close())
}

// partition rejects ambiguous shapes and case collisions before native import starts.
func partition(root *os.Root) ([]Resource, error) {
	result := []Resource{}
	names := map[string]bool{}
	var total int64
	err := fs.WalkDir(root.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if entry.IsDir() {
			if name != "." && !strings.Contains(name, "/") && !slices.Contains([]string{"abilities", "assets", "devlog", "recipes", "registries", "scenes", "scripts", "shaders"}, name) {
				return fs.SkipDir
			}
			if name == "scripts/shell" || strings.HasPrefix(name, "scripts/shell/") {
				return fs.SkipDir
			}
			return nil
		}
		if !contentPath(name) {
			return nil
		}
		if !entry.Type().IsRegular() || !supported(name) {
			return errors.New("content contains a link, special file or unsupported shape")
		}
		folded := strings.ToLower(name)
		if names[folded] {
			return errors.New("content paths collide across supported platforms")
		}
		names[folded] = true
		raw, err := ReadRegular(root, name, MaxResourceBytes)
		if err != nil {
			return err
		}
		total += int64(len(raw))
		if total > MaxPackBytes {
			return errors.New("source content exceeds build budget")
		}
		result = append(result, Resource{Path: name, SHA256: Digest(raw), Size: int64(len(raw))})
		if len(result) > 10000 {
			return errors.New("source resource count exceeds build budget")
		}
		return nil
	})
	if err != nil {
		return nil, err
	}
	slices.SortFunc(result, func(a, b Resource) int { return strings.Compare(a.Path, b.Path) })
	if len(result) == 0 {
		return nil, errors.New("content partition is empty")
	}
	return result, nil
}

// ValidateInventory enforces complete ordered identities within the packaged boundary.
func ValidateInventory(resources []Resource) error {
	if len(resources) == 0 || len(resources) > 10000 {
		return errors.New("resource inventory is empty or exceeds its budget")
	}
	previous := ""
	folded := map[string]bool{}
	var total int64
	for _, r := range resources {
		imported := strings.HasPrefix(r.Path, ".godot/imported/") && fs.ValidPath(r.Path) && !strings.ContainsAny(r.Path, "\\\r\n\t:")
		if (!contentPath(r.Path) && !imported) || (!imported && !supported(r.Path)) || r.Path <= previous || folded[strings.ToLower(r.Path)] || r.Size < 0 || r.Size > MaxResourceBytes || len(r.SHA256) != 64 {
			return errors.New("resource inventory violates the content boundary")
		}
		digest, err := hex.DecodeString(r.SHA256)
		if err != nil || hex.EncodeToString(digest) != r.SHA256 {
			return errors.New("resource digest is not canonical SHA-256")
		}
		previous = r.Path
		folded[strings.ToLower(r.Path)] = true
		total += r.Size
		if total > MaxPackBytes {
			return errors.New("resource inventory exceeds build budget")
		}
	}
	return nil
}
