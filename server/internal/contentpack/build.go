package contentpack

import (
	"encoding/json"
	"errors"
	"io/fs"
	"os"
	"path/filepath"
	"slices"
	"strings"
)

// writeNew exclusively creates one artifact; it never replaces a caller-owned path.
func writeNew(root *os.Root, name string, raw []byte) error {
	file, err := root.OpenFile(name, os.O_CREATE|os.O_EXCL|os.O_WRONLY, 0600)
	if err != nil {
		return err
	}
	_, writeErr := file.Write(raw)
	return errors.Join(writeErr, file.Close())
}

// Stage snapshots trusted source into a new private directory. Native import
// runs there through the Bash driver, leaving the original project's cache alone.
func Stage(source, work string) error {
	if source == "" || work == "" {
		return errors.New("source and new staging directory are required")
	}
	source, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return err
	}
	work, err = physicalDestination(work)
	if err != nil {
		return err
	}
	if err := requireOutside(source, work); err != nil {
		return errors.New("staging must be outside the source project")
	}
	resources, err := Partition(source)
	if err != nil {
		return err
	}
	if err := os.Mkdir(work, 0700); err != nil {
		return errors.New("staging directory must not exist")
	}
	root, err := os.OpenRoot(work)
	if err != nil {
		return err
	}
	stageErr := root.Mkdir("project", 0700)
	if stageErr == nil {
		stageErr = stageProject(source, filepath.Join(work, "project"))
	}
	inventory, marshalErr := json.Marshal(resources)
	if stageErr == nil && marshalErr == nil {
		stageErr = writeNew(root, "selected.json", inventory)
	}
	return errors.Join(stageErr, marshalErr, root.Close())
}

// Finalize reads back native bytes and every staged resource before exclusively
// creating a completed artifact directory. It cannot populate delivery fields.
func Finalize(source, work, output string) error {
	if source == "" || work == "" || output == "" {
		return errors.New("source, staging and new output directory are required")
	}
	source, err := filepath.Abs(source)
	if err != nil {
		return err
	}
	source, err = filepath.EvalSymlinks(source)
	if err != nil {
		return err
	}
	work, err = filepath.Abs(work)
	if err != nil {
		return err
	}
	work, err = filepath.EvalSymlinks(work)
	if err != nil {
		return err
	}
	output, err = physicalDestination(output)
	if err != nil {
		return err
	}
	if err := requireOutside(work, output); err != nil {
		return errors.New("final output must be outside private staging")
	}
	if err := requireOutside(source, output); err != nil {
		return errors.New("final output must be outside the source project")
	}
	workRoot, err := os.OpenRoot(work)
	if err != nil {
		return err
	}
	stageRoot, err := workRoot.OpenRoot("project")
	if err != nil {
		return errors.Join(err, workRoot.Close())
	}
	pack, inventory, receipt, finalizeErr := readBuilt(workRoot, stageRoot)
	closeErr := errors.Join(stageRoot.Close(), workRoot.Close())
	if err := errors.Join(finalizeErr, closeErr); err != nil {
		return err
	}
	return publishDirectory(output, map[string][]byte{"content.pck": pack, "receipt.json": receipt, "resources.json": inventory})
}

// physicalDestination resolves existing parents without creating the final path.
func physicalDestination(path string) (string, error) {
	absolute, err := filepath.Abs(path)
	if err != nil {
		return "", err
	}
	parent, err := filepath.EvalSymlinks(filepath.Dir(absolute))
	if err != nil {
		return "", err
	}
	return filepath.Join(parent, filepath.Base(absolute)), nil
}

// Filesystem identity, not spelling, detects both symbolic and case-folded aliases.
func requireOutside(anchor, destination string) error {
	anchorInfo, err := os.Stat(anchor)
	if err != nil {
		return err
	}
	for parent := filepath.Dir(destination); ; parent = filepath.Dir(parent) {
		info, err := os.Stat(parent)
		if err != nil {
			return err
		}
		if os.SameFile(anchorInfo, info) {
			return errors.New("destination is physically inside staging or source")
		}
		if parent == filepath.Dir(parent) {
			return nil
		}
	}
}

