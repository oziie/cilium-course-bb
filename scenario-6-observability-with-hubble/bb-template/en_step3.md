### Observability with Hubble

#### Step 3 — Observe Pod-to-Pod and Pod-to-Service Traffic

**Pod to pod.** Call nginx by its pod IP, then show the latest flows of the client pod:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
```
```bash
hubble observe --pod default/netshoot-client --last 10
```

One `curl` gives a full TCP conversation. The output looks like this (names, ports and
IDs differ in your cluster):

```
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
```

How to read it:

| Part | Meaning |
| --- | --- |
| `default/netshoot-client:38958` | namespace/pod and port: Hubble shows names, not only IPs |
| `(ID:48603)` | the Cilium **security identity** of the pod, derived from its labels |
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
```
```bash
hubble observe --pod default/netshoot-client --last 20
```

The output looks like this. The flows of the earlier pod-to-pod call also appear above
these lines; they are left out here:

```
Oct 12 21:58:27.585: default/netshoot-client:52192 (ID:48603) -> kube-system/coredns-559f6c778d-shp78:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.588: default/netshoot-client:52192 (ID:48603) <- kube-system/coredns-559f6c778d-shp78:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.839: default/netshoot-client:41963 (ID:48603) -> kube-system/coredns-559f6c778d-tpm7h:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:58:28.627: default/netshoot-client:41963 (ID:48603) <- kube-system/coredns-559f6c778d-tpm7h:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:28.628: default/netshoot-client (ID:48603) -> 10.96.0.10 (world) to-stack FORWARDED (ICMPv4 DestinationUnreachable(Port))
```

Two things are new:

1. **A DNS lookup** to a `kube-system/coredns-...` pod on port `53` (`UDP`): the client
   first asks CoreDNS for the IP of `nginx-service`.
2. **The TCP flows go to the nginx pod, not to the ClusterIP.** Cilium translates the
   ClusterIP to a pod IP with eBPF before the packet leaves the client, so the flows look
   exactly like the pod-to-pod ones.

The last two lines are a late DNS reply: it arrives after `curl` has already closed its
socket, so the client's kernel answers with an ICMP `DestinationUnreachable(Port)`. It is
addressed to `10.96.0.10`, the ClusterIP of the `kube-dns` Service. A ClusterIP belongs to
no pod and has no identity, so Hubble labels it `world`. It is harmless.

> **Note:** Hubble shows that traffic happened on port 80, but not the HTTP method, path
> or status code. That level of detail needs an L7 policy, which sends the traffic through
> Envoy. Without one, Hubble works at L3/L4.
