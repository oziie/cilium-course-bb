#!/usr/bin/env bash
#
# setup-ubuntu.sh — Prepare an Ubuntu host for the Cilium & eBPF course labs.
#
# Installs: Docker Engine, kubectl, kind, helm, cilium-cli, hubble-cli
# Creates : a 3-node kind cluster with the default CNI disabled
#
# Tested on Ubuntu 22.04 / 24.04 (amd64, arm64).
#
# Usage:
#   ./setup-ubuntu.sh                 # install tools + create the cluster
#   ./setup-ubuntu.sh --tools-only    # install tools, skip the cluster
#   ./setup-ubuntu.sh --cluster-only  # skip tools, create the cluster
#   ./setup-ubuntu.sh --name mylab --config /path/to/kind.yaml
#
set -euo pipefail

CLUSTER_NAME="kind"
KIND_CONFIG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/../scenario-1-installation-cilium/light-lab.yaml"
DO_TOOLS=true
DO_CLUSTER=true

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools-only)   DO_CLUSTER=false; shift ;;
    --cluster-only) DO_TOOLS=false;   shift ;;
    --name)         CLUSTER_NAME="$2"; shift 2 ;;
    --config)       KIND_CONFIG="$2";  shift 2 ;;
    -h|--help)      sed -n '2,20p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 1 ;;
  esac
done

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux (Ubuntu)."
[[ $EUID -ne 0 ]] || die "run as a normal user, not root — the script calls sudo where needed."
have sudo || die "sudo is required."

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
info "Architecture: ${ARCH}"

if [[ -r /etc/os-release ]]; then
  . /etc/os-release
  [[ "${ID:-}" == "ubuntu" ]] || warn "not Ubuntu (${PRETTY_NAME:-unknown}) — continuing anyway."
fi

# A 3-node kind cluster running Cilium needs headroom.
CPUS=$(nproc)
MEM_GB=$(( $(awk '/MemTotal/ {print $2}' /proc/meminfo) / 1024 / 1024 ))
(( CPUS  >= 4 )) || warn "only ${CPUS} CPUs detected — 4+ recommended."
(( MEM_GB >= 7 )) || warn "only ${MEM_GB} GiB RAM detected — 8+ GiB recommended."

# ----------------------------------------------------------------------------
# Tools
# ----------------------------------------------------------------------------
install_docker() {
  if have docker; then
    info "Docker already installed: $(docker --version)"
  else
    info "Installing Docker Engine from the official Docker apt repository"
    sudo apt-get update -qq
    sudo apt-get install -y -qq ca-certificates curl gnupg
    sudo install -m 0755 -d /etc/apt/keyrings
    sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
      -o /etc/apt/keyrings/docker.asc
    sudo chmod a+r /etc/apt/keyrings/docker.asc
    echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu ${UBUNTU_CODENAME:-$VERSION_CODENAME} stable" \
      | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null
    sudo apt-get update -qq
    sudo apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin
  fi

  sudo systemctl enable --now docker

  if ! id -nG "$USER" | tr ' ' '\n' | grep -qx docker; then
    info "Adding ${USER} to the 'docker' group"
    sudo usermod -aG docker "$USER"
    warn "Group membership applies to NEW logins. Run 'newgrp docker' (or log out and back in) before using kind."
  fi
}

install_kubectl() {
  if have kubectl; then
    info "kubectl already installed: $(kubectl version --client -o yaml 2>/dev/null | awk '/gitVersion/{print $2; exit}')"
    return
  fi
  local ver
  ver=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
  info "Installing kubectl ${ver}"
  curl -fsSLo /tmp/kubectl "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}/kubectl"
  curl -fsSLo /tmp/kubectl.sha256 "https://dl.k8s.io/release/${ver}/bin/linux/${ARCH}/kubectl.sha256"
  echo "$(cat /tmp/kubectl.sha256)  /tmp/kubectl" | sha256sum --check --status \
    || die "kubectl checksum mismatch"
  sudo install -o root -g root -m 0755 /tmp/kubectl /usr/local/bin/kubectl
  rm -f /tmp/kubectl /tmp/kubectl.sha256
}

