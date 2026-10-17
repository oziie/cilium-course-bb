#!/usr/bin/env bash
#
# install-clis.sh — Install the course CLIs without sudo or container privileges.
#
# Installs: kubectl, kind, helm, cilium-cli, hubble-cli
#
# Unlike setup-ubuntu.sh it does NOT install Docker, call sudo or change sysctls,
# so it runs in an unprivileged container. kind still needs a Docker daemon to
# create clusters: the script only reports whether one is reachable.
#
# Binaries go to /usr/local/bin when it is writable (root in a container),
# otherwise to ~/.local/bin. Override with INSTALL_DIR=/some/dir.
#
# Usage:
#   ./install-clis.sh
#
# Troubleshooting: multi-node kind clusters on a fresh VM can hit the default
# inotify limits (pods crash with "too many open files"). Raise them on the
# host (needs root, so this script does not do it):
#   sudo sysctl fs.inotify.max_user_instances=512 fs.inotify.max_user_watches=524288
#
set -euo pipefail

case "${1:-}" in
  "") ;;
  -h|--help) sed -n '2,21p' "${BASH_SOURCE[0]}"; exit 0 ;;
  *) echo "unknown argument: $1" >&2; exit 1 ;;
esac

# Same pins as bb-image/Dockerfile: bump them together. hubble-cli must match
# the Cilium minor the labs install (1.18): a newer CLI fails against Cilium
# 1.18 with "invalid fieldmask".
KUBECTL_VERSION=v1.37.1
KIND_VERSION=v0.33.0
HELM_VERSION=v3.22.0
CILIUM_CLI_VERSION=v0.20.1
HUBBLE_VERSION=v1.18.6

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
[[ "$(uname -s)" == "Linux" ]] || die "this script targets Linux."

case "$(uname -m)" in
  x86_64)  ARCH=amd64 ;;
  aarch64) ARCH=arm64 ;;
  *) die "unsupported architecture: $(uname -m)" ;;
esac
info "Architecture: ${ARCH}"

# Minimal images (ubuntu:24.04) ship without curl. Installing it needs root,
# which a container usually has; otherwise the image must provide it.
for tool in curl tar sha256sum; do
  have "$tool" && continue
  if [[ $EUID -eq 0 ]] && have apt-get; then
    info "Installing curl and CA certificates"
    apt-get update -qq
    apt-get install -y -qq --no-install-recommends ca-certificates curl >/dev/null
    break
  fi
  die "'${tool}' is required and cannot be installed without root."
done

if [[ -z "${INSTALL_DIR:-}" ]]; then
  if [[ -w /usr/local/bin ]]; then
    INSTALL_DIR=/usr/local/bin
  else
    INSTALL_DIR="$HOME/.local/bin"
  fi
fi
mkdir -p "$INSTALL_DIR"
info "Install directory: ${INSTALL_DIR}"

DL=$(mktemp -d)
trap 'rm -rf "$DL"' EXIT

# ----------------------------------------------------------------------------
# Tools
# ----------------------------------------------------------------------------
install_kubectl() {
  info "Installing kubectl ${KUBECTL_VERSION}"
  curl -fsSLo "$DL/kubectl" "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
  echo "$(curl -fsSL "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256")  $DL/kubectl" \
    | sha256sum --check --status || die "kubectl checksum mismatch"
  install -m 0755 "$DL/kubectl" "$INSTALL_DIR/kubectl"
}

install_kind() {
  info "Installing kind ${KIND_VERSION}"
  ( cd "$DL" \
    && curl -fsSL --remote-name-all \
         "https://github.com/kubernetes-sigs/kind/releases/download/${KIND_VERSION}/kind-linux-${ARCH}{,.sha256sum}" \
    && sha256sum --check --status "kind-linux-${ARCH}.sha256sum" ) \
    || die "kind download or checksum failed"
  install -m 0755 "$DL/kind-linux-${ARCH}" "$INSTALL_DIR/kind"
}

install_helm() {
  local tarball="helm-${HELM_VERSION}-linux-${ARCH}.tar.gz"
  info "Installing helm ${HELM_VERSION}"
  ( cd "$DL" \
    && curl -fsSL --remote-name-all "https://get.helm.sh/${tarball}{,.sha256sum}" \
    && sha256sum --check --status "${tarball}.sha256sum" \
    && tar -xzf "$tarball" --strip-components=1 "linux-${ARCH}/helm" ) \
    || die "helm download or checksum failed"
  install -m 0755 "$DL/helm" "$INSTALL_DIR/helm"
}

# cilium-cli and hubble-cli ship identical release layouts.
install_cilium_style_cli() {
  local name="$1" repo="$2" binary="$3" ver="$4"
  local tarball="${binary}-linux-${ARCH}.tar.gz"
  info "Installing ${name} ${ver}"
  ( cd "$DL" \
    && curl -fsSL --remote-name-all \
         "https://github.com/${repo}/releases/download/${ver}/${tarball}{,.sha256sum}" \
    && sha256sum --check --status "${tarball}.sha256sum" ) \
    || die "${name} download or checksum failed"
  tar -C "$INSTALL_DIR" -xzf "$DL/$tarball" "$binary"
}

install_kubectl
install_kind
install_helm
install_cilium_style_cli "cilium-cli" "cilium/cilium-cli" "cilium" "$CILIUM_CLI_VERSION"
install_cilium_style_cli "hubble-cli" "cilium/hubble"     "hubble" "$HUBBLE_VERSION"

# ----------------------------------------------------------------------------
# Report
# ----------------------------------------------------------------------------
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *) warn "${INSTALL_DIR} is not on PATH. Run: export PATH=\"${INSTALL_DIR}:\$PATH\"" ;;
esac

if have docker && docker info >/dev/null 2>&1; then
  DOCKER_STATUS="reachable: kind can create clusters."
else
  DOCKER_STATUS="NOT reachable: 'kind create cluster' will fail until a daemon is available."
fi

cat <<NEXT

------------------------------------------------------------------
CLIs installed to ${INSTALL_DIR}:
  kubectl ${KUBECTL_VERSION}, kind ${KIND_VERSION}, helm ${HELM_VERSION},
  cilium-cli ${CILIUM_CLI_VERSION}, hubble-cli ${HUBBLE_VERSION}

Docker daemon ${DOCKER_STATUS}
------------------------------------------------------------------
NEXT
