### Observability with Hubble

#### Step 3 — Observe Pod-to-Pod and Pod-to-Service Traffic

**Pod to pod.** Call nginx by its pod IP, then show the latest flows of the client pod:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
hubble observe --pod default/netshoot-client --last 10
```

One `curl` gives a full TCP conversation. A flow looks like this:

```
default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-...:80 (ID:4512) to-overlay FORWARDED (TCP Flags: SYN)
```

How to read it:

| Part | Meaning |
| --- | --- |
| `default/netshoot-client:51522` | namespace/pod and port: Hubble shows names, not only IPs |
| `(ID:28634)` | the Cilium **security identity** of the pod, derived from its labels |
| `->` / `<-` | request direction / reply direction |
| `to-overlay` | the packet left the node through the VXLAN tunnel |
| `to-endpoint` | the packet was delivered to the destination pod |
| `FORWARDED` | the packet was allowed. The other verdict is `DROPPED` |
| `TCP Flags` | `SYN` → `SYN, ACK` → `ACK` is the handshake, `PSH` carries data, `FIN` closes it |

The same `SYN` shows up twice: once leaving `kind-worker` (`to-overlay`) and once arriving
on `kind-worker2` (`to-endpoint`). Each node records what it sees, and Relay merges them.

**Pod to Service.** Now call nginx through the **Service name**:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx-service
hubble observe --pod default/netshoot-client --last 20
```

Two things are new:

1. **A DNS lookup** to a `kube-system/coredns-...` pod on port `53` (`UDP`): the client
   first asks CoreDNS for the IP of `nginx-service`.
2. **The TCP flows go to the nginx pod, not to the ClusterIP.** Cilium translates the
   ClusterIP to a pod IP with eBPF before the packet leaves the client, so the flows look
   exactly like the pod-to-pod ones.

> **Note:** Hubble shows that traffic happened on port 80, but not the HTTP method, path
> or status code. That level of detail needs an L7 policy, which sends the traffic through
> Envoy. Without one, Hubble works at L3/L4.