install_kind() {
  if have kind; then
    info "kind already installed: $(kind --version)"
    return
  fi
  local ver release_json
  # Fetch the whole response first: piping curl into `grep -m1` makes grep exit
  # early, curl then fails with error 23 and pipefail aborts the script.
  release_json=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest)
  ver=$(grep -m1 '"tag_name"' <<<"$release_json" | cut -d'"' -f4)
  [[ -n "$ver" ]] || die "could not resolve the latest kind release"
  info "Installing kind ${ver}"
  curl -fsSLo /tmp/kind "https://kind.sigs.k8s.io/dl/${ver}/kind-linux-${ARCH}"
  sudo install -o root -g root -m 0755 /tmp/kind /usr/local/bin/kind
  rm -f /tmp/kind
}

install_helm() {
  if have helm; then
    info "helm already installed: $(helm version --short)"
    return
  fi
  info "Installing helm (official get-helm-3 installer)"
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 \
    -o /tmp/get-helm-3
  chmod +x /tmp/get-helm-3
  /tmp/get-helm-3
  rm -f /tmp/get-helm-3
}

# cilium-cli and hubble-cli ship identical release layouts.
install_cilium_style_cli() {
  local name="$1" repo="$2" binary="$3"
  if have "$binary"; then
    info "${name} already installed at $(command -v "$binary")"
    return
  fi
  local ver tarball
  ver=$(curl -fsSL "https://raw.githubusercontent.com/${repo}/main/stable.txt")
  tarball="${binary}-linux-${ARCH}.tar.gz"
  info "Installing ${name} ${ver}"
  curl -fsSL --remote-name-all \
    "https://github.com/${repo}/releases/download/${ver}/${tarball}{,.sha256sum}" \
    --output-dir /tmp
  ( cd /tmp && sha256sum --check --status "${tarball}.sha256sum" ) \
    || die "${name} checksum mismatch"
  sudo tar -C /usr/local/bin -xzf "/tmp/${tarball}"
  rm -f "/tmp/${tarball}" "/tmp/${tarball}.sha256sum"
}

tune_inotify() {
  # kind runs every node as a container; each kubelet/containerd consumes inotify
  # watches on the host. Ubuntu defaults are too low for multi-node clusters and
  # cause pods to hang in ContainerCreating or CrashLoopBackOff.
  info "Raising inotify limits for multi-node kind clusters"
  sudo tee /etc/sysctl.d/99-kind.conf >/dev/null <<'SYSCTL'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL
  sudo sysctl -q --system
}

if [[ "$DO_TOOLS" == true ]]; then
  install_docker
  install_kubectl
  install_kind
  install_helm
  install_cilium_style_cli "cilium-cli" "cilium/cilium-cli" "cilium"
  install_cilium_style_cli "hubble-cli" "cilium/hubble"     "hubble"
  tune_inotify
fi

# ----------------------------------------------------------------------------
# Cluster
# ----------------------------------------------------------------------------
if [[ "$DO_CLUSTER" == true ]]; then
  docker info >/dev/null 2>&1 \
    || die "cannot talk to the Docker daemon. Run 'newgrp docker' (or re-login) and try again."
  [[ -f "$KIND_CONFIG" ]] || die "kind config not found: ${KIND_CONFIG}"

  if kind get clusters 2>/dev/null | grep -qx "$CLUSTER_NAME"; then
    warn "kind cluster '${CLUSTER_NAME}' already exists — skipping creation."
    warn "Delete it first with: kind delete cluster --name ${CLUSTER_NAME}"
  else
    info "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
    kind create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
  fi

  info "Cluster nodes (NotReady is EXPECTED until Cilium is installed):"
  kubectl get nodes -o wide || true
  info "Pending pods (coredns / local-path-provisioner) are also expected:"
  kubectl get pods -A || true

  cat <<'NEXT'

------------------------------------------------------------------
Environment ready.

Nodes are NotReady and coredns is Pending on purpose: the kind
config sets disableDefaultCNI: true, so the cluster has no CNI yet.

Next: scenario-1-installation-cilium/instructions-scenario-1.md
      installs Cilium via Helm and the nodes turn Ready.
------------------------------------------------------------------
NEXT
fi
