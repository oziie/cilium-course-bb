# Setup — Preparing an Ubuntu Host for the Labs

> **Note:** This is the prerequisite step for every scenario in this repository. If you
> are using the Bulut Bilisimciler (BB) hosted lab environment, the cluster and CLIs are
> already provisioned — skip straight to
> [Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md).

Follow this page to build the lab environment on your own machine: a 3-node
[kind](https://kind.sigs.k8s.io/) cluster **with no CNI installed**, ready for Cilium.

**Tested on:** Ubuntu 22.04 LTS and 24.04 LTS (`amd64` and `arm64`).

**Recommended resources:** 4 vCPU, 8 GiB RAM, 20 GiB free disk. A 3-node kind cluster
running Cilium, Envoy and Hubble will struggle below that.

---

## Option A — Automated (recommended)

The script installs every CLI and creates the cluster. It is idempotent: re-running it
skips whatever is already present.

```bash
git clone https://github.com/<your-org>/cilium-course-bb.git
cd cilium-course-bb/setup-ubuntu
./setup-ubuntu.sh
```

Because the script adds your user to the `docker` group, the very first run may stop and
ask you to refresh your group membership. If it does:

```bash
newgrp docker           # or log out and back in
./setup-ubuntu.sh --cluster-only
```

Useful flags:

| Flag | Effect |
| --- | --- |
| `--tools-only` | Install the CLIs, do not create a cluster |
| `--cluster-only` | Skip the CLIs, only create the cluster |
| `--name <name>` | Cluster name (default `kind`) |
| `--config <path>` | kind config file (default `../scenario-1-installation-cilium/light-lab.yaml`) |

Then jump to [Verify the Environment](#verify-the-environment).

---

## Option B — Manual, step by step

Work through this if you want to understand each component, or if the script fails on
your distribution.

### 1. Install Docker Engine

kind runs each Kubernetes node as a Docker container, so Docker is the only hard
dependency.

```bash
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  | sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin
```

Run Docker without `sudo`:

```bash
sudo usermod -aG docker "$USER"
newgrp docker            # or log out and back in
docker run --rm hello-world
```

> **Note:** Do **not** use the `docker.io` package from the Ubuntu archive or the Snap
> package. Both are older and the Snap confinement regularly breaks kind's bind mounts.

### 2. Install kubectl

```bash
KUBECTL_VERSION=$(curl -fsSL https://dl.k8s.io/release/stable.txt)
ARCH=$(dpkg --print-architecture)

curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl"
curl -fsSLO "https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/${ARCH}/kubectl.sha256"
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check

sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl kubectl.sha256

kubectl version --client
```

### 3. Install kind

```bash
KIND_VERSION=$(curl -fsSL https://api.github.com/repos/kubernetes-sigs/kind/releases/latest \
  | grep -m1 '"tag_name"' | cut -d'"' -f4)
ARCH=$(dpkg --print-architecture)

curl -fsSLo ./kind "https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}"
sudo install -o root -g root -m 0755 ./kind /usr/local/bin/kind
rm ./kind

kind --version
```

### 4. Install Helm

Cilium is installed with Helm in Scenario 1.

```bash
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
helm version --short
```

### 5. Install the Cilium CLI

```bash
CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=$(dpkg --print-architecture)

curl -fsSL --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "cilium-linux-${CLI_ARCH}.tar.gz.sha256sum"

sudo tar -C /usr/local/bin -xzf "cilium-linux-${CLI_ARCH}.tar.gz"
rm "cilium-linux-${CLI_ARCH}.tar.gz"{,.sha256sum}

cilium version --client
```

### 6. Install the Hubble CLI

Needed in Scenario 6 (Observability).

```bash
HUBBLE_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/hubble/main/stable.txt)
HUBBLE_ARCH=$(dpkg --print-architecture)

curl -fsSL --remote-name-all \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum"

sudo tar -C /usr/local/bin -xzf "hubble-linux-${HUBBLE_ARCH}.tar.gz"
rm "hubble-linux-${HUBBLE_ARCH}.tar.gz"{,.sha256sum}

hubble version
```

### 7. Raise the host inotify limits

Every kind node is a container with its own kubelet and containerd, and each one consumes
host inotify watches. Ubuntu's defaults are too low for a multi-node cluster — symptoms
are pods stuck in `ContainerCreating` or agents in `CrashLoopBackOff` for no obvious
reason.

```bash
sudo tee /etc/sysctl.d/99-kind.conf > /dev/null <<'SYSCTL'
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
SYSCTL

sudo sysctl --system
```

### 8. Create the kind cluster

The cluster definition lives with Scenario 1 so both pages share one source of truth:

```yaml
# scenario-1-installation-cilium/light-lab.yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true   # Disables kindnetd prior to Cilium install
```

One control-plane node plus two workers gives you two schedulable nodes, which is what
Scenario 2 needs to show *internode* pod-to-pod traffic across the VXLAN tunnel.
`disableDefaultCNI: true` removes kindnetd so Cilium can own the data plane.

```bash
cd cilium-course-bb
kind create cluster --name kind --config scenario-1-installation-cilium/light-lab.yaml
```

> **Note:** kind writes the kubeconfig context automatically. Confirm you are pointed at
> the right cluster with `kubectl config current-context` — it should print
> `kind-kind`, which matches the `cluster.name=kind-kind` Helm value used in Scenario 1.

---

## Verify the Environment

```bash
$ kubectl get nodes
NAME                 STATUS     ROLES           AGE   VERSION
kind-control-plane   NotReady   control-plane   60s   v1.34.0
kind-worker          NotReady   <none>          45s   v1.34.0
kind-worker2         NotReady   <none>          45s   v1.34.0
```

```bash
$ kubectl get pods -A
NAMESPACE            NAME                                         READY   STATUS    RESTARTS
kube-system          coredns-…                                    0/1     Pending   0
kube-system          coredns-…                                    0/1     Pending   0
kube-system          etcd-kind-control-plane                      1/1     Running   0
kube-system          kube-apiserver-kind-control-plane            1/1     Running   0
kube-system          kube-controller-manager-kind-control-plane   1/1     Running   0
kube-system          kube-scheduler-kind-control-plane            1/1     Running   0
local-path-storage   local-path-provisioner-…                     0/1     Pending   0
```

> **Note:** `NotReady` nodes and `Pending` coredns / local-path-provisioner pods are the
> **expected** outcome, not a failure. The kubelet reports `NotReady` while no CNI plugin
> is configured, so the scheduler refuses to place pods that need pod networking. Both
> resolve in Scenario 1 the moment the Cilium agent starts.

Checklist before moving on:

```bash
docker --version
kubectl version --client
kind --version
helm version --short
cilium version --client
hubble version
```

---

## Teardown and Reset

```bash
# Delete the lab cluster
kind delete cluster --name kind

# Re-create it from scratch
./setup-ubuntu/setup-ubuntu.sh --cluster-only

# Reclaim disk used by cached node images
docker system prune -a
```

---

## Troubleshooting

| Symptom | Cause / Fix |
| --- | --- |
| `permission denied while trying to connect to the Docker daemon socket` | Group membership not refreshed. Run `newgrp docker` or log out and back in. |
| `ERROR: failed to create cluster: node(s) already exist` | A cluster with that name exists. Run `kind delete cluster --name kind` first. |
| Nodes stay `NotReady` **after** installing Cilium | Check the agent: `kubectl -n kube-system get pods -l k8s-app=cilium` and `kubectl -n kube-system logs ds/cilium`. |
| Pods stuck in `ContainerCreating`, agents restarting | inotify limits — see [step 7](#7-raise-the-host-inotify-limits). |
| `too many open files` in kubelet or containerd logs | Same inotify cause as above. |
| Cluster creation times out pulling images | Pre-pull the node image: `docker pull kindest/node:<tag>`, then re-run. |
| Running Ubuntu inside a VM | Give the VM 4 vCPU / 8 GiB and confirm cgroup v2 is active: `stat -fc %T /sys/fs/cgroup` should print `cgroup2fs`. |

---

## Next Step

Continue with
**[Scenario 1 — Installing Cilium](../scenario-1-installation-cilium/instructions-scenario-1.md)**.
