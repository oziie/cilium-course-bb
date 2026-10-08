# Scenario 6 — Observability with Hubble

**Scope:** Turn on Hubble and watch the traffic of the nginx app from scenario 3: pod to
pod, pod to Service, DNS lookups, traffic leaving the cluster and a failed connection. No
network policy is used in this scenario, Hubble only observes.

## Prepare the kind cluster (no need for BB)

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. Run the script in this folder **even if you are continuing from the
previous scenario**: on top of the usual setup, it enables Hubble Relay and Hubble UI.

```bash
cd scenario-6-observability-with-hubble
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates (or reuses) the cluster, installs Cilium with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) if it is not
installed yet, then enables Hubble Relay and UI and waits until everything is ready. An
existing Cilium installation keeps its version and its other settings.

> **Note:** If policies from scenarios 4 or 5 are still in the cluster, delete them first
> (`kubectl delete cnp --all -A`). This scenario observes traffic without any policy.

## What is Hubble?

Cilium's eBPF programs already see every packet that enters or leaves a pod. Hubble
records those events as **flows** and lets you query them. It has three parts:

| Part | Where it runs | What it does |
| --- | --- | --- |
| Hubble server | inside every `cilium` agent | records the flows of its own node |
| Hubble Relay | `hubble-relay` Deployment | collects flows from all nodes into one API |
| Hubble UI | `hubble-ui` Deployment | draws a service map from the flows in a browser |

```
 kind-control-plane     kind-worker          kind-worker2
┌────────────────┐   ┌────────────────┐   ┌────────────────┐
│ cilium agent   │   │ cilium agent   │   │ cilium agent   │
│  └ Hubble      │   │  └ Hubble      │   │  └ Hubble      │
└───────┬────────┘   └───────┬────────┘   └───────┬────────┘
        └────────────────────┼────────────────────┘
                             ▼
                      ┌──────────────┐
                      │ Hubble Relay │◀── hubble CLI (localhost:4245)
                      └──────┬───────┘
                             ▼
                      ┌──────────────┐
                      │  Hubble UI   │◀── browser (localhost:12000)
                      └──────────────┘
```

The Hubble server is on by default. Relay and the UI have to be enabled.

## Check Hubble Relay and UI

The `create-kind-cluster.sh` script already enabled them with a Helm upgrade of the
existing Cilium release:

```bash
helm upgrade cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --reuse-values \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true
```

- `--reuse-values` keeps the values set at install time (tunnel mode, IPAM, ...). Without
  it, Helm would reset them to the chart defaults.
- `--version` keeps the installed Cilium version (1.18.4, from Scenario 1), so the
  upgrade only changes Hubble.

> **Note:** If you did not use the script, run the command above yourself (or
> `cilium hubble enable --ui`, which does the same).

Check that the new pods are running and Relay is healthy:

```bash
$ kubectl -n kube-system rollout status deployment/hubble-relay
$ kubectl -n kube-system rollout status deployment/hubble-ui
$ cilium status
    /¯¯\
 /¯¯\__/¯¯\    Cilium:             OK
 \__/¯¯\__/    Operator:           OK
 /¯¯\__/¯¯\    Envoy DaemonSet:    OK
 \__/¯¯\__/    Hubble Relay:       OK
    \__/       ClusterMesh:        disabled
