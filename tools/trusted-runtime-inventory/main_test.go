package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// inventoryFixture supplies packages and metadata with an explicit terminal record.
func inventoryFixture() string {
	var b strings.Builder
	b.WriteString("WAR_RUNTIME_INVENTORY\t1\namd64\n")
	for name, version := range directPins {
		fmt.Fprintf(&b, "package\t%s\t%s\tamd64\tinstalled\n", name, version)
	}
	b.WriteString("package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\n")
	b.WriteString("package\tapt\t2.8.3\tamd64\tinstalled\n")
	for _, path := range []string{"/var/lib/apt/lists/snapshot_InRelease", "/var/lib/apt/lists/snapshot_main_binary-amd64_Packages.lz4", "/etc/apt/sources.list.d/ubuntu.sources", "/etc/apt/apt.conf.d/50snapshot", "/usr/share/keyrings/ubuntu-archive-keyring.gpg", "/etc/ssl/certs/ca-certificates.crt"} {
		digest, size := strings.Repeat("a", 64), 123
		if strings.HasSuffix(path, "_InRelease") {
			digest, size = strings.Repeat("d", 64), 789
		}
		if strings.Contains(path, "_Packages") {
			path, digest, size = strings.TrimSuffix(path, ".lz4"), strings.Repeat("c", 64), 456
		}
		fmt.Fprintf(&b, "file\t%s\t%d\t%s\n", digest, size, path)
	}
	b.WriteString(transactionRecords())
	fmt.Fprintf(&b, "engine\t%s\nEND\n", strings.Repeat("b", 64))
	return b.String()
}

// transactionRecords separates inherited identities from the archives acquired before install.
func transactionRecords() string {
	var b strings.Builder
	b.WriteString("apt-version\t2.8.3\nbase-package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\nbase-package\tapt\t2.8.3\tamd64\tinstalled\n")
	fmt.Fprintf(&b, "target\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t%s\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\t/var/lib/apt/lists/snapshot_InRelease\t789\t%s\n", strings.Repeat("c", 64), strings.Repeat("d", 64))
	for name, version := range directPins {
		fmt.Fprintf(&b, "argument\t%s=%s\n", name, version)
		fmt.Fprintf(&b, "plan\thttps://snapshot.ubuntu.com/test/%s.deb\t%s.deb\t123\t%s\n", name, name, strings.Repeat("a", 64))
		fmt.Fprintf(&b, "archive\t%s.deb\t%s\t%s\tamd64\t123\t%s\n", name, name, version, strings.Repeat("a", 64))
		fmt.Fprintf(&b, "origin\t%s.deb\t%s\t%s\tamd64\ttest/%s.deb\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t%s\t/var/lib/apt/lists/snapshot_InRelease\t789\t%s\n", name, name, version, name, strings.Repeat("c", 64), strings.Repeat("d", 64))
	}
	b.WriteString("transaction-complete\n")
	return b.String()
}

