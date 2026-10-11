#!/usr/bin/env bash
#
# create-kind-cluster.sh — Create the kind cluster used by scenarios 1 to 6
# and install Cilium on it.
#
# Layout: 1 control-plane + 2 workers, default CNI (kindnetd) disabled and
# replaced by Cilium (Helm, Scenario 1 settings plus Gateway API). Every scenario folder
# ships the same script and light-lab.yaml; re-running it reuses an existing
# cluster and leaves an existing Cilium installation untouched.
# Scenario 9 only: kube-proxy is disabled in light-lab.yaml, the Gateway API
# CRDs are installed before Cilium, and Cilium is installed from
# cilium-values.yaml with kube-proxy replacement, L2 announcements and Gateway
# API support. An existing Cilium without these settings is an error: re-run
# with --recreate.
# Run setup-ubuntu/setup-ubuntu.sh first.
#
# Usage:
#   ./create-kind-cluster.sh [--name NAME] [--config FILE] [--image IMAGE]
#                            [--cilium-version VER] [--gateway-api-version VER]
#                            [--no-cilium] [--recreate]
#   ./create-kind-cluster.sh --delete [--name NAME]
#
# Options:
#   --name NAME           cluster name (default: kind -> context kind-kind, nodes kind-*)
#   --config FILE         kind config (default: light-lab.yaml next to this script)
#   --image IMAGE         kindest/node image to pin the Kubernetes version (default: kind's)
#   --cilium-version VER  Cilium Helm chart version (default: 1.18.4)
#   --gateway-api-version VER  Gateway API CRD version (default: v1.3.0, matches Cilium 1.18)
#   --no-cilium           create the cluster only; install Cilium yourself (Scenario 1)
#   --recreate            delete the cluster first if it already exists
#   --delete              delete the cluster and its kubeconfig entry, then exit
#
# Environment:
#   KUBECONFIG      kubeconfig file to write (default: ~/.kube/config)
#
set -Eeuo pipefail

# ----------------------------------------------------------------------------
# Helpers
# ----------------------------------------------------------------------------
info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

trap 'rc=$?; printf "\033[1;31m[x]\033[0m line %s: \"%s\" failed (exit %s)\n" \
  "$LINENO" "$BASH_COMMAND" "$rc" >&2; exit "$rc"' ERR

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

# ----------------------------------------------------------------------------
# Arguments
# ----------------------------------------------------------------------------
CLUSTER_NAME="kind"
KIND_CONFIG="${SCRIPT_DIR}/light-lab.yaml"
CILIUM_VALUES="${SCRIPT_DIR}/cilium-values.yaml"
NODE_IMAGE=""
CILIUM_VERSION="1.18.4"
GATEWAY_API_VERSION="v1.3.0"
INSTALL_CILIUM=true
RECREATE=false
DELETE=false

need_value() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     need_value "$@"; CLUSTER_NAME="$2"; shift 2 ;;
    --config)   need_value "$@"; KIND_CONFIG="$2"; shift 2 ;;
    --image)    need_value "$@"; NODE_IMAGE="$2"; shift 2 ;;
    --cilium-version) need_value "$@"; CILIUM_VERSION="$2"; shift 2 ;;
    --gateway-api-version) need_value "$@"; GATEWAY_API_VERSION="$2"; shift 2 ;;
    --no-cilium) INSTALL_CILIUM=false; shift ;;
    --recreate) RECREATE=true; shift ;;
    --delete)   DELETE=true; shift ;;
    -h|--help)  sed -n '2,34p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done

CONTEXT="kind-${CLUSTER_NAME}"

# kind and kubectl both honour KUBECONFIG; pin it to a single file so the
# cluster entry always lands in a known place. A colon-separated list is
# reduced to its first entry, which is where kubectl writes changes.
KUBECONFIG_FILE="${KUBECONFIG:-$HOME/.kube/config}"
KUBECONFIG_FILE="${KUBECONFIG_FILE%%:*}"
export KUBECONFIG="$KUBECONFIG_FILE"

# ----------------------------------------------------------------------------
# Preflight
# ----------------------------------------------------------------------------
tools=(docker kind kubectl)
if $INSTALL_CILIUM && ! $DELETE; then tools+=(helm); fi
for tool in "${tools[@]}"; do
  have "$tool" || die "'${tool}' not found — run setup-ubuntu/setup-ubuntu.sh first."
