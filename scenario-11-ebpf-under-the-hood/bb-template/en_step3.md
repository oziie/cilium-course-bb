### eBPF Under the Hood

#### Step 3 — Maps: Where the Data Lives

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
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
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
