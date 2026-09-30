// Validate the rendered zone bundle against its host-owned network boundary.
package main

import (
	"bytes"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

// validateDocuments checks complete Kustomize output, not source filenames.
func validateDocuments(input io.Reader) error {
	decoder := yaml.NewDecoder(input)
	count := 0
	for {
		var resource struct {
			APIVersion string `yaml:"apiVersion"`
			Kind       string `yaml:"kind"`
		}
		err := decoder.Decode(&resource)
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("decode rendered deployment: %w", err)
		}
		if resource.APIVersion == "" && resource.Kind == "" {
			return errors.New("empty rendered document")
		}
		if resource.APIVersion == "" || resource.Kind == "" {
			return errors.New("rendered document requires apiVersion and kind")
		}
		group, _, _ := strings.Cut(resource.APIVersion, "/")
		if group == "networking.k8s.io" && resource.Kind == "NetworkPolicy" {
			return errors.New("standard NetworkPolicy is host-owned; remove it from the tenant bundle")
		}
		count++
	}
	if count == 0 {
		return errors.New("empty rendered deployment")
	}
	return nil
}

// validateDirectory resolves nested resources and Lists through real Kustomize.
func validateDirectory(ctx context.Context, directory string) error {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "kubectl", "kustomize", ".")
	command.Dir = directory
	command.WaitDelay = 5 * time.Second
	rendered, err := command.Output()
	if err != nil {
		return fmt.Errorf("render deployment: %w", err)
	}
	return validateDocuments(bytes.NewReader(rendered))
}

// main exposes the same rendered-bundle check used by CI to local operators.
func main() {
	if len(os.Args) != 2 {
		fmt.Fprintln(os.Stderr, "usage: deploy-manifests <deployment-directory>")
		os.Exit(2)
	}
	if err := validateDirectory(context.Background(), os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
	fmt.Println("Rendered zone manifests use host-owned network isolation")
}