[OUTPUT TRUNCATED]
```

### Connect the Hubble CLI

The `hubble` CLI talks to Relay. Open a port-forward to it in a **second terminal** and
leave it running:

```bash
$ cilium hubble port-forward
```

Back in the first terminal:

```bash
$ hubble status
Healthcheck (via localhost:4245): Ok
Current/Max Flows: 541/12,285 (4.40%)
Flows/s: 6.68
Connected Nodes: 3/3
```

```bash
$ hubble list nodes
NAME                           STATUS      AGE     FLOWS/S   CURRENT/MAX-FLOWS
kind-kind/kind-control-plane   Connected   1m27s   3.94      373/4095 (  9.11%)
kind-kind/kind-worker          Connected   53s     1.09      81/4095 (  1.98%)
kind-kind/kind-worker2         Connected   59s     1.08      87/4095 (  2.12%)
```

`Connected Nodes: 3/3` means Relay reaches the Hubble server on every node. Each node keeps
its last 4095 flows in memory, so Hubble shows recent traffic, not a full history.

## Deploy the Applications

The same apps as in scenario 3: nginx on `kind-worker2`, the client on `kind-worker` and a
`ClusterIP` Service in front of nginx.

| File | Contents |
| --- | --- |
| [`app-nginx.yaml`](app-nginx.yaml) | `nginx-deployment`, pinned to `kind-worker2` |
| [`app-netshoot.yaml`](app-netshoot.yaml) | `netshoot-client` pod, pinned to `kind-worker` |
| [`svc-nginx.yaml`](svc-nginx.yaml) | `nginx-service`, ClusterIP on port 80 |

```bash
$ kubectl apply -f app-nginx.yaml -f app-netshoot.yaml -f svc-nginx.yaml
$ kubectl wait --for=condition=Ready pod --all --timeout=120s
$ kubectl get pods -o wide
NAME                                READY   IP              NODE
nginx-deployment-979f5455f-tjd2w    1/1     10.244.2.127    kind-worker2
netshoot-client                     1/1     10.244.1.67     kind-worker
```

```
 kind-worker                                kind-worker2
┌──────────────────┐                       ┌──────────────────┐
│ netshoot-client  │── nginx-service:80 ─▶ │ nginx-deployment │
│                  │   (ClusterIP)         │ pod :80          │
└────────┬─────────┘                       └──────────────────┘
         │ DNS :53                 internet :443
         ▼                         ▲
   kube-system/coredns             └── netshoot-client
```

> **Note:** Your pod names and IPs will differ. The flow outputs below are examples, so
> read them for their shape, not their exact values.

## Observe Pod-to-Pod Traffic

In the first terminal, follow the flows of the client pod:

```bash
$ hubble observe --pod default/netshoot-client --follow
```

In a third terminal, call nginx by its **pod IP**:

```bash
$ NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
$ kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
200
```

One `curl` gives a full TCP conversation:

```
Oct  9 10:12:01.104: default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: SYN)
Oct  9 10:12:01.105: default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-endpoint FORWARDED (TCP Flags: SYN)
Oct  9 10:12:01.105: default/netshoot-client:51522 (ID:28634) <- default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: SYN, ACK)
Oct  9 10:12:01.106: default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: ACK)
Oct  9 10:12:01.106: default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct  9 10:12:01.107: default/netshoot-client:51522 (ID:28634) <- default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct  9 10:12:01.108: default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:80 (ID:4512) to-overlay FORWARDED (TCP Flags: ACK, FIN)
[OUTPUT TRUNCATED]
```

How to read a flow:

| Part | Meaning |
| --- | --- |
| `default/netshoot-client:51522` | namespace/pod and port. Hubble shows names, not only IPs |
| `(ID:28634)` | the Cilium **security identity** of the pod, derived from its labels |
| `->` / `<-` | request direction / reply direction |
| `to-overlay` | the packet left the node through the VXLAN tunnel (the pods are on different nodes) |
| `to-endpoint` | the packet was delivered to the destination pod |
| `FORWARDED` | the packet was allowed through. The other verdict you will meet is `DROPPED` |
| `TCP Flags` | `SYN` → `SYN, ACK` → `ACK` is the handshake, `PSH` carries data, `FIN` closes it |

Each node records only what it sees, which is why the same `SYN` shows up twice: once
leaving `kind-worker` (`to-overlay`) and once arriving on `kind-worker2` (`to-endpoint`).
Relay merges both nodes into one stream.

> **Note:** Hubble shows that HTTP happened on port 80, but not the method, path or status
> code. That level of detail needs an L7 policy (scenario 5), which sends the traffic
> through Envoy. Without one, Hubble works at L3/L4.

## Observe Pod-to-Service Traffic

Keep `hubble observe` running and call nginx through the **Service name** this time:

```bash
$ kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx-service
200
```

Two new things show up before the TCP flows.

**1. A DNS lookup.** The client first asks CoreDNS for `nginx-service`:

```
Oct  9 10:14:22.310: default/netshoot-client:40312 (ID:28634) -> kube-system/coredns-668d6bf9bc-x8nvk:53 (ID:31187) to-overlay FORWARDED (UDP)
Oct  9 10:14:22.311: default/netshoot-client:40312 (ID:28634) <- kube-system/coredns-668d6bf9bc-x8nvk:53 (ID:31187) to-endpoint FORWARDED (UDP)
```

The client used the kube-dns Service IP (`10.96.0.10`), but the flow already shows the
CoreDNS **pod**.

**2. The TCP flows go to the nginx pod, not to the ClusterIP.** As in scenario 3, Cilium
translates the ClusterIP to a backend pod IP in eBPF, before the packet leaves the client.
So the flows look exactly like the pod-to-pod ones above.

To see which Service a flow went through, print it as JSON and look at
`destination_service`:

```bash
$ hubble observe --pod default/netshoot-client --to-port 80 --last 1 -o json | jq '.flow.destination_service'
{
  "name": "nginx-service",
  "namespace": "default"
}
```

## Filter the Flows

`hubble observe` without filters prints the last 20 flows of the whole cluster, which is
noisy. A few filters answer most questions:

```bash
# Who is calling nginx?
$ hubble observe --to-pod default/nginx-deployment --last 20

