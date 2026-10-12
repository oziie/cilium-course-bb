# Scenario 11 — eBPF Under the Hood

**Scope:** Look inside Cilium's data plane. Find the eBPF **programs** Cilium attaches
to the network interfaces, read the eBPF **maps** that hold Services and policies, and
watch the **events** the programs send while traffic flows. Every earlier scenario used
these pieces without showing them; here you see them directly.

## What is eBPF

**eBPF** lets you run small, safe programs inside the Linux kernel, triggered by events
such as a packet arriving on an interface, without changing the kernel or loading a
kernel module. Cilium uses it to do all of its networking, load balancing and security
work right where packets pass through the kernel, instead of in long iptables chains.

Three building blocks make this work, and this scenario looks at each of them:

| Building block | What it is | What Cilium uses it for |
| --- | --- | --- |
| **Program + hook** | code the kernel runs when an event fires at a hook point (here: a packet on an interface) | forwarding, Service load balancing, policy checks on every packet |
| **Map** | a key/value store in the kernel, shared by programs and user space | Service backends, pod identities, policy rules, connection tracking |
| **Event** | a message a program sends to user space through a ring buffer | `cilium-dbg monitor` and Hubble (drops, traces) |

Before a program is loaded, the kernel's **verifier** checks that it always finishes
and only touches memory it is allowed to, so a bug cannot crash the kernel. The program
is then **JIT-compiled** into native machine code, so it runs at close to native speed.

The split between programs and maps is the key idea: **programs are the logic and stay
the same; maps are the data and change all the time.** When a pod starts, a Service
gets a new backend or a policy changes, the Cilium agent only updates map entries. No
program is reloaded and no packet path is rebuilt.

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

## Prepare the kind cluster (no need for BB)

This scenario uses a cluster **without kube-proxy**, so Services are handled by eBPF
only. Delete the previous cluster first, then create a new one:

```bash
cd scenario-11-ebpf-under-the-hood
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

[`light-lab.yaml`](light-lab.yaml) is the same as in Scenarios 8 to 10: 1 control-plane
+ 2 workers, `disableDefaultCNI: true` and `kubeProxyMode: none`. Cilium is installed
with [`cilium-values.yaml`](cilium-values.yaml), the Scenario 1 settings plus
`kubeProxyReplacement: true`. The script runs the equivalent of:

```bash
helm upgrade --install cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

```bash
$ cilium config view | grep 'kube-proxy-replacement '
kube-proxy-replacement                            true
```

## Deploy the Test Applications

[`app-nginx.yaml`](app-nginx.yaml) creates an `nginx` Deployment with two replicas on
`kind-worker2` and a ClusterIP Service `nginx`. [`app-client.yaml`](app-client.yaml)
creates a `client` pod on `kind-worker`:

```bash
kubectl apply -f app-nginx.yaml -f app-client.yaml
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
kubectl wait --for=condition=Ready pod/client --timeout=120s
kubectl get pods -o wide
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

The last command prints `200`.

The Cilium agent image ships two tools you will use: `bpftool`, the standard Linux tool
for eBPF, and `cilium-dbg`, Cilium's own debug CLI. Save the name of the agent pod on
each worker:

```bash
AGENT1=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
AGENT2=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker2 -o name)
```

## Building Block 1: Programs Attached to Hooks

The agent runs in the node's network namespace, so `bpftool` there sees the node's
interfaces. List the eBPF programs attached to them on `kind-worker2`:

```bash
$ kubectl -n kube-system exec $AGENT2 -c cilium-agent -- bpftool net show
xdp:

