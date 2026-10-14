### Installation of Cilium

#### Step 1 — Create the kind Cluster

In this scenario you install **Cilium** as the network plugin (CNI) of a Kubernetes
cluster. First, create a local cluster with **kind** (Kubernetes in Docker): 1
control-plane node and 2 worker nodes. Having two workers lets the later scenarios show
traffic between pods on different nodes.

Write the kind configuration file:

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

`disableDefaultCNI: true` turns off **kindnetd**, the network plugin kind installs by
default, so that Cilium can take over pod networking.

Create the cluster (this takes a minute or two):

```bash
kind create cluster --config light-lab.yaml
```

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