# All DNS traffic in the cluster
$ hubble observe --port 53 --last 20

# Only what happens on one node
$ hubble observe --node kind-worker2 --last 20

# Only one namespace
$ hubble observe --namespace default --last 20
```

> **Note:** `--to-pod default/nginx-deployment` matches every pod whose name **starts
> with** `nginx-deployment`, so you don't need the random suffix.

### Traffic leaving the cluster

Call a site on the internet:

```bash
$ kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
200
```

Everything outside the cluster has the reserved identity `world`. Filter on it:

```bash
$ hubble observe --pod default/netshoot-client --to-label reserved:world --last 10
Oct  9 10:18:40.551: default/netshoot-client:39880 (ID:28634) -> 23.192.228.80:443 (world) to-stack FORWARDED (TCP Flags: SYN)
Oct  9 10:18:40.589: default/netshoot-client:39880 (ID:28634) -> 23.192.228.80:443 (world) to-stack FORWARDED (TCP Flags: ACK)
[OUTPUT TRUNCATED]
```

- The destination is only an IP. Hubble can show the name `example.com` only when DNS
  goes through a DNS-aware policy, as in scenario 5.
- `to-stack` means the packet was handed to the node's network stack, which sends it out
  of the cluster (masqueraded to the node IP).

## Observe a Failed Connection

Not every failure is a policy drop. Call nginx on a port where nothing listens:

```bash
$ kubectl exec pod/netshoot-client -- curl -s -m 3 http://$NGINX_IP:8081
command terminated with exit code 7
```

```bash
$ hubble observe --pod default/netshoot-client --port 8081 --last 10
Oct  9 10:20:05.712: default/netshoot-client:58214 (ID:28634) -> default/nginx-deployment-979f5455f-tjd2w:8081 (ID:4512) to-overlay FORWARDED (TCP Flags: SYN)
Oct  9 10:20:05.713: default/netshoot-client:58214 (ID:28634) <- default/nginx-deployment-979f5455f-tjd2w:8081 (ID:4512) to-overlay FORWARDED (TCP Flags: ACK, RST)
```

The network delivered the `SYN` (`FORWARDED`), and the nginx pod answered with `RST`:
"nothing is listening on this port". This is an application or configuration problem,
not a network one. A policy drop would look different: a `DROPPED` verdict and no reply.

## Hubble UI

Open the UI. The command opens a port-forward on `localhost:12000` and your browser:

```bash
$ cilium hubble ui
ℹ️  Opening "http://localhost:12000" in your browser...
```

1. Select the `default` namespace at the top.
2. In another terminal, generate some traffic:

   ```bash
   for i in $(seq 1 10); do
     kubectl exec pod/netshoot-client -- curl -s -o /dev/null http://nginx-service
     kubectl exec pod/netshoot-client -- curl -s -o /dev/null https://example.com
     sleep 1
   done
   ```

3. Watch the service map draw `netshoot-client → nginx-deployment`,
   `netshoot-client → kube-dns` and `netshoot-client → world`. The table under the map
   lists the same flows as `hubble observe`.

Click a box or an arrow to filter the table to that workload.

## Cleanup

Stop the port-forwards (`Ctrl+C` in their terminals) and remove the test applications:

```bash
kubectl delete -f svc-nginx.yaml -f app-nginx.yaml -f app-netshoot.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