// TestTransactionObservationsNeverAcceptPartialPlans keeps plausible prefixes fail closed.
func TestTransactionObservationsNeverAcceptPartialPlans(t *testing.T) {
	raw := inventoryFixture()
	mutations := map[string]string{
		"total archive budget":        strings.ReplaceAll(raw, "\t123\t", "\t67108864\t"),
		"no baseline":                 strings.ReplaceAll(raw, "base-package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\n", ""),
		"missing completion":          strings.ReplaceAll(raw, "transaction-complete\n", ""),
		"missing plan":                strings.ReplaceAll(raw, "plan\thttps://snapshot.ubuntu.com/test/libgl1.deb\tlibgl1.deb\t123\t"+strings.Repeat("a", 64)+"\n", ""),
		"missing archive":             strings.ReplaceAll(raw, "archive\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\t123\t"+strings.Repeat("a", 64)+"\n", ""),
		"missing target":              strings.ReplaceAll(raw, "target\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t"+strings.Repeat("c", 64)+"\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\t/var/lib/apt/lists/snapshot_InRelease\t789\t"+strings.Repeat("d", 64)+"\n", ""),
		"missing origin":              strings.ReplaceAll(raw, "origin\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\ttest/libgl1.deb\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t"+strings.Repeat("c", 64)+"\t/var/lib/apt/lists/snapshot_InRelease\t789\t"+strings.Repeat("d", 64)+"\n", ""),
		"wrong tuple":                 strings.Replace(raw, "archive\tlibgl1.deb\tlibgl1\t1.7.0-1build1", "archive\tlibgl1.deb\tlibgl1\t99", 1),
		"origin tuple mismatch":       strings.Replace(raw, "origin\tlibgl1.deb\tlibgl1\t1.7.0-1build1", "origin\tlibgl1.deb\tlibgl1\t99", 1),
		"untrusted origin":            strings.Replace(raw, "\tmain\tamd64\tyes\tUbuntu", "\tmain\tamd64\tno\tUbuntu", 1),
		"bad origin digest":           strings.Replace(raw, "\t456\t"+strings.Repeat("c", 64), "\t456\tbad", 1),
		"same size corruption":        strings.Replace(raw, "archive\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\t123\t"+strings.Repeat("a", 64), "archive\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\t123\t"+strings.Repeat("c", 64), 1),
		"wrong argument":              strings.Replace(raw, "argument\tlibgl1=1.7.0-1build1", "argument\tlibgl1=99", 1),
		"duplicate archive":           strings.Replace(raw, "transaction-complete", "archive\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\t123\t"+strings.Repeat("a", 64)+"\ntransaction-complete", 1),
		"duplicate origin":            strings.Replace(raw, "transaction-complete", "origin\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\ttest/libgl1.deb\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble/\tnoble\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble\tnoble\thttps://snapshot.ubuntu.com/dists/noble/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_main_binary-amd64_Packages\t456\t"+strings.Repeat("c", 64)+"\t/var/lib/apt/lists/snapshot_InRelease\t789\t"+strings.Repeat("d", 64)+"\ntransaction-complete", 1),
		"trailing transaction":        strings.Replace(raw, "transaction-complete\n", "transaction-complete\napt-version\t2.8.3\n", 1),
		"unaccounted inherited":       strings.Replace(raw, "base-package\tbase-files\t13ubuntu10.3", "base-package\tother-files\t13ubuntu10.3", 1),
		"duplicate plan":              strings.Replace(raw, "transaction-complete", "plan\thttps://snapshot.ubuntu.com/test/libgl1.deb\tlibgl1.deb\t123\t"+strings.Repeat("a", 64)+"\ntransaction-complete", 1),
		"credential URI":              strings.Replace(raw, "https://snapshot.ubuntu.com/test/libgl1.deb", "https://user@snapshot.ubuntu.com/test/libgl1.deb", 1),
		"escaped filename":            strings.Replace(raw, "\tlibgl1.deb\t123", "\t../libgl1.deb\t123", 1),
		"oversized archive":           strings.Replace(raw, "\tlibgl1.deb\t123", "\tlibgl1.deb\t67108865", 1),
		"wrong apt version":           strings.Replace(raw, "apt-version\t2.8.3", "apt-version\t99", 1),
		"redundant inherited archive": strings.Replace(raw, "transaction-complete", "base-package\tlibgl1\t1.7.0-1build1\tamd64\tinstalled\ntransaction-complete", 1),
	}
	for name, changed := range mutations {
		t.Run(name, func(t *testing.T) {
			if changed == raw {
				t.Fatal("negative control did not alter the observation")
			}
			if _, err := parseInventory([]byte(changed), strings.Repeat("b", 64)); err == nil {
				t.Fatal("accepted incomplete transaction")
			}
		})
	}
}

// TestTransactionUpgrade replaces a baseline version while preserving every inherited identity.
func TestTransactionUpgrade(t *testing.T) {
	raw := strings.Replace(inventoryFixture(), "transaction-complete", "base-package\tlibgl1\t1.0\tamd64\tinstalled\ntransaction-complete", 1)
	got, err := parseInventory([]byte(raw), strings.Repeat("b", 64))
	if err != nil || len(got.Transaction.Inherited) != 3 || len(got.Transaction.Archives) != 10 {
		t.Fatalf("complete upgrade refused: %v", err)
	}
}

