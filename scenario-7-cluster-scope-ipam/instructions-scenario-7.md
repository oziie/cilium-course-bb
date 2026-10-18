# Scenario 7 — Cluster Scope IPAM

**Scope:** Install Cilium in Cluster Scope IPAM mode with deliberately small address pools,
check which PodCIDR each node receives, and fill up one node until its pods can no longer
get an IP address.

## Step 1 — Create the Cluster with Cluster Scope IPAM

**IPAM** (IP Address Management) decides which IP address each pod gets. In
**Cluster Scope** mode (`ipam.mode=cluster-pool`), **Cilium, not Kubernetes**, gives each
node its pod address range (PodCIDR). The Cilium operator splits one or more cluster-wide
pools into per-node subnets. It is Cilium's **default** IPAM mode, because it needs no
special Kubernetes configuration. Its advantage is that the cluster can have **several**
pools instead of one. But if the pools are too small, pods still run out of addresses.
This scenario simulates exactly that.

**If exists, delete any previous cluster first (mandatory).** The IPAM mode is set when
Cilium is installed and **cannot be changed on a running cluster**. If a cluster from an
earlier scenario exists, it uses `ipam.mode=kubernetes`, so delete it, then create the
new cluster with the [`create-kind-cluster.sh`](create-kind-cluster.sh) script in this
folder:

```bash
cd scenario-7-cluster-scope-ipam
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

> **Note:** If you skip the deletion, the script stops with
> `Cilium is installed with ipam 'kubernetes', not cluster-pool — re-run with --recreate.`

The script creates the cluster from [`light-lab.yaml`](light-lab.yaml) and installs
Cilium with the values in [`cilium-values.yaml`](cilium-values.yaml). Apart from `ipam`,
they are the usual lab settings:

```yaml
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
```

- `clusterPoolIPv4PodCIDRList`: two small `/28` pools (16 addresses each) for the whole
  cluster.
- `clusterPoolIPv4MaskSize: 29`: each node receives a `/29` (8 addresses) from one of the
  pools.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

```bash
kind delete cluster --name kind
```
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
```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  -f cilium-values.yaml
```

</details>

Wait until Cilium is ready:

```bash
cilium status --wait
```

Check that Cilium runs in Cluster Scope mode:

```bash
cilium config view | grep cluster-pool
```

You see `ipam cluster-pool`, the two pools in `cluster-pool-ipv4-cidr` and the mask size
`29`.

## Step 2 — Check the Subnet of Each Node

The Cilium operator writes each node's subnet into the node's `CiliumNode` resource:

```bash
kubectl get ciliumnode -o custom-columns=NODE:.metadata.name,CIDR:.spec.ipam.podCIDRs[0]
```

Example output (your assignment may differ):

```
NODE                 CIDR
kind-control-plane   10.0.42.8/29
kind-worker          10.0.42.0/29
kind-worker2         10.0.84.8/29
```

A `/28` holds only two `/29` subnets. The first pool (`10.0.42.0/28`) runs out after two
nodes, so the third node receives its subnet from the second pool (`10.0.84.0/28`).

**How many pods fit on a node?** A `/29` has 8 addresses:

| Addresses | Used for |
| --- | --- |
| 2 | network and broadcast address, never used |
| 1 | `cilium_host`, Cilium's router interface on the node |
| 1 | `cilium-health`, Cilium's health-check endpoint |
| **4** | **pods** |

Cilium counts **6 allocatable** addresses per node (8 minus network and broadcast), but
only **4 are left for pods**.

## Step 3 — Deploy a Sample Pod and Check the Node's Addresses

Deploy a pod on `kind-worker`:

```bash
kubectl run netshoot-client --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"kind-worker"}}}' \
  -- sleep infinity
```
```bash
kubectl wait --for=condition=Ready pod/netshoot-client --timeout=120s
```
```bash
kubectl get pod netshoot-client -o wide
```

The pod IP comes from the `/29` of `kind-worker` that you saw in step 2.

Now look at the IPAM section of `cilium-dbg status` on the Cilium agent of that node:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status --verbose | grep -A 6 '^IPAM'
```

Example output:

```
IPAM:                    IPv4: 3/6 allocated from 10.0.42.0/29,
Allocated addresses:
  10.0.42.1 (router)
  10.0.42.4 (health)
  10.0.42.5 (default/netshoot-client)
```

`3/6` means 3 of the 6 allocatable addresses are in use: the router (`cilium_host`), the
health endpoint and your pod. If `coredns` pods run on this node, they are listed too.

## Step 4 — Run Out of Addresses on a Node

Create a Deployment with **10** nginx pods, all pinned to `kind-worker2`:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 10
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      nodeSelector:
        kubernetes.io/hostname: kind-worker2
      containers:
        - name: nginx
          image: nginx
EOF
```

Wait about 30 seconds, then list the pods:

```bash
kubectl get pods -o wide -l app.kubernetes.io/name=nginx
```

At most **4** pods are `Running` (fewer if `coredns` already uses addresses on
`kind-worker2`). The others stay in `ContainerCreating`, with no IP: the node has no
address left to give them.

Confirm it on the Cilium agent of `kind-worker2`:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker2 -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status | grep IPAM
```

The output shows `IPv4: 6/6 allocated`: every address is in use. The events of the stuck
pods tell the same story. Kubernetes could not create the pod's network because Cilium
had no IP left to allocate:

```bash
STUCK_POD=$(kubectl get pods -l app.kubernetes.io/name=nginx --field-selector status.phase=Pending -o name | head -n 1)
kubectl describe $STUCK_POD | grep -m 1 "range is full"
```

**Limitations of Cluster Scope.** It is more flexible than Kubernetes Host Scope, but:

- **The address space is static.** You cannot add or expand the pools once the cluster is
  running, so an exhaustion like this one cannot be fixed without redeploying.
- **Limited control over pod IPs.** All pods draw from the same shared pools, whatever
  their workload or namespace.

Multi-Pool IPAM mode removes these restrictions.

## Cleanup

Remove the test applications:

```bash
kubectl delete deployment nginx-deployment
kubectl delete pod netshoot-client
```

This cluster uses `ipam.mode=cluster-pool`, while the other scenarios use different
settings. **Deleting it is mandatory in every environment, BB included:**

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
