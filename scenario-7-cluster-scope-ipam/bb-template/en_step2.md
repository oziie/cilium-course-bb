### Cluster Scope IPAM

#### Step 2 — Check the Subnet of Each Node

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
