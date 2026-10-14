### eBPF Under the Hood

#### Step 2 — Programs Attached to Hooks

Deploy something to look at: an `nginx` Deployment with two replicas on `kind-worker2`,
a ClusterIP Service `nginx`, and a `client` pod on `kind-worker`:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      nodeSelector:
        kubernetes.io/hostname: kind-worker2
      containers:
        - name: nginx
          image: nginx
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
EOF
```
```bash
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
```
```bash
kubectl wait --for=condition=Ready pod/client --timeout=120s
```
```bash
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

The last command prints `200`.

The Cilium agent image ships `bpftool`, the standard Linux tool for eBPF, and
`cilium-dbg`, Cilium's own debug CLI. Save the name of the agent pod on each worker:

```bash
AGENT1=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
```
```bash
AGENT2=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker2 -o name)
```

The agent runs in the node's network namespace, so `bpftool` there sees the node's
interfaces. List the eBPF programs attached to them on `kind-worker2`:

```bash
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- bpftool net show
```

Each line is one program attached to a hook on an interface, for example
`lxc4b1e2c9a7d10(9) tcx/ingress cil_from_container`. On older kernels the hook is shown
as `clsact/ingress` instead of `tcx/ingress`.

| Interface | Program | When it runs |
| --- | --- | --- |
| `lxc...` | `cil_from_container` | a packet leaves a pod (one `lxc` interface per pod) |
| `eth0` | `cil_from_netdev` / `cil_to_netdev` | a packet enters / leaves the node |
| `cilium_vxlan` | `cil_from_overlay` / `cil_to_overlay` | a packet arrives from / goes into the tunnel to another node |
| `cilium_host` | `cil_to_host` / `cil_from_host` | a packet goes to / comes from the node itself |

Before the kernel accepted these programs, its **verifier** checked that each one always
finishes and only touches memory it is allowed to, so a bug cannot crash the kernel.
Then the kernel **JIT-compiled** them to native machine code, so they run at close to
native speed.

Each pod has its own `lxc` interface with its own program. Cilium calls each pod an
**endpoint**. Match the endpoints to the pods:

```bash
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg endpoint list
```

The two `nginx` pods are listed with their IPs and labels. The `client` pod is not here:
it runs on `kind-worker`, and its program is attached there.