done

if ! docker info >/dev/null 2>&1; then
  if [[ -S /var/run/docker.sock && ! -w /var/run/docker.sock ]]; then
    die "no permission on the Docker socket — run 'newgrp docker' (or log out and back in)."
  fi
  die "Docker daemon is not reachable — start it with 'sudo systemctl start docker'."
fi

# Capture first: piping into `grep -q` can SIGPIPE kind and, under pipefail,
# report an existing cluster as missing.
cluster_exists() {
  local clusters
  clusters=$(kind get clusters 2>/dev/null) || return 1
  grep -qx "$CLUSTER_NAME" <<<"$clusters"
}

# ----------------------------------------------------------------------------
# Delete mode
# ----------------------------------------------------------------------------
if $DELETE; then
  if cluster_exists; then
    info "Deleting kind cluster '${CLUSTER_NAME}'"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    info "Cluster '${CLUSTER_NAME}' does not exist — nothing to delete."
  fi
  exit 0
fi

[[ -r "$KIND_CONFIG" ]] || die "kind config not found: ${KIND_CONFIG}"
if $INSTALL_CILIUM; then
  [[ -r "$CILIUM_VALUES" ]] || die "Cilium values not found: ${CILIUM_VALUES}"
fi

# The scenarios pin pods to kind-worker / kind-worker2 by hostname.
[[ "$CLUSTER_NAME" == "kind" ]] \
  || warn "cluster name '${CLUSTER_NAME}' renames the nodes; scenario manifests expect 'kind-worker' and 'kind-worker2'."

if [[ "$(uname -s)" == "Linux" ]]; then
  watches=$(sysctl -n fs.inotify.max_user_watches 2>/dev/null || echo 0)
  instances=$(sysctl -n fs.inotify.max_user_instances 2>/dev/null || echo 0)
  (( watches >= 524288 && instances >= 512 )) \
    || warn "inotify limits are low (watches=${watches}, instances=${instances}) — re-run setup-ubuntu.sh."
fi

# ----------------------------------------------------------------------------
# Cluster
# ----------------------------------------------------------------------------
mkdir -p "$(dirname -- "$KUBECONFIG_FILE")"
chmod 700 "$(dirname -- "$KUBECONFIG_FILE")" 2>/dev/null || true

if cluster_exists; then
  if $RECREATE; then
    info "Cluster '${CLUSTER_NAME}' exists — deleting it (--recreate)"
    kind delete cluster --name "$CLUSTER_NAME"
  else
    info "Cluster '${CLUSTER_NAME}' already exists — reusing it (pass --recreate to start fresh)"
  fi
fi

if ! cluster_exists; then
  info "Creating kind cluster '${CLUSTER_NAME}' from ${KIND_CONFIG}"
  create_args=(create cluster --name "$CLUSTER_NAME" --config "$KIND_CONFIG"
               --kubeconfig "$KUBECONFIG_FILE")
  [[ -n "$NODE_IMAGE" ]] && create_args+=(--image "$NODE_IMAGE")
  # No --wait: with the default CNI disabled the nodes stay NotReady until
  # Cilium is installed, so waiting for Ready would always time out.
  kind "${create_args[@]}" || die "kind failed to create cluster '${CLUSTER_NAME}'."
fi

# ----------------------------------------------------------------------------
# Kubeconfig
# ----------------------------------------------------------------------------
info "Writing context '${CONTEXT}' to ${KUBECONFIG_FILE}"
kind export kubeconfig --name "$CLUSTER_NAME" --kubeconfig "$KUBECONFIG_FILE" >/dev/null
kubectl config use-context "$CONTEXT" >/dev/null
chmod 600 "$KUBECONFIG_FILE"

# ----------------------------------------------------------------------------
# Verify
# ----------------------------------------------------------------------------
info "Waiting for the API server to become ready"
for _ in $(seq 1 60); do
  kubectl get --raw='/readyz' >/dev/null 2>&1 && break
  sleep 2
done
kubectl get --raw='/readyz' >/dev/null 2>&1 \
  || die "API server for '${CONTEXT}' did not become ready within 120s."

