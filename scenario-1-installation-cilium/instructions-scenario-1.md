# Scenario 1 — Installation of Cilium

> **Note:** E-Book Chapter-3 and this repo is the reference for the installation part.

**Scope:** Create a kind cluster without a CNI, install Cilium with Helm and verify the
installation.

## Prerequisites Tools

- `helm`
- `cilium-cli`
- `hubble`

If you are building the lab on your own Ubuntu machine, follow
[setup-ubuntu/instructions-setup-ubuntu.md](../setup-ubuntu/instructions-setup-ubuntu.md)
first to install them.

## Step 1 — Create the kind Cluster

In this scenario you install **Cilium** as the network plugin (CNI) of a Kubernetes
cluster. First, create a local cluster with **kind** (Kubernetes in Docker): 1
control-plane node and 2 worker nodes. Having two workers lets the later scenarios show
traffic between pods on different nodes.

The kind configuration is in [`light-lab.yaml`](light-lab.yaml):

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
```

`disableDefaultCNI: true` turns off **kindnetd**, the network plugin kind installs by
default, so that Cilium can take over pod networking.

Create the cluster (this takes a minute or two) with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-1-installation-cilium
./create-kind-cluster.sh --no-cilium
kubectl config current-context   # should print kind-kind
```

`--no-cilium` stops after creating the cluster, because installing Cilium is what this
scenario is about. Without the flag, the script also runs the Helm install of step 2 for
you; that is how the later scenarios use it. Other useful flags: `--recreate` to start
fresh, `--image kindest/node:<tag>` to pin the Kubernetes version, `--delete` to remove
the cluster. See `./create-kind-cluster.sh --help`.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

```bash
cat > light-lab.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
EOF
```
```bash
kind create cluster --config light-lab.yaml
```

</details>

Check the nodes and the pods:

```bash
kubectl get nodes
```
```bash
kubectl get pods -A
```

The nodes are `NotReady`, and the `coredns` and `local-path-provisioner` pods are
`Pending`. This is expected: the cluster has **no CNI yet**, so pods cannot get a network.
You fix that in the next step by installing Cilium.

## Step 2 — Install Cilium with Helm

Add the Cilium Helm repository:

```bash
helm repo add cilium https://helm.cilium.io/
```

Install Cilium into the `kube-system` namespace:

```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

What each setting does:

- `--version 1.18.4` pins the Cilium version. Without it, Helm installs the latest
  release, which can change from one day to the next. Pinning keeps every environment
  the same.
- `cluster.name=kind-kind` names the cluster, matching the kubectl context created by
  kind.
- `ipam.mode=kubernetes` makes Cilium give pod IPs from the address range Kubernetes
  assigns to each node.
- `operator.replicas=1` runs a single Cilium operator, enough for a small lab cluster.
- `routingMode=tunnel` and `tunnelProtocol=vxlan` carry traffic between nodes inside a
  VXLAN tunnel, so the nodes' network does not need to know the pod IPs.

Wait until the installation is complete:

```bash
cilium status --wait
```

The command returns when all Cilium components are ready. This can take a few minutes.

## Step 3 — Verify the Installation

Show the status of Cilium:

```bash
cilium status
```

`Cilium`, `Operator` and `Envoy DaemonSet` must be `OK`. `Hubble Relay` and
`ClusterMesh` are `disabled`, which is expected: they are not part of this installation.

Cilium runs three components:

| Component | Kind | Role |
| --- | --- | --- |
| `cilium` | DaemonSet (one pod per node) | the agent: loads the eBPF programs that handle pod networking |
| `cilium-envoy` | DaemonSet (one pod per node) | the Envoy proxy used for Layer 7 features |
| `cilium-operator` | Deployment (1 replica) | cluster-wide tasks, such as managing resources shared by all agents |

Check them with kubectl:

```bash
kubectl get -n kube-system daemonset cilium cilium-envoy
```
```bash
kubectl get -n kube-system deployment cilium-operator
```

Both DaemonSets show `3` desired and `3` ready pods, one per node. The operator shows
`1/1`.

Now that a CNI is installed, the cluster works normally:

```bash
kubectl get nodes
```
```bash
kubectl get pods -A
```

All three nodes are `Ready`, and the `coredns` and `local-path-provisioner` pods that were
`Pending` in step 1 are now `Running`.

## Cleanup (no need for BB)

[Scenario 2](../scenario-2-pod-connectivity/instructions-scenario-2.md) runs on this
cluster with Cilium already installed, so **keep it** if you are continuing.

Delete it only when you are done with the lab or want to start over:

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```

> **Note:** Deleting the cluster removes the Cilium installation with it. To come back,
> re-run this scenario from [Step 1](#step-1--create-the-kind-cluster), or run
> `./create-kind-cluster.sh` (without `--no-cilium`) from any later scenario's folder to
> get a cluster with Cilium already installed.
