// updatepublisher is an explicitly experimental offline operator command.
// It never discovers keys, reads credentials from the environment, or publishes.
package main

import (
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"time"

	"github.com/devantler-tech/world-at-ruin/server/internal/updatepublisher"
)

func main() {
	if err := run(os.Args[1:]); err != nil {
		fmt.Fprintln(os.Stderr, "updatepublisher:", err)
		os.Exit(1)
	}
}
func run(args []string) error {
	flags := flag.NewFlagSet("updatepublisher", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	experimental := flags.Bool("experimental", false, "explicitly enable offline tooling")
	operation := flags.String("operation", "", "canonicalize, issue, assemble, or verify")
	kind := flags.String("kind", "", "certificate, revocation, or head")
	input := flags.String("input", "", "public JSON input")
	output := flags.String("output", "", "new public JSON output; never overwritten")
	private := flags.String("private-key", "", "explicit owner-only P-256 PEM file")
	root := flags.String("root-public-key", "", "explicit trusted root PEM file")
	cert := flags.String("certificate", "", "root-signed certificate JSON")
	rev := flags.String("revocation", "", "root-signed revocation JSON")
	head := flags.String("head", "", "independently obtained root-signed head JSON")
	observed := flags.String("observed-at", "", "canonical UTC observation")
	if err := flags.Parse(args); err != nil || flags.NArg() != 0 {
		return errors.New("invalid command arguments")
	}
	if !*experimental {
		return errors.New("offline publication is experimental; pass -experimental to opt in")
	}
	if *operation != "canonicalize" && *operation != "issue" && *operation != "assemble" && *operation != "verify" {
		return errors.New("select a supported operation")
	}
	raw, err := readFile(*input, false)
	if err != nil {
		return err
	}
	var result []byte
	if *operation == "canonicalize" {
		result, err = updatepublisher.Canonicalize(raw)
	} else {
		at, timeErr := time.Parse(time.RFC3339, *observed)
		if timeErr != nil || at.UTC().Format(time.RFC3339) != *observed || len(*observed) != 20 {
			return errors.New("observed-at must be explicit canonical UTC")
		}
		switch *operation {
		case "issue":
			keyRaw, keyErr := readFile(*private, true)
			if keyErr != nil {
				return keyErr
			}
			key, keyErr := updatepublisher.ParsePrivateKey(keyRaw)
			if keyErr != nil {
				return keyErr
			}
			result, err = updatepublisher.SignDocument(*kind, raw, key, at)
		case "assemble", "verify":
			rootRaw, rootErr := readFile(*root, false)
			if rootErr != nil {
				return rootErr
			}
			rootKey, rootErr := updatepublisher.ParsePublicKey(rootRaw)
			if rootErr != nil {
				return rootErr
			}
			headRaw, headErr := readFile(*head, false)
			if headErr != nil {
				return headErr
			}
			if *operation == "verify" {
				if *output != "" {
					return errors.New("verification does not write an output")
				}
				return updatepublisher.VerifyBundle(raw, headRaw, rootKey, at)
			}
			certRaw, certErr := readFile(*cert, false)
			if certErr != nil {
				return certErr
			}
			revRaw, revErr := readFile(*rev, false)
			if revErr != nil {
				return revErr
			}
			keyRaw, keyErr := readFile(*private, true)
			if keyErr != nil {
				return keyErr
			}
			key, keyErr := updatepublisher.ParsePrivateKey(keyRaw)
			if keyErr != nil {
				return keyErr
			}
			result, err = updatepublisher.Assemble(raw, certRaw, revRaw, headRaw, rootKey, key, at)
		default:
			return errors.New("unsupported operation")
		}
	}
	if err != nil {
		return err
	}
	return publishNew(*output, result)
}
func readFile(path string, private bool) ([]byte, error) {
	file, err := openInput(path)
	if err != nil {
		return nil, errors.New("required input cannot be opened")
	}
	info, statErr := file.Stat()
	if statErr != nil || !info.Mode().IsRegular() || info.Size() > updatepublisher.MaxDocumentBytes || (private && info.Mode().Perm()&0077 != 0) {
		closeErr := file.Close()
		return nil, errors.Join(errors.New("input must be a bounded regular file; private keys need owner-only permissions"), closeErr)
	}
	raw, readErr := io.ReadAll(io.LimitReader(file, updatepublisher.MaxDocumentBytes+1))
	closeErr := file.Close()
	if readErr != nil || closeErr != nil || len(raw) > updatepublisher.MaxDocumentBytes {
		return nil, errors.New("required input cannot be read completely")
	}
	return raw, nil
}
func publishNew(path string, raw []byte) error {
	if path == "" {
		return errors.New("a new output path is required")
	}
	file, err := os.CreateTemp(filepath.Dir(path), ".updatepublisher-")
	if err != nil {
		return errors.New("cannot stage output")
	}
	temp := file.Name()
	defer func() {
		if removeErr := os.Remove(temp); removeErr != nil && !os.IsNotExist(removeErr) {
			fmt.Fprintln(os.Stderr, "updatepublisher: temporary public output could not be removed")
		}
	}()
	if _, err := file.Write(raw); err != nil {
		closeErr := file.Close()
		return errors.Join(errors.New("cannot stage complete output"), closeErr)
	}
	if err := file.Sync(); err != nil {
		closeErr := file.Close()
		return errors.Join(errors.New("cannot sync staged output"), closeErr)
	}
	if err := file.Close(); err != nil {
		return errors.New("cannot close staged output")
	}
	// Linking inside the same directory is atomic and never replaces an existing
	// file or symlink. Failed signing and publication preserve the caller's bytes.
	if err := os.Link(temp, path); err != nil {
		return errors.New("output exists or cannot be published; choose a new path")
	}
	return nil
}