tc:
eth0(2) tcx/ingress cil_from_netdev prog_id 1021 link_id 9
eth0(2) tcx/egress cil_to_netdev prog_id 1030 link_id 10
cilium_net(3) tcx/ingress cil_to_host prog_id 1003 link_id 7
cilium_host(4) tcx/ingress cil_to_host prog_id 990 link_id 5
cilium_host(4) tcx/egress cil_from_host prog_id 997 link_id 6
cilium_vxlan(5) tcx/ingress cil_from_overlay prog_id 960 link_id 3
cilium_vxlan(5) tcx/egress cil_to_overlay prog_id 965 link_id 4
lxc4b1e2c9a7d10(9) tcx/ingress cil_from_container prog_id 1150 link_id 13
lxc9f03a6d2e8b1(11) tcx/ingress cil_from_container prog_id 1172 link_id 15
...
```

Your IDs and interface names are different. On older kernels the hook is shown as
`clsact/ingress` instead of `tcx/ingress`; the idea is the same.

| Interface | Program | When it runs |
| --- | --- | --- |
| `lxc...` | `cil_from_container` | a packet leaves a pod (one `lxc` interface per pod) |
| `eth0` | `cil_from_netdev` / `cil_to_netdev` | a packet enters / leaves the node |
| `cilium_vxlan` | `cil_from_overlay` / `cil_to_overlay` | a packet arrives from / goes into the VXLAN tunnel to another node |
| `cilium_host` | `cil_to_host` / `cil_from_host` | a packet goes to / comes from the node itself |

Each pod has its own `lxc` interface with its own program. Cilium calls each pod an
**endpoint**; match the endpoints to the pods:

```bash
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg endpoint list
```

The two `nginx` pods are listed with their IPs and labels. The `client` pod is not here:
it runs on `kind-worker` and has its program there.

## Building Block 2: Maps

Programs keep no state of their own. Everything they need to decide what to do with a
packet lives in **maps**. List the maps on `kind-worker`, where the client runs:

```bash
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg map list
```

Each line is one map, with the number of entries it holds. The exact names carry a
version suffix (for example `_v2`) that changes between Cilium releases; look for these
prefixes:

| Map name starts with | Contents |
| --- | --- |
| `cilium_lb4_services`, `cilium_lb4_backends` | Services and their backend pods |
| `cilium_ipcache` | every known IP → its security identity |
| `cilium_policy` | allowed identities and ports, one map per endpoint |
| `cilium_ct4_global` | connection tracking: open connections |

### Services live in a map, not in iptables

Look up the `nginx` Service in the load-balancing map:

```bash
$ NGINX_IP=$(kubectl get svc nginx -o jsonpath='{.spec.clusterIP}')
$ kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
10.96.112.40:80/TCP (0)    0.0.0.0:0 (5) (0) [ClusterIP, non-routable]
10.96.112.40:80/TCP (1)    10.244.2.15:80/TCP (5) (1)
10.96.112.40:80/TCP (2)    10.244.2.83:80/TCP (5) (2)
```

The ClusterIP has one entry per backend: the two `nginx` pod IPs. When the client calls
`http://nginx`, the program on the client's `lxc` interface looks up this map, picks a
backend and rewrites the destination before the packet even leaves the pod's side.

Scale the Deployment and look again:

```bash
kubectl scale deployment nginx --replicas=4
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
```

There are now four backends. The agent added two map entries; no program was reloaded.

With kube-proxy, every Service would also create `KUBE-SVC-...` iptables chains on
every node. Check the node:

```bash
$ docker exec kind-worker iptables-save | grep -c KUBE-SVC
0
```

None at all: Service load balancing is done entirely by eBPF programs and maps.

## Building Block 3: Policies and Events

A network policy also ends up as map entries. [`cnp-allow-frontend.yaml`](cnp-allow-frontend.yaml)
allows only pods labelled `app=frontend` to reach `nginx` on port 80:

```bash
kubectl scale deployment nginx --replicas=2
kubectl apply -f cnp-allow-frontend.yaml
```

The `client` pod is labelled `app=client`, so it is now blocked. Ingress policy is
enforced on the node of the **destination** pod, so watch for drop **events** on
`kind-worker2` while the client tries again. `timeout 15` stops the monitor after 15
seconds; the `&` runs it in the background so you can call `curl` in the same terminal:

```bash
$ timeout 15 kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg monitor --type drop &
$ sleep 3; kubectl exec client -- curl -s --max-time 3 http://nginx; wait
xx drop (Policy denied) flow 0x0 to endpoint 1342, ifindex 9, file bpf_lxc.c:2112, , identity 21915->8429: 10.244.1.52:41030 -> 10.244.2.15:80 tcp SYN
...
```

Read the event from left to right:

- `Policy denied`: why the packet was dropped.
- `file bpf_lxc.c`: the eBPF program that dropped it, the one in front of the nginx pod.
- `identity 21915->8429`: Cilium does not compare IPs. It compares **security
  identities**, numbers derived from the pods' labels, and looks them up in the policy
  map.

This event came from the eBPF program through a ring buffer to user space. Hubble
(Scenario 6) reads the same events.

Now look at the nginx pod's **policy map**. Each endpoint has its own, filled from the
policy:

```bash
$ NGINX_POD=$(kubectl get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')
$ EP_ID=$(kubectl get ciliumendpoint $NGINX_POD -o jsonpath='{.status.id}')
$ kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
POLICY   DIRECTION   LABELS (source:key[=value])   PORT/PROTO   ...
Allow    Ingress     reserved:host                 ANY          ...
Allow    Egress      reserved:unknown              ANY          ...
```

There is no ingress entry for any pod yet: no pod has the label `app=frontend`, so no
identity matches the policy. Give the client that label:

```bash
kubectl label pod client app=frontend --overwrite
sleep 5
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

- The client got a **new identity** for its new labels.
- The policy map now has an `Allow Ingress` entry for that identity (labels
  `k8s:app=frontend ...`) on `80/TCP`.
- `curl` prints `200` again.

No program changed and no pod restarted. The agent wrote one new map entry, and the
next packet was allowed.

## Cleanup

Remove the policy and the test applications:

```bash
kubectl delete -f cnp-allow-frontend.yaml -f app-client.yaml -f app-nginx.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
