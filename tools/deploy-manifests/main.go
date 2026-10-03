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
	"slices"
	"strings"
	"time"

	"go.yaml.in/yaml/v3"
)

type healthProbe struct {
	Exec *struct {
		Command []string `yaml:"command"`
	} `yaml:"exec"`
	TCPSocket      *struct{} `yaml:"tcpSocket"`
	HTTPGet        *struct{} `yaml:"httpGet"`
	GRPC           *struct{} `yaml:"grpc"`
	TimeoutSeconds int64     `yaml:"timeoutSeconds"`
}

// validateHealthProbe requires verified listener health inside the kubelet deadline.
func validateHealthProbe(probe healthProbe) error {
	expected := []string{
		"/zoneprobe", "-tls-only", "-url", "wss://127.0.0.1:8443/zone",
		"-tls-server-name-file", "/credentials/tls.crt", "-timeout",
	}
	if probe.Exec == nil || probe.TCPSocket != nil || probe.HTTPGet != nil || probe.GRPC != nil ||
		len(probe.Exec.Command) != len(expected)+1 || !slices.Equal(probe.Exec.Command[:len(expected)], expected) {
		return errors.New("zone TLS health requires the verified TLS-only exec command")
	}
	deadline, err := time.ParseDuration(probe.Exec.Command[len(expected)])
	if err != nil || deadline <= 0 || deadline > time.Minute || probe.TimeoutSeconds < 1 || probe.TimeoutSeconds > 60 ||
		deadline >= time.Duration(probe.TimeoutSeconds)*time.Second {
		return errors.New("zone TLS health deadline must be shorter than the kubelet timeout")
	}
	return nil
}

// validateDocuments checks complete Kustomize output, not source filenames.
func validateDocuments(input io.Reader) error {
	return validateBundle(input, false)
}

// validateBundle enforces host policy ownership and, for publication, one healthy zone Deployment.
func validateBundle(input io.Reader, requireZone bool) error {
	decoder := yaml.NewDecoder(input)
	count := 0
	zones := 0
	for {
		var resource struct {
			APIVersion string `yaml:"apiVersion"`
			Kind       string `yaml:"kind"`
			Metadata   struct {
				Name string `yaml:"name"`
			} `yaml:"metadata"`
			Spec struct {
				Template struct {
					Spec struct {
						Containers []struct {
							Name           string      `yaml:"name"`
							ReadinessProbe healthProbe `yaml:"readinessProbe"`
							LivenessProbe  healthProbe `yaml:"livenessProbe"`
						} `yaml:"containers"`
					} `yaml:"spec"`
				} `yaml:"template"`
			} `yaml:"spec"`
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
		if resource.APIVersion == "apps/v1" && resource.Kind == "Deployment" && resource.Metadata.Name == "world-at-ruin-zone" {
			zones++
			found := false
			for _, container := range resource.Spec.Template.Spec.Containers {
				if container.Name != "world-at-ruin" {
					continue
				}
				if found {
					return errors.New("zone TLS health requires exactly one zone container")
				}
				found = true
				if err := validateHealthProbe(container.ReadinessProbe); err != nil {
					return fmt.Errorf("readiness probe: %w", err)
				}
				if err := validateHealthProbe(container.LivenessProbe); err != nil {
					return fmt.Errorf("liveness probe: %w", err)
				}
			}
			if !found {
				return errors.New("zone TLS health container is missing")
			}
		}
		count++
	}
	if count == 0 {
		return errors.New("empty rendered deployment")
	}
	if requireZone && zones != 1 {
		return errors.New("zone TLS health requires exactly one intended zone Deployment")
	}
	return nil
}

// validateDirectory resolves nested resources and Lists through real Kustomize.
func validateDirectory(ctx context.Context, directory string) error {
	rendered, err := renderDirectory(ctx, directory)
	if err != nil {
		return err
	}
	return validateBundle(bytes.NewReader(rendered), true)
}

// renderDirectory expands the actual Kustomization with bounded process cleanup.
func renderDirectory(ctx context.Context, directory string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(ctx, 30*time.Second)
	defer cancel()
	command := exec.CommandContext(ctx, "kubectl", "kustomize", ".")
	command.Dir = directory
	command.WaitDelay = 5 * time.Second
	rendered, err := command.Output()
	if err != nil {
		return nil, fmt.Errorf("render deployment: %w", err)
	}
	return rendered, nil
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
	fmt.Println("Rendered zone manifests use verified TLS health and host-owned network isolation")
}
