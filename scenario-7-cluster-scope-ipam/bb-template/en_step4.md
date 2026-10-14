### Cluster Scope IPAM

#### Step 4 — Run Out of Addresses on a Node

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
