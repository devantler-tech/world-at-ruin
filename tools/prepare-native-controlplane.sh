#!/usr/bin/env bash
# Pin disposable fixture binaries for the native image; never select a cluster.
set -euo pipefail
umask 077
[[ $# == 1 && "$1" == /* && ! -e "$1" ]] || { echo 'A new absolute fixture output directory is required' >&2; exit 1; }
destination="$1"
scratch="$(mktemp -d)"
trap 'rm -rf -- "${scratch}"' EXIT
case "$(uname -m)" in
  x86_64)
    architecture=amd64
    envtest_hash=1d1c453633b72c161a5d5a886cde7ac850be1a2ac796a9e1d4ffacacc64868295bdd2d57aa66cd0c158f5ce510f5dfe3fbc61ac21bd3dcfb875bd70658aa663a
    helm_hash=86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb
    ;;
  aarch64|arm64)
    architecture=arm64
    envtest_hash=ae6a670502988200b0131c943758cfd3d3a58cf4e6247ef7f0e6a6467f1cd9a333c802e86101f0446b1b92a0e327387224e1e44fe1a4693da0929c6e529cfe9a
    helm_hash=31c5794dd55c66a51e6b7d2e2ac7a114ae8b1de41ff1d9ba51748ac973b06a08
    ;;
  *) echo 'Unsupported native fixture architecture' >&2; exit 1 ;;
esac
[[ "$(uname -s)" == Linux ]] || { echo 'Native image fixtures require Linux' >&2; exit 1; }
curl --fail --silent --show-error --location --max-time 120 --retry 2 "https://github.com/kubernetes-sigs/controller-tools/releases/download/envtest-v1.37.0/envtest-v1.37.0-linux-${architecture}.tar.gz" -o "${scratch}/envtest.tar.gz"
printf '%s  %s\n' "${envtest_hash}" "${scratch}/envtest.tar.gz" | sha512sum --check --status
curl --fail --silent --show-error --location --max-time 60 --retry 2 "https://get.helm.sh/helm-v4.3.0-linux-${architecture}.tar.gz" -o "${scratch}/helm.tar.gz"
printf '%s  %s\n' "${helm_hash}" "${scratch}/helm.tar.gz" | sha256sum --check --status
tar -xzf "${scratch}/envtest.tar.gz" -C "${scratch}"
tar -xzf "${scratch}/helm.tar.gz" -C "${scratch}"
agones_version="$(go list -m -f '{{.Version}}' agones.dev/agones)"
[[ "${agones_version}" == v1.61.0 ]] || { echo 'Review the fixture CRD pin with the Agones upgrade' >&2; exit 1; }
agones_directory="$(go list -m -f '{{.Dir}}' agones.dev/agones)"
[[ -n "${agones_directory}" ]] || { echo 'Pinned Agones module unavailable' >&2; exit 1; }
mkdir -- "${destination}"
cp -- "${scratch}/controller-tools/envtest/kube-apiserver" "${scratch}/controller-tools/envtest/etcd" "${scratch}/controller-tools/envtest/kubectl" "${destination}/"
"${scratch}/linux-${architecture}/helm" template native-commit "${agones_directory}/install/helm/agones" --show-only templates/crds/gameserver.yaml > "${destination}/gameserver.yaml"
chmod 755 "${destination}" "${destination}/kube-apiserver" "${destination}/etcd" "${destination}/kubectl"
chmod 644 "${destination}/gameserver.yaml"
