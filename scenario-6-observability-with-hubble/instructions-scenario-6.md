# Scenario 6 — Observability with Hubble

**Scope:** Turn on Hubble and watch the traffic of the nginx app from scenario 3: pod to
pod, pod to Service, DNS lookups, traffic leaving the cluster and a failed connection. No
network policy is used in this scenario, Hubble only observes.

## Step 1 — Create the Cluster, Install Cilium and Deploy the Applications

In this scenario you turn on **Hubble**, Cilium's observability layer, and watch the
traffic of a small application: pod to pod, pod to Service, DNS lookups, traffic leaving
the cluster and a failed connection. No network policy is used: Hubble only observes.

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, the cluster is
already there. Otherwise, create (or reuse) it with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-6-observability-with-hubble
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster from [`light-lab.yaml`](light-lab.yaml), installs Cilium
with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) and waits until
all nodes are `Ready`. If Cilium is already installed, it is left as is.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

Write the kind configuration file and create the cluster. `disableDefaultCNI: true` turns
off kind's default network plugin so that Cilium can manage pod networking:

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
EOF
```
```bash
kind create cluster --config light-lab.yaml
```

Install Cilium with Helm:

```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

</details>

> **Note:** This folder's script also enables Hubble Relay and Hubble UI on top of the
> usual setup, so with the script the Helm upgrade of step 2 changes nothing. Running it
> anyway is harmless. If policies from scenarios 4 or 5 are still in the cluster, delete
> them first (`kubectl delete cnp --all -A`): this scenario observes traffic without any
> policy.

Wait until Cilium is ready:

```bash
cilium status --wait
```

Deploy the applications: nginx on `kind-worker2`, a client pod on `kind-worker`, and a
`nginx-service` Service in front of nginx:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
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
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - port: 80
EOF
```
```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
```
```bash
kubectl get pods -o wide
```

The client runs on `kind-worker` and nginx on `kind-worker2`.

## Step 2 — Enable Hubble Relay and Connect the CLI

Cilium's eBPF programs already see every packet entering or leaving a pod. Hubble turns
them into readable **flows**:

| Component | Where it runs | Role |
| --- | --- | --- |
| Hubble server | inside every `cilium` agent | records the flows of its own node (on by default) |
| Hubble Relay | `hubble-relay` Deployment | collects the flows of **all** nodes into one API |
| `hubble` CLI | your terminal | reads the flows from Relay |

Enable Hubble Relay with a Helm upgrade. `--reuse-values` keeps the settings from the
installation and only adds Relay:

```bash
helm upgrade cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --reuse-values \
  --set hubble.relay.enabled=true
```
```bash
kubectl -n kube-system rollout status deployment/hubble-relay
```
```bash
cilium status
```

`cilium status` now shows `Hubble Relay: OK`.

The `hubble` CLI connects to Relay on `localhost:4245`. Open a port-forward to Relay. The
`&` at the end keeps it running in the background, so you can keep using this terminal:

```bash
cilium hubble port-forward > /dev/null 2>&1 &
```
```bash
sleep 3
hubble status
```

`hubble status` shows `Healthcheck (via localhost:4245): Ok` and `Connected Nodes: 3/3`:
Relay reaches the Hubble server on every node.

```bash
hubble list nodes
```

Each node keeps its most recent flows in memory (4095 per node), so Hubble shows recent
traffic, not a full history.

> **Note:** If `hubble status` fails with `connect: connection refused`, the port-forward
> is not running. Start it again with the `cilium hubble port-forward` command above.

## Step 3 — Observe Pod-to-Pod and Pod-to-Service Traffic

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

## Step 4 — Filter Flows, Traffic Leaving the Cluster and a Failed Connection

**Filters.** Without filters, `hubble observe` shows the flows of the whole cluster, which
is noisy. A few filters answer most questions:

```bash
# Who is calling nginx?
hubble observe --to-pod default/nginx-deployment --last 10
```
```bash
# All DNS traffic in the cluster
hubble observe --port 53 --last 10
```
```bash
# Only what happens on one node
hubble observe --node-name kind-worker2 --last 10
```

`--to-pod default/nginx-deployment` matches every pod whose name **starts with**
`nginx-deployment`, so you don't need the random suffix.

> **Note:** To see which node recorded each flow, add `--print-node-name` to any
> `hubble observe` command. Each line then also shows the node name, for example
> `kind-kind/kind-worker2`.

**Traffic leaving the cluster.** Call a site on the internet, then filter on `world`, the
identity Cilium gives to everything outside the cluster:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
```
```bash
hubble observe --pod default/netshoot-client --to-label reserved:world --last 10
```

- The destination is shown as an IP followed by `(world)`.
- `to-stack` means the packet was handed to the node's network stack, which sends it out
  of the cluster.

**A failed connection.** Not every failure is a network problem. Call nginx on port 8081,
where nothing listens:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -m 3 http://$NGINX_IP:8081
```
```bash
hubble observe --port 8081 --last 10
```

`curl` fails with `exit code 7`. In Hubble:

- the `SYN` was `FORWARDED`: the network delivered it to the nginx pod;
- the pod answered with `TCP Flags: ACK, RST`: "nothing is listening on this port".

This is an application or configuration problem, not a network one. A policy drop would
look different: a `DROPPED` verdict and no reply.

> **Note:** `--pod` and `--port` together match only when the pod **and** the port are on
> the same side of the flow. The client uses a random port and nginx owns port 8081, so
> `--pod default/netshoot-client --port 8081` shows nothing. Filter on the port alone.

## Cleanup

Stop the background port-forward and remove the test applications:

```bash
kill %1   # or: pkill -f "cilium hubble port-forward"
kubectl delete service nginx-service
kubectl delete deployment nginx-deployment
kubectl delete pod netshoot-client
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
