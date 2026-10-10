# Scenario 7 — Cluster Scope IPAM

**Scope:** Install Cilium in Cluster Scope IPAM mode with deliberately small address pools,
check which PodCIDR each node receives, and fill up one node until its pods can no longer
get an IP address.

## What is Cluster Scope IPAM?

IPAM (IP Address Management) decides which IP address every pod gets. Until now the lab
used `ipam.mode=kubernetes` (Kubernetes Host Scope): Kubernetes gives each node a
PodCIDR, and Cilium hands out pod IPs from it.

In **Cluster Scope** mode (`ipam.mode=cluster-pool`), **Cilium, not Kubernetes,**
allocates the PodCIDRs to the nodes. The Cilium operator splits one or more cluster-wide
pools into per-node subnets and writes them to each node's `CiliumNode` resource. The
Cilium agent on the node then hands out pod IPs from that subnet.

| | Kubernetes Host Scope | Cluster Scope |
| --- | --- | --- |
| `ipam.mode` | `kubernetes` | `cluster-pool` |
| Who assigns the node PodCIDR | Kubernetes (kube-controller-manager) | Cilium operator |
| Where the node PodCIDR is stored | `Node` `.spec.podCIDR` | `CiliumNode` `.spec.ipam.podCIDRs` |
| Cluster-wide pools | one | one or more |

Cluster Scope needs no specific Kubernetes configuration, so it is Cilium's **default**
IPAM mode. Without extra settings, Cilium uses the cluster-wide `10.0.0.0/8` prefix and
gives every `CiliumNode` a `/24` subnet.

Its advantage over Kubernetes Host Scope is that the cluster can have **several** CIDRs
instead of just one. That is more flexible, but it does not solve IP address exhaustion
if the pools were too small to begin with. This scenario simulates exactly that.

## Delete the Previous Cluster (mandatory, BB included)

The IPAM mode is set when Cilium is installed and cannot be changed on a running
cluster. The cluster from the previous scenarios uses `ipam.mode=kubernetes`, and this
scenario needs `ipam.mode=cluster-pool`. **Deleting the cluster is mandatory in every
environment, BB included:**

```bash
cd scenario-7-cluster-scope-ipam
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```

> **Note:** If you skip this step, the script stops with
> `Cilium is installed with ipam 'kubernetes', not cluster-pool — re-run with --recreate.`

## Cilium Configuration

Cilium starts with the values in [`cilium-values.yaml`](cilium-values.yaml). Apart from
IPAM, they are the same settings as in
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md):

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
- `clusterPoolIPv4MaskSize: 29`: every node receives a `/29` (8 addresses) from one of
  the pools.

A `/29` has 8 addresses. The network and broadcast addresses are not used, which leaves
**6 allocatable addresses** per node. Two of them go to Cilium's own `cilium_host` (router)
and `cilium-health` interfaces, so **only 4 are left for pods** on each node.

> **Note:** These are Cilium Helm values, not kind settings. The kind config
> [`light-lab.yaml`](light-lab.yaml) is the same as in the other scenarios; a comment in
> it points to `cilium-values.yaml`.

## Create the Cluster and Install Cilium (mandatory, BB included)

After the deletion there is no cluster left, so this step is mandatory too:

```bash
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster from `light-lab.yaml`, then installs Cilium with the
values above. It is the same as running:

```bash
helm upgrade --install cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  -f cilium-values.yaml
```

Check that Cilium is running in Cluster Scope mode with the Cilium CLI:

```bash
$ cilium config view | grep cluster-pool
cluster-pool-ipv4-cidr                            10.0.42.0/28 10.0.84.0/28
cluster-pool-ipv4-mask-size                       29
ipam                                              cluster-pool
```

## Check the Node Subnets

The operator writes each node's subnet to its `CiliumNode` resource:

```bash
$ kubectl get ciliumnode -o custom-columns=NODE:.metadata.name,CIDR:.spec.ipam.podCIDRs[0]
NODE                 CIDR
kind-control-plane   10.0.42.8/29
kind-worker          10.0.42.0/29
kind-worker2         10.0.84.8/29
```

A `/28` only holds two `/29` subnets, so the first pool runs out after two nodes and the
third node receives its subnet from the second pool.

> **Note:** Which node gets which subnet can differ in your cluster. The outputs in this
> scenario are examples, so read them for their shape, not their exact values.

## Deploy a Sample Pod

Deploy the [`netshoot-client-pod.yaml`](netshoot-client-pod.yaml) pod, pinned to
`kind-worker`:

```bash
$ kubectl apply -f netshoot-client-pod.yaml
$ kubectl wait --for=condition=Ready pod/netshoot-client --timeout=120s
$ kubectl get pod netshoot-client -o wide
NAME              READY   STATUS    IP          NODE
netshoot-client   1/1     Running   10.0.42.5   kind-worker
```

The pod IP comes from the `/29` of `kind-worker`. Now look at the IPAM section of
`cilium-dbg status` on the Cilium agent of that node:

```bash
$ CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector spec.nodeName=kind-worker -o name)
$ kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- \
    cilium-dbg status --verbose | grep -A 4 '^IPAM'
IPAM:                    IPv4: 3/6 allocated from 10.0.42.0/29,
Allocated addresses:
  10.0.42.1 (router)
  10.0.42.4 (health)
  10.0.42.5 (default/netshoot-client)
```

`3/6` means 3 of the 6 allocatable addresses are in use: the router (`cilium_host`), the
health endpoint and the pod.

> **Note:** If `coredns` pods were scheduled on this node, they appear in the list too.

## Exhaust the Node's Addresses

Create a Deployment with 10 nginx pods, all pinned to `kind-worker2`, from
[`nginx-deployment-10-replicas.yaml`](nginx-deployment-10-replicas.yaml):

```bash
$ kubectl apply -f nginx-deployment-10-replicas.yaml
$ kubectl get pods -o wide -l app.kubernetes.io/name=nginx
NAME                                READY   STATUS              IP          NODE
nginx-deployment-5d9c7b8f6b-2xkqp   1/1     Running             10.0.84.11  kind-worker2
nginx-deployment-5d9c7b8f6b-7hzlm   1/1     Running             10.0.84.13  kind-worker2
nginx-deployment-5d9c7b8f6b-9wq4r   1/1     Running             10.0.84.10  kind-worker2
nginx-deployment-5d9c7b8f6b-c8vnt   1/1     Running             10.0.84.14  kind-worker2
nginx-deployment-5d9c7b8f6b-fj2mx   0/1     ContainerCreating   <none>      kind-worker2
nginx-deployment-5d9c7b8f6b-k4tzd   0/1     ContainerCreating   <none>      kind-worker2
...
```

At most 4 pods are `Running`, fewer if `coredns` already uses addresses on `kind-worker2`.
The rest stay in `ContainerCreating` because they have no IP address. Check the
Cilium agent on `kind-worker2`:

```bash
$ CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium \
    --field-selector spec.nodeName=kind-worker2 -o name)
$ kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status | grep IPAM
IPAM:                    IPv4: 6/6 allocated from 10.0.84.8/29,
```

All available addresses are allocated. The events of a stuck pod show the same reason
(look for `range is full`):

```bash
kubectl describe pod <a-ContainerCreating-pod> | tail -5
```

## Limitations of Cluster Scope

Cluster Scope is more flexible than Kubernetes Host Scope, but it still has important
limitations:

- **The address space is static.** You cannot add or expand PodCIDRs once the cluster is
  running, so IP exhaustion like the one above cannot be fixed without redeploying.
- **Limited control over pod IPs.** All pods draw from the same shared pools, whatever
  their workload or namespace.

Multi-Pool IPAM mode removes these restrictions.

## Cleanup

Remove the test applications:

```bash
kubectl delete -f nginx-deployment-10-replicas.yaml -f netshoot-client-pod.yaml
```

This cluster uses `ipam.mode=cluster-pool`, while the other scenarios use different
settings. **Deleting it is mandatory in every environment, BB included:**

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
