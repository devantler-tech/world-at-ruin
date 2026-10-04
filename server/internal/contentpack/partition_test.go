package contentpack

import (
	"bytes"
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// TestPartitionIsCompleteOrderedAndKeepsRecoveryOutsideThePack covers selection and link refusal.
func TestPartitionIsCompleteOrderedAndKeepsRecoveryOutsideThePack(t *testing.T) {
	dir := t.TempDir()
	for name, data := range map[string]string{"assets/b.txt": "b", "assets/a.txt": "a", "scripts/shell/recover.gd": "base", "scripts/boot_recovery.gd": "base", "tests/trick.txt": "test", "project.godot": "settings"} {
		if err := os.MkdirAll(filepath.Join(dir, filepath.Dir(name)), 0700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(dir, name), []byte(data), 0600); err != nil {
			t.Fatal(err)
		}
	}
	got, err := Partition(dir)
	if err != nil || len(got) != 2 || got[0].Path != "assets/a.txt" || got[1].Path != "assets/b.txt" {
		t.Fatalf("partition %#v %v", got, err)
	}
	if err := os.Symlink("a.txt", filepath.Join(dir, "assets/link.txt")); err != nil {
		t.Fatal(err)
	}
	if _, err := Partition(dir); err == nil {
		t.Fatal("source link accepted")
	}
}

// TestReceiptRejectsChangedPackAndChangedResourceInventory covers exact bytes, shape and inventory.
func TestReceiptRejectsChangedPackAndChangedResourceInventory(t *testing.T) {
	resources := []Resource{{Path: "assets/a.txt", SHA256: Digest([]byte("a")), Size: 1}}
	receipt, err := NewReceipt([]byte("native pack"), resources)
	if err != nil {
		t.Fatal(err)
	}
	if err := Verify([]byte("native pack"), resources, receipt); err != nil {
		t.Fatal(err)
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, receipt, "", "  "); err != nil {
		t.Fatal(err)
	}
	if err := Verify([]byte("native pack"), resources, pretty.Bytes()); err == nil {
		t.Fatal("noncanonical receipt verified")
	}
	if err := Verify([]byte("other pack"), resources, receipt); err == nil {
		t.Fatal("replaced pack verified")
	}
	resources[0].SHA256 = Digest([]byte("b"))
	if err := Verify([]byte("native pack"), resources, receipt); err == nil {
		t.Fatal("changed inventory verified")
	}
}

// TestStageRefusesPhysicalSourceAliasesBeforeCreatingAnything covers links and native case aliases.
func TestStageRefusesPhysicalSourceAliasesBeforeCreatingAnything(t *testing.T) {
	parent := t.TempDir()
	source := filepath.Join(parent, "project")
	if err := os.MkdirAll(filepath.Join(source, "assets"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "assets", "a.txt"), []byte("a"), 0600); err != nil {
		t.Fatal(err)
	}
	alias := filepath.Join(parent, "alias")
	if err := os.Symlink(source, alias); err != nil {
		t.Fatal(err)
	}
	pathsToTest := [][2]string{{source, filepath.Join(alias, "work")}, {alias, filepath.Join(source, "work")}}
	caseAlias := filepath.Join(parent, strings.ToUpper(filepath.Base(source)))
	if original, err := os.Stat(source); err == nil {
		if other, err := os.Stat(caseAlias); err == nil && os.SameFile(original, other) {
			pathsToTest = append(pathsToTest, [2]string{source, filepath.Join(caseAlias, "work")})
		}
	}
	for _, paths := range pathsToTest {
		if err := Stage(paths[0], paths[1]); err == nil {
			t.Fatal("staging through a physical source alias accepted")
		}
		if _, err := os.Stat(filepath.Join(source, "work")); !os.IsNotExist(err) {
			t.Fatalf("alias refusal created a staging directory: %v", err)
		}
	}
}

// TestProtectedRecoveryCannotBeInsertedIntoAnInventory fences owners and all remap companions.
func TestProtectedRecoveryCannotBeInsertedIntoAnInventory(t *testing.T) {
	for _, name := range []string{"scripts/boot_recovery.gd", "scripts/boot_recovery.gd.uid", "scripts/boot_recovery.gd.remap", "scripts/BOOT_RECOVERY.gd.remap", "scripts/shell/new_owner.gd", "tests/hidden.tres", "tools/hidden.gd", "project.godot", ".godot/global_script_class_cache.cfg", "assets/../project.godot"} {
		if err := ValidateInventory([]Resource{{Path: name, SHA256: Digest([]byte("replacement")), Size: 11}}); err == nil {
			t.Errorf("protected path %s accepted", name)
		}
	}
}

// TestFreshScriptRemainsInTheCumulativeSelection leaves UID creation to clean native import.
func TestFreshScriptRemainsInTheCumulativeSelection(t *testing.T) {
	dir := t.TempDir()
	if err := os.Mkdir(filepath.Join(dir, "scripts"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "scripts", "new.gd"), []byte("extends RefCounted\n"), 0600); err != nil {
		t.Fatal(err)
	}
	if resources, err := Partition(dir); err != nil || len(resources) != 1 || resources[0].Path != "scripts/new.gd" {
		t.Fatalf("fresh script was not selected: %#v %v", resources, err)
	}
}

// TestFinalizeRefusesOutputInsidePhysicalSource prevents publication from changing caller sources.
func TestFinalizeRefusesOutputInsidePhysicalSource(t *testing.T) {
	parent := t.TempDir()
	source := filepath.Join(parent, "source")
	if err := os.MkdirAll(filepath.Join(source, "assets"), 0700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(source, "assets", "a.txt"), []byte("a"), 0600); err != nil {
		t.Fatal(err)
	}
	work := filepath.Join(parent, "work")
	if err := Stage(source, work); err != nil {
		t.Fatal(err)
	}
	resources, err := Partition(source)
	if err != nil {
		t.Fatal(err)
	}
	inventory, err := json.Marshal(resources)
	if err != nil {
		t.Fatal(err)
	}
	for name, raw := range map[string][]byte{"content.pck": []byte("native bytes"), "resources.json": inventory} {
		if err := os.WriteFile(filepath.Join(work, name), raw, 0600); err != nil {
			t.Fatal(err)
		}
	}
	alias := filepath.Join(parent, "alias")
	if err := os.Symlink(source, alias); err != nil {
		t.Fatal(err)
	}
	outputs := []string{filepath.Join(alias, "assets", "output")}
	caseAlias := filepath.Join(parent, "SOURCE")
	if original, err := os.Stat(source); err == nil {
		if other, err := os.Stat(caseAlias); err == nil && os.SameFile(original, other) {
			outputs = append(outputs, filepath.Join(caseAlias, "assets", "output"))
		}
	}
	for _, output := range outputs {
		if err := Finalize(source, work, output); err == nil {
			t.Fatal("final artifact was written into the source project")
		}
		if _, err := os.Stat(filepath.Join(source, "assets", "output")); !os.IsNotExist(err) {
			t.Fatalf("finalization refusal created output: %v", err)
		}
	}
}
