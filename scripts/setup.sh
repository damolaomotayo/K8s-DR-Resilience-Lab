#!/usr/bin/env bash
# One-time setup on a fresh Ubuntu 22.04+ / Amazon Linux 2023 host.
# Installs Docker, kubectl 1.30.5, k3d 5.7.4, Velero 1.14.1, jq, curl, python venv (tests).
set -euo pipefail
KUBECTL_VERSION="${KUBECTL_VERSION:-v1.30.5}"
K3D_VERSION="${K3D_VERSION:-v5.7.4}"
VELERO_VERSION="${VELERO_VERSION:-v1.14.1}"

case "$(uname -m)" in
  x86_64) ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) echo "Unsupported CPU: $(uname -m)" >&2; exit 1 ;;
esac

if command -v apt-get >/dev/null 2>&1; then
  sudo apt-get update -y
  sudo apt-get install -y docker.io curl jq python3 python3-venv python3-pip tar
elif command -v dnf >/dev/null 2>&1; then
  sudo dnf install -y docker curl jq python3 python3-pip tar
else
  echo "Unsupported OS: install docker, curl, jq, python3 manually." >&2; exit 1
fi
sudo systemctl enable --now docker
sudo usermod -aG docker "$USER"

install_bin() { sudo install -m 0755 "$1" "/usr/local/bin/$2"; }
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT

command -v kubectl >/dev/null || { curl -fsSL -o "$TMP/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"; install_bin "$TMP/kubectl" kubectl; }
command -v k3d >/dev/null || { curl -fsSL -o "$TMP/k3d" "https://github.com/k3d-io/k3d/releases/download/${K3D_VERSION}/k3d-linux-${ARCH}"; install_bin "$TMP/k3d" k3d; }
if ! command -v velero >/dev/null; then
  curl -fsSL -o "$TMP/velero.tgz" "https://github.com/vmware-tanzu/velero/releases/download/${VELERO_VERSION}/velero-${VELERO_VERSION}-linux-${ARCH}.tar.gz"
  tar -xzf "$TMP/velero.tgz" -C "$TMP"
  install_bin "$TMP/velero-${VELERO_VERSION}-linux-${ARCH}/velero" velero
fi

cd "$(dirname "$0")/.."
python3 -m venv .venv
.venv/bin/pip install -q -r requirements-dev.txt

echo
kubectl version --client | head -1; k3d version | head -1; velero version --client-only | head -3
echo "Setup complete. IMPORTANT: run 'newgrp docker' (or log out and back in) so docker works without sudo."