cp_count=$(kubectl get nodes -l node-role.kubernetes.io/control-plane --no-headers | wc -l)
total_count=$(kubectl get nodes --no-headers | wc -l)
worker_count=$(( total_count - cp_count ))
(( cp_count == 1 && worker_count == 2 )) \
  || die "expected 1 control-plane + 2 workers, found ${cp_count} + ${worker_count} (check ${KIND_CONFIG})."

# ----------------------------------------------------------------------------
# Cilium
# ----------------------------------------------------------------------------
if $INSTALL_CILIUM; then
  # Cilium only starts its Gateway API controller (and the Helm chart only
  # creates the cilium GatewayClass) if these CRDs exist when it is installed.
  # Applying them again is harmless.
  info "Installing Gateway API ${GATEWAY_API_VERSION} CRDs"
  for crd in gatewayclasses gateways httproutes referencegrants grpcroutes; do
    kubectl apply -f "https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/${GATEWAY_API_VERSION}/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml" >/dev/null \
      || die "failed to install the Gateway API CRD '${crd}'."
  done

  # Never upgrade an existing release. An existing Cilium must already have
  # the Scenario 9 features; kube-proxy replacement also needs a cluster
  # created without kube-proxy, so the fix is a new cluster.
  if helm status cilium -n kube-system >/dev/null 2>&1; then
    for key in kube-proxy-replacement enable-l2-announcements enable-gateway-api; do
      value=$(kubectl -n kube-system get configmap cilium-config \
        -o go-template="{{index .data \"${key}\"}}" 2>/dev/null || true)
      [[ "$value" == "true" ]] \
        || die "Cilium is installed without ${key}=true — re-run with --recreate."
    done
    info "Cilium is already installed with the Scenario 9 settings — leaving it as is"
  else
    # Without kube-proxy, the agent reaches the API server directly instead of
    # through the kubernetes Service.
    info "Installing Cilium ${CILIUM_VERSION} with Gateway API (this takes a few minutes)"
    helm upgrade --install cilium cilium --repo https://helm.cilium.io/ \
      -n kube-system \
      --version "$CILIUM_VERSION" \
      --set cluster.name="$CONTEXT" \
      --set k8sServiceHost="${CLUSTER_NAME}-control-plane" \
      --set k8sServicePort=6443 \
      -f "$CILIUM_VALUES" \
      || die "helm failed to install Cilium ${CILIUM_VERSION}."
  fi

  info "Waiting for Cilium and the nodes to become ready"
  kubectl -n kube-system rollout status daemonset/cilium --timeout=300s
  kubectl -n kube-system rollout status daemonset/cilium-envoy --timeout=300s
  kubectl -n kube-system rollout status deployment/cilium-operator --timeout=300s
  kubectl wait --for=condition=Ready nodes --all --timeout=300s >/dev/null \
    || die "nodes did not become Ready — check 'kubectl -n kube-system get pods'."
fi

kubectl get nodes -o wide

if $INSTALL_CILIUM; then
  cat <<NEXT

------------------------------------------------------------------
Cluster '${CLUSTER_NAME}' is up: 1 control-plane + 2 workers, Cilium installed
with kube-proxy replacement, L2 announcements and Gateway API support.
kubectl context : ${CONTEXT}
kubeconfig      : ${KUBECONFIG_FILE}

Check it with: cilium status
Kind network  : docker network inspect kind | grep Subnet   (needed for lb-ippool.yaml)
GatewayClass  : kubectl get gatewayclass   (cilium should be Accepted)
NEXT
else
  cat <<NEXT

------------------------------------------------------------------
Cluster '${CLUSTER_NAME}' is up: 1 control-plane + 2 workers, no CNI.
kubectl context : ${CONTEXT}
kubeconfig      : ${KUBECONFIG_FILE}

Nodes are NotReady and coredns is Pending until a CNI is installed —
that is expected. Install Cilium next, as described in Scenario 1:
  scenario-1-installation-cilium/instructions-scenario-1.md
NEXT
fi

if [[ "$KUBECONFIG_FILE" != "$HOME/.kube/config" ]]; then
  cat <<HINT

This kubeconfig is not kubectl's default. In each new shell run:
  export KUBECONFIG=${KUBECONFIG_FILE}
HINT
fi
echo "------------------------------------------------------------------"