// TestObservedInventory checks full inventory capture and deterministic report ordering.
func TestObservedInventory(t *testing.T) {
	got, err := parseInventory([]byte(inventoryFixture()), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	if len(got.Packages) != 12 || len(got.Files) != 6 || got.Architecture != "amd64" || len(got.Transaction.Archives) != 10 || len(got.Transaction.Inherited) != 2 || len(got.Transaction.Targets) != 1 || len(got.Transaction.Archives[0].Origins) != 1 || got.Transaction.Archives[0].Origins[0].Index.SHA256 == "" || !got.Transaction.Archives[0].Origins[0].Trusted {
		t.Fatalf("incomplete inventory: %+v", got)
	}
	other, err := parseInventory([]byte(inventoryFixture()), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	var a, b bytes.Buffer
	if err = writeReport(got, &a); err != nil {
		t.Fatal(err)
	}
	if err = writeReport(other, &b); err != nil {
		t.Fatal(err)
	}
	if a.String() != b.String() {
		t.Fatal("map iteration changed canonical report")
	}
}

func TestTransactionRetainsEveryAuthenticatedOriginForOneArchive(t *testing.T) {
	indexHash, releaseHash := strings.Repeat("c", 64), strings.Repeat("d", 64)
	files := fmt.Sprintf("file\t%s\t456\t/var/lib/apt/lists/snapshot_updates_main_binary-amd64_Packages\nfile\t%s\t789\t/var/lib/apt/lists/snapshot_updates_InRelease\n", indexHash, releaseHash)
	target := fmt.Sprintf("target\thttps://snapshot.ubuntu.com/dists/noble-updates/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_updates_main_binary-amd64_Packages\t456\t%s\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble-updates/\tnoble-updates\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble-updates\tnoble-updates\t/var/lib/apt/lists/snapshot_updates_InRelease\t789\t%s\n", indexHash, releaseHash)
	origin := fmt.Sprintf("origin\tlibgl1.deb\tlibgl1\t1.7.0-1build1\tamd64\ttest/libgl1.deb\thttps://snapshot.ubuntu.com/\thttps://snapshot.ubuntu.com/dists/noble-updates/\tnoble-updates\tmain\tamd64\tyes\tUbuntu\tUbuntu\tnoble-updates\tnoble-updates\thttps://snapshot.ubuntu.com/dists/noble-updates/main/binary-amd64/Packages\t/var/lib/apt/lists/snapshot_updates_main_binary-amd64_Packages\t456\t%s\t/var/lib/apt/lists/snapshot_updates_InRelease\t789\t%s\n", indexHash, releaseHash)
	raw := strings.Replace(inventoryFixture(), "transaction-complete\n", files+target+origin+"transaction-complete\n", 1)
	got, err := parseInventory([]byte(raw), strings.Repeat("b", 64))
	if err != nil {
		t.Fatal(err)
	}
	for _, archive := range got.Transaction.Archives {
		if archive.Name == "libgl1" && len(archive.Origins) == 2 && len(got.Transaction.Targets) == 2 {
			return
		}
	}
	t.Fatal("complete authenticated origin set not retained")
}

func TestArchiveOriginAcceptsAPTsEncodedRepositoryFilename(t *testing.T) {
	request := "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/pool/f/foo_1.0%2bds%7ebeta%251_amd64.deb"
	index := "https://snapshot.ubuntu.com/ubuntu/20261003T000000Z/dists/noble/main/binary-amd64/Packages"
	filename := "pool/f/foo_1.0+ds~beta%1_amd64.deb"
	if !requestMatchesOrigin(request, index, "noble", filename) {
		t.Fatal("APT-encoded archive URI did not match its package filename")
	}
	if requestMatchesOrigin(request, index, "other", filename) || requestMatchesOrigin("http://archive.ubuntu.com/ubuntu/"+filename, index, "noble", filename) {
		t.Fatal("accepted an archive outside the selected snapshot index namespace")
	}
}

// TestIncompleteAndAmbiguousInventory refuses missing, duplicate and conflicting records.
func TestIncompleteAndAmbiguousInventory(t *testing.T) {
	original := inventoryFixture()
	cases := map[string]string{
		"partial":            strings.TrimSuffix(original, "END\n"),
		"trailing":           original + "package\tlate\t1\tamd64\tinstalled\n",
		"duplicate":          strings.Replace(original, "END\n", "package\tbase-files\t13ubuntu10.3\tamd64\tinstalled\nEND\n", 1),
		"wrong pin":          strings.Replace(original, "2.15.0-1.1ubuntu2", "99", 1),
		"wrong architecture": strings.Replace(original, "\namd64\n", "\narm64\n", 1),
		"unconfigured":       strings.Replace(original, "\tinstalled\n", "\tunpacked\n", 1),
		"missing indexes":    strings.ReplaceAll(original, "/var/lib/apt/lists/", "/etc/apt/"),
		"missing signature":  strings.ReplaceAll(original, "_InRelease", "_Other"),
		"escape":             strings.Replace(original, "/etc/apt/apt.conf.d/50snapshot", "/etc/apt/../private", 1),
		"duplicate file":     strings.Replace(original, "END\n", "file\t"+strings.Repeat("a", 64)+"\t123\t/etc/apt/apt.conf.d/50snapshot\nEND\n", 1),
		"unknown":            strings.Replace(original, "package\tbase-files", "mystery\tbase-files", 1),
		"oversize":           original + strings.Repeat("x", maximumInventoryBytes),
		"empty":              "",
	}
	for name, raw := range cases {
		t.Run(name, func(t *testing.T) {
			if _, err := parseInventory([]byte(raw), strings.Repeat("b", 64)); err == nil {
				t.Fatal("accepted incomplete inventory")
			}
		})
	}
	if _, err := parseInventory([]byte(original), strings.Repeat("c", 64)); err == nil {
		t.Fatal("accepted wrong engine")
	}
}

// TestImageContract rejects a partial inspection or a different execution boundary.
func TestImageContract(t *testing.T) {
	good := `[{"Id":"sha256:` + strings.Repeat("a", 64) + `","Os":"linux","Architecture":"amd64","Config":{"User":"1001:1001","WorkingDir":"/project","Entrypoint":["/usr/local/bin/godot"]}}]`
	if _, err := parseImage([]byte(good)); err != nil {
		t.Fatal(err)
	}
	for _, bad := range []string{good + "[]", good[:len(good)-2], strings.Replace(good, "amd64", "arm64", 1), strings.Replace(good, "1001:1001", "0", 1), strings.Replace(good, "/project", "/", 1), strings.Replace(good, "/usr/local/bin/godot", "/bin/sh", 1)} {
		if _, err := parseImage([]byte(bad)); err == nil {
			t.Fatal("accepted wrong image contract")
		}
	}
}

type shortReportWriter struct{}

// Write simulates an output sink that accepts only part of a report.
func (shortReportWriter) Write(raw []byte) (int, error) { return len(raw) - 1, nil }

// TestReportWriteFailure ensures a short output write cannot succeed.
func TestReportWriteFailure(t *testing.T) {
	if writeReport(inventory{}, shortReportWriter{}) == nil {
		t.Fatal("partial write became complete report")
	}
}

// TestDiagnosticSelection keeps the default inert and rejects unknown selections.
func TestDiagnosticSelection(t *testing.T) {
	var output bytes.Buffer
	if err := run(nil, &output); err != nil || output.Len() != 0 {
		t.Fatal("default mode observed or emitted data")
	}
	if err := run([]string{"--unknown"}, &output); err == nil || output.Len() != 0 {
		t.Fatal("unknown selection admitted")
	}
}

// TestRecipeReadsAreBoundedAndObserveChangedBytes exercises real file replacement and refusal paths.
func TestRecipeReadsAreBoundedAndObserveChangedBytes(t *testing.T) {
	path := filepath.Join(t.TempDir(), "builder.sh")
	if err := os.WriteFile(path, []byte("first recipe"), 0600); err != nil {
		t.Fatal(err)
	}
	before, err := fileIdentity(path, "tools/builder.sh", 32)
	if err != nil {
		t.Fatal(err)
	}
	if err = os.WriteFile(path, []byte("changed recipe"), 0600); err != nil {
		t.Fatal(err)
	}
	after, err := fileIdentity(path, "tools/builder.sh", 32)
	if err != nil || before.SHA256 == after.SHA256 {
		t.Fatal("recipe replacement retained prior identity")
	}
	if _, err = boundedFile(path, 2); err == nil {
		t.Fatal("oversized recipe accepted")
	}
	link := path + ".link"
	if err = os.Symlink(path, link); err != nil {
		t.Fatal(err)
	}
	if _, err = boundedFile(link, 32); err == nil {
		t.Fatal("linked recipe accepted")
	}
	if _, err = boundedFile(filepath.Dir(path), 32); err == nil {
		t.Fatal("directory accepted")
	}
	if err = os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err = boundedFile(path, 32); err == nil {
		t.Fatal("missing recipe accepted")
	}
}