// readBuilt binds every selected and generated resource to independently read bytes.
func readBuilt(workRoot, stageRoot *os.Root) ([]byte, []byte, []byte, error) {
	inventory, err := ReadRegular(workRoot, "resources.json", 8<<20)
	if err != nil {
		return nil, nil, nil, err
	}
	var packed []Resource
	if err := json.Unmarshal(inventory, &packed); err != nil {
		return nil, nil, nil, errors.New("native inventory is invalid")
	}
	if err := ValidateInventory(packed); err != nil {
		return nil, nil, nil, err
	}
	selected, err := ReadRegular(workRoot, "selected.json", 8<<20)
	if err != nil {
		return nil, nil, nil, err
	}
	var expected []Resource
	if err := json.Unmarshal(selected, &expected); err != nil {
		return nil, nil, nil, err
	}
	if err := ValidateInventory(expected); err != nil {
		return nil, nil, nil, err
	}
	byPath := map[string]Resource{}
	for _, r := range packed {
		byPath[r.Path] = r
	}
	for _, r := range expected {
		built, found := byPath[r.Path]
		if !found {
			return nil, nil, nil, errors.New("native pack omitted selected content")
		}
		if !strings.HasSuffix(r.Path, ".import") && built != r {
			return nil, nil, nil, errors.New("source changed after initial content selection")
		}
	}
	for _, r := range packed {
		raw, err := ReadRegular(stageRoot, r.Path, MaxResourceBytes)
		if err != nil || Digest(raw) != r.SHA256 || int64(len(raw)) != r.Size {
			return nil, nil, nil, errors.New("native inventory differs from its staged resource")
		}
	}
	pack, err := ReadRegular(workRoot, "content.pck", MaxPackBytes)
	if err != nil {
		return nil, nil, nil, err
	}
	receipt, err := NewReceipt(pack, packed)
	if err != nil {
		return nil, nil, nil, err
	}
	if err := Verify(pack, packed, receipt); err != nil {
		return nil, nil, nil, err
	}
	return pack, inventory, receipt, nil
}

// stageProject copies the bounded import context while omitting checkout-local caches.
func stageProject(source, destination string) error {
	src, err := os.OpenRoot(source)
	if err != nil {
		return err
	}
	dst, err := os.OpenRoot(destination)
	if err != nil {
		return errors.Join(err, src.Close())
	}
	var snapshotBytes int64
	snapshotFiles := 0
	copyErr := fs.WalkDir(src.FS(), ".", func(name string, entry fs.DirEntry, walkErr error) error {
		if walkErr != nil {
			return walkErr
		}
		if name == "." {
			return nil
		}
		if entry.IsDir() {
			if !strings.Contains(name, "/") && !slices.Contains([]string{"abilities", "assets", "devlog", "recipes", "registries", "scenes", "scripts", "shaders"}, name) {
				return fs.SkipDir
			}
			return dst.Mkdir(name, 0700)
		}
		if !strings.Contains(name, "/") && !slices.Contains([]string{"project.godot", "icon.svg", "icon.svg.import"}, name) {
			return nil
		}
		if !entry.Type().IsRegular() {
			return errors.New("project snapshot contains a link or special file")
		}
		raw, err := ReadRegular(src, name, MaxResourceBytes)
		if err != nil {
			return err
		}
		snapshotBytes += int64(len(raw))
		snapshotFiles++
		if snapshotBytes > MaxPackBytes || snapshotFiles > 10000 {
			return errors.New("whole project snapshot exceeds build budget")
		}
		return writeNew(dst, name, raw)
	})
	return errors.Join(copyErr, src.Close(), dst.Close())
}

// publishDirectory creates a fresh output and writes its completion receipt last.
func publishDirectory(output string, files map[string][]byte) error {
	parent, err := os.OpenRoot(filepath.Dir(output))
	if err != nil {
		return err
	}
	name := filepath.Base(output)
	if err := parent.Mkdir(name, 0700); err != nil {
		return errors.Join(errors.New("output already exists or cannot be created"), parent.Close())
	}
	dst, err := parent.OpenRoot(name)
	if err != nil {
		return errors.Join(err, parent.Close())
	}
	// The receipt is last: directories without it never count as completed builds.
	for _, file := range []string{"content.pck", "resources.json", "receipt.json"} {
		if err := writeNew(dst, file, files[file]); err != nil {
			cleanupErr := errors.Join(dst.Remove("content.pck"), dst.Remove("resources.json"), dst.Remove("receipt.json"), dst.Close(), parent.Remove(name), parent.Close())
			return errors.Join(errors.New("publication failed"), err, cleanupErr)
		}
	}
	return errors.Join(dst.Close(), parent.Close())
}
