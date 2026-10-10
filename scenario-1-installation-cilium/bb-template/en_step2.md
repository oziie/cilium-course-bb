### Installation of Cilium

#### Step 2 — Install Cilium with Helm

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
