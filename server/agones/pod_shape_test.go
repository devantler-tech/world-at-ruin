package agones

import (
	"testing"

	"agones.dev/agones/pkg/apis"
	agonesv1 "agones.dev/agones/pkg/apis/agones/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"
)

const serviceAccountMountPath = "/var/run/secrets/kubernetes.io/serviceaccount"

type noOpAPIHooks struct{}

func (noOpAPIHooks) ValidateGameServerSpec(*agonesv1.GameServerSpec, *field.Path) field.ErrorList {
	return nil
}

func (noOpAPIHooks) ValidateScheduling(apis.SchedulingStrategy, *field.Path) field.ErrorList {
	return nil
}

func (noOpAPIHooks) MutateGameServerPod(*agonesv1.GameServerSpec, *corev1.Pod) error {
	return nil
}

func (noOpAPIHooks) SetEviction(*agonesv1.Eviction, *corev1.Pod) error {
	return nil
}

// TestOfficialPodShapeShadowsTheZoneCredentialOnly pins the Agones controller
// assumption ADR 0002 depends on. Leaving serviceAccountName unset selects the
// official SDK ServiceAccount path; DisableServiceAccount then shadows that
// token only in the named zone container, while the SDK sidecar retains it.
func TestOfficialPodShapeShadowsTheZoneCredentialOnly(t *testing.T) {
	gameServer := &agonesv1.GameServer{
		ObjectMeta: metav1.ObjectMeta{
			Namespace: "games",
			Name:      "zone-17",
			UID:       "uid-17",
		},
		Spec: agonesv1.GameServerSpec{
			Container: "zone",
			Template: corev1.PodTemplateSpec{
				Spec: corev1.PodSpec{
					Containers: []corev1.Container{{
						Name:  "zone",
						Image: "world-at-ruin/zone:test",
						VolumeMounts: []corev1.VolumeMount{{
							Name:      "admission-wrapping-public-key",
							MountPath: "/var/run/world-at-ruin/admission",
							ReadOnly:  true,
						}},
					}},
					Volumes: []corev1.Volume{{
						Name: "admission-wrapping-public-key",
						VolumeSource: corev1.VolumeSource{
							ConfigMap: &corev1.ConfigMapVolumeSource{
								LocalObjectReference: corev1.LocalObjectReference{
									Name: "zone-admission-wrapping-key",
								},
							},
						},
					}},
				},
			},
		},
	}
	gameServer.ApplyDefaults()
	pod, err := gameServer.Pod(
		noOpAPIHooks{},
		corev1.Container{Name: "agones-gameserver-sidecar", Image: "agones-sdk:test"},
	)
	if err != nil {
		t.Fatalf("build official GameServer pod: %v", err)
	}
	if pod.Spec.ServiceAccountName != "" {
		t.Fatalf(
			"GameServer template set serviceAccountName %q; want empty so Agones installs its SDK identity",
			pod.Spec.ServiceAccountName,
		)
	}
	if pod.Spec.AutomountServiceAccountToken != nil && !*pod.Spec.AutomountServiceAccountToken {
		t.Fatal("pod disables service-account automount; the SDK sidecar would lose its credential")
	}

	// This is the exact opinionated controller branch: it installs the SDK
	// identity, then shadows that credential only in Spec.Container.
	pod.Spec.ServiceAccountName = "agones-sdk"
	if err := gameServer.DisableServiceAccount(pod); err != nil {
		t.Fatalf("shadow zone service account: %v", err)
	}

	zone := findPodContainer(t, pod, "zone")
	sidecar := findPodContainer(t, pod, "agones-gameserver-sidecar")
	if !hasMount(zone, serviceAccountMountPath) {
		t.Fatal("zone container retained the Kubernetes service-account token")
	}
	if hasMount(sidecar, serviceAccountMountPath) {
		t.Fatal("SDK sidecar token was shadowed; SetAnnotation/WatchGameServer/Ready would be unauthorized")
	}
	if pod.Spec.ServiceAccountName != "agones-sdk" {
		t.Fatalf("pod service account = %q, want the official SDK identity", pod.Spec.ServiceAccountName)
	}
	for _, volume := range pod.Spec.Volumes {
		if volume.Secret != nil {
			t.Fatalf("pod volume %q mounts a Kubernetes Secret; want public ConfigMap input only", volume.Name)
		}
	}
}

func findPodContainer(t *testing.T, pod *corev1.Pod, name string) corev1.Container {
	t.Helper()
	for _, container := range pod.Spec.Containers {
		if container.Name == name {
			return container
		}
	}
	for _, container := range pod.Spec.InitContainers {
		if container.Name == name {
			return container
		}
	}
	t.Fatalf("pod has no %q container", name)
	return corev1.Container{}
}

func hasMount(container corev1.Container, path string) bool {
	for _, mount := range container.VolumeMounts {
		if mount.MountPath == path {
			return true
		}
	}
	return false
}
