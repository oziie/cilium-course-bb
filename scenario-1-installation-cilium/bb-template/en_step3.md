### Installation of Cilium

#### Step 3 — Verify the Installation

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
