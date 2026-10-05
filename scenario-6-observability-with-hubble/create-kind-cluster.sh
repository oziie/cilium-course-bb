#!/usr/bin/env bash
#
# create-kind-cluster.sh — Create the kind cluster used by scenarios 1 to 6.
#
# Layout: 1 control-plane + 2 workers, default CNI (kindnetd) disabled so
# Cilium can be installed in Scenario 1. Every scenario folder ships the same
# script and light-lab.yaml; re-running it reuses an existing cluster.
# Run setup-ubuntu/setup-ubuntu.sh first.
#
# Usage:
#   ./create-kind-cluster.sh [--name NAME] [--config FILE] [--image IMAGE] [--recreate]
#   ./create-kind-cluster.sh --delete [--name NAME]
#
# Options:
#   --name NAME     cluster name (default: kind -> context kind-kind, nodes kind-*)
#   --config FILE   kind config (default: light-lab.yaml next to this script)
#   --image IMAGE   kindest/node image to pin the Kubernetes version (default: kind's)
#   --recreate      delete the cluster first if it already exists
#   --delete        delete the cluster and its kubeconfig entry, then exit
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
NODE_IMAGE=""
RECREATE=false
DELETE=false

need_value() { [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "$1 requires a value"; }

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name)     need_value "$@"; CLUSTER_NAME="$2"; shift 2 ;;
    --config)   need_value "$@"; KIND_CONFIG="$2"; shift 2 ;;
    --image)    need_value "$@"; NODE_IMAGE="$2"; shift 2 ;;
    --recreate) RECREATE=true; shift ;;
    --delete)   DELETE=true; shift ;;
    -h|--help)  sed -n '2,23p' "${BASH_SOURCE[0]}"; exit 0 ;;
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
for tool in docker kind kubectl; do
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

kubectl get nodes -o wide

cat <<NEXT

------------------------------------------------------------------
Cluster '${CLUSTER_NAME}' is up: 1 control-plane + 2 workers.
kubectl context : ${CONTEXT}
kubeconfig      : ${KUBECONFIG_FILE}

Nodes are NotReady and coredns is Pending until a CNI is installed —
that is expected. Install Cilium next, as described in Scenario 1:
  scenario-1-installation-cilium/instructions-scenario-1.md
NEXT

if [[ "$KUBECONFIG_FILE" != "$HOME/.kube/config" ]]; then
  cat <<HINT

This kubeconfig is not kubectl's default. In each new shell run:
  export KUBECONFIG=${KUBECONFIG_FILE}
HINT
fi
echo "------------------------------------------------------------------"
