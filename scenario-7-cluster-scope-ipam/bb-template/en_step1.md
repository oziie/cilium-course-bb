### Cluster Scope IPAM

#### Step 1 — Create the Cluster with Cluster Scope IPAM

**IPAM** (IP Address Management) decides which IP address each pod gets. In
**Cluster Scope** mode (`ipam.mode=cluster-pool`), **Cilium, not Kubernetes**, gives each
node its pod address range (PodCIDR). The Cilium operator splits one or more cluster-wide
pools into per-node subnets. It is Cilium's **default** IPAM mode, because it needs no
special Kubernetes configuration. Its advantage is that the cluster can have **several**
pools instead of one. But if the pools are too small, pods still run out of addresses.
This scenario simulates exactly that.

**Delete any previous cluster first (mandatory).** The IPAM mode is set when Cilium is
installed and **cannot be changed on a running cluster**. If a cluster from an earlier
scenario exists, it uses `ipam.mode=kubernetes`, so delete it:

```bash
kind delete cluster --name kind
```

Create the cluster:

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
kind create cluster --config light-lab.yaml
```

Write the Cilium settings to a values file. Apart from `ipam`, they are the usual lab
settings:

```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4MaskSize: 29
    clusterPoolIPv4PodCIDRList:
      - 10.0.42.0/28
      - 10.0.84.0/28
EOF
```

- `clusterPoolIPv4PodCIDRList`: two small `/28` pools (16 addresses each) for the whole
  cluster.
- `clusterPoolIPv4MaskSize: 29`: each node receives a `/29` (8 addresses) from one of the
  pools.

Install Cilium with these values and wait until it is ready:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  -f cilium-values.yaml
cilium status --wait
```

Check that Cilium runs in Cluster Scope mode:

```bash
cilium config view | grep cluster-pool
```

You see `ipam cluster-pool`, the two pools in `cluster-pool-ipv4-cidr` and the mask size
`29`.
