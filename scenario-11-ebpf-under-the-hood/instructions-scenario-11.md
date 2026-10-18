# Scenario 11 — eBPF Under the Hood

**Scope:** Look inside Cilium's data plane. Find the eBPF **programs** Cilium attaches
to the network interfaces, read the eBPF **maps** that hold Services and policies, and
watch the **events** the programs send while traffic flows. Every earlier scenario used
these pieces without showing them; here you see them directly.

## Step 1 — What is eBPF? Create the Cluster

**eBPF** lets you run small, safe programs inside the Linux kernel, triggered by events
such as a packet arriving on a network interface, without changing the kernel or
loading a kernel module. Cilium uses it to forward, load-balance and secure traffic
right where packets pass through the kernel, instead of in long iptables chains.

Every earlier scenario used eBPF without showing it. In this scenario you look at the
three building blocks Cilium is made of:

1. **Programs attached to hooks**: the code that runs for every packet (Step 2).
2. **Maps**: key/value stores in the kernel that hold the data the programs need, such
   as Services and policies (Step 3).
3. **Events**: messages the programs send to user space, for example when they drop a
   packet (Step 4).

```
 user space   cilium-agent                 cilium-dbg monitor / Hubble
                   │ writes                            ▲
 ──────────────────┼───────────────────────────────────┼─────────────
 kernel            ▼                                   │ events
              ┌─────────┐   lookup    ┌─────────┐      │
              │  maps   │◀────────────│ program │──────┘
              └─────────┘             └────▲────┘
                                           │ runs on
             packet ──▶ hook (lxc / eth0 / cilium_vxlan)
```

This scenario uses a cluster **without kube-proxy**, so Services are handled by eBPF
only.
Delete any previous cluster, then create the new one with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-11-ebpf-under-the-hood
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

The kind config [`light-lab.yaml`](light-lab.yaml) is the usual 1 control-plane + 2
workers with `disableDefaultCNI: true`, plus `kubeProxyMode: none`, which tells kind not
to install kube-proxy. The script installs Cilium with the values in
[`cilium-values.yaml`](cilium-values.yaml):

```yaml
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
```

They are the Scenario 1 settings plus `kubeProxyReplacement: true`.

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
  kubeProxyMode: none
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
  mode: kubernetes
kubeProxyReplacement: true
EOF
```
```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

</details>

Wait until Cilium is ready and check the setting:

```bash
cilium status --wait
```
```bash
cilium config view | grep 'kube-proxy-replacement '
```

`kube-proxy-replacement` is `true`: from now on, eBPF does the work kube-proxy used to do.

## Step 2 — Programs Attached to Hooks

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

## Step 3 — Maps: Where the Data Lives

eBPF programs keep no state of their own. Everything they need to decide what to do
with a packet lives in **maps**: key/value stores in the kernel that both the programs
and the Cilium agent can read and write. List the maps on `kind-worker`, where the
client runs:

```bash
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg map list
```

Each line is one map, with the number of entries it holds. The exact names carry a
version suffix (for example `_v2`); look for these prefixes:

| Map name starts with | Contents |
| --- | --- |
| `cilium_lb4_services`, `cilium_lb4_backends` | Services and their backend pods |
| `cilium_ipcache` | every known IP → its security identity |
| `cilium_policy` | allowed identities and ports, one map per endpoint |
| `cilium_ct4_global` | connection tracking: open connections |

Now look up the `nginx` Service in the load-balancing map:

```bash
NGINX_IP=$(kubectl get svc nginx -o jsonpath='{.spec.clusterIP}')
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
```

The ClusterIP has one line per backend, each with an `nginx` pod IP. When the client
calls `http://nginx`, the program on the client's `lxc` interface looks up this map,
picks a backend and rewrites the destination right away.

Scale the Deployment and look again:

```bash
kubectl scale deployment nginx --replicas=4
```
```bash
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
```
```bash
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
```

There are now four backends. This is the key idea of eBPF in Cilium: **programs are
the logic and stay the same; maps are the data and change all the time.** The agent
only added two map entries. No program was reloaded.

With kube-proxy, every Service would also create `KUBE-SVC-...` iptables chains on
every node. Count them on the node:

```bash
docker exec kind-worker iptables-save | grep -c KUBE-SVC
```

The count is `0`: Service load balancing is done entirely by eBPF programs and maps.
Scale back down before the next step:

```bash
kubectl scale deployment nginx --replicas=2
```

## Step 4 — Policies in Maps, and Events from the Kernel

A network policy also ends up as map entries. Allow only pods labelled `app=frontend`
to reach `nginx` on port 80:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
EOF
```

The `client` pod is labelled `app=client`, so it is now blocked. Ingress policy is
enforced on the node of the **destination** pod, so watch for drop **events** on
`kind-worker2` while the client tries again. `timeout 15` stops the monitor after 15
seconds, and `&` runs it in the background so you can use `curl` in the same terminal:

```bash
timeout 15 kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg monitor --type drop &
sleep 3; kubectl exec client -- curl -s --max-time 3 http://nginx; wait
```

You see lines like this one:

```
xx drop (Policy denied) flow 0x0 to endpoint 1342, ifindex 9, file bpf_lxc.c:2112, , identity 21915->8429: 10.244.1.52:41030 -> 10.244.2.15:80 tcp SYN
```

- `Policy denied`: why the packet was dropped.
- `file bpf_lxc.c`: the eBPF program that dropped it, the one in front of the nginx pod.
- `identity 21915->8429`: Cilium does not compare IPs. It compares **security
  identities**, numbers derived from the pods' labels.

The program sent this event to user space through a ring buffer. Hubble (Scenario 6)
reads the same events.

Now look at the nginx pod's **policy map**. Each endpoint has its own:

```bash
NGINX_POD=$(kubectl get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')
EP_ID=$(kubectl get ciliumendpoint $NGINX_POD -o jsonpath='{.status.id}')
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
```

There is no `Ingress` entry for any pod: no pod has the label `app=frontend` yet, so
no identity matches the policy. Give the client that label and check again:

```bash
kubectl label pod client app=frontend --overwrite
```
```bash
sleep 5
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
```
```bash
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

- The client got a **new identity** for its new labels.
- The policy map now has an `Allow` `Ingress` entry for that identity (labels
  `k8s:app=frontend ...`) on `80/TCP`.
- `curl` prints `200` again.

No program changed and no pod restarted. The agent wrote one new map entry, and the
next packet was allowed. Programs at hooks, data in maps, events to user space: that is
how Cilium uses eBPF for everything you did in this course.

## Cleanup

Remove the policy and the test applications:

```bash
kubectl delete ciliumnetworkpolicy allow-frontend-to-nginx
kubectl delete service nginx
kubectl delete deployment nginx
kubectl delete pod client
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
