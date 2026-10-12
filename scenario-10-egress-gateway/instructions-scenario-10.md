# Scenario 10 — Egress Gateway

**Scope:** Make traffic that leaves the cluster from selected pods always come from **one
known IP address**. Run a small server outside the cluster that prints the caller's IP,
see that pods normally leave with the IP of whatever node they run on, then apply a
`CiliumEgressGatewayPolicy` that sends one app's traffic out through a chosen gateway
node.

## Why an Egress Gateway

When a pod talks to something outside the cluster, Cilium **masquerades** the traffic:
it replaces the pod IP with the IP of the node the pod runs on. That is fine until the
other side filters by source IP, which is common:

- a partner API or a SaaS service that only accepts calls from allowlisted IPs
- a database or a legacy system behind a firewall
- audit logs that should show which application made the call

Pods move between nodes, and nodes come and go, so "the node's IP" is not a stable
answer. You would have to allowlist every node, and every node that is added later.

An **Egress Gateway** fixes this. A `CiliumEgressGatewayPolicy` says:

| Field | Question it answers |
| --- | --- |
| `selectors` | **which pods** does this apply to? |
| `destinationCIDRs` | **which destinations** (outside the cluster)? |
| `egressGateway` | **which node** sends the traffic out, and with **which IP**? |

Matching traffic is sent through the VXLAN tunnel to the gateway node, which
masquerades it with its own IP. The external service now sees one IP, no matter where
the pod runs.

```
                   kind Docker network (172.18.0.0/16)

 kind-worker                             kind-worker2 (egress-gateway=true)
┌──────────────────┐   VXLAN tunnel    ┌──────────────────┐
│ payments pod ────┼──────────────────▶│ SNAT to its own  │──┐
│                  │                   │ IP 172.18.0.4    │  │
│ catalog pod ─────┼── SNAT to         └──────────────────┘  ▼
└──────────────────┘   kind-worker's IP ─────────▶  external-server
                       172.18.0.3                  (prints caller IP)
```

## Prepare the kind cluster (no need for BB)

Like Scenarios 8 and 9, this scenario needs a cluster **without kube-proxy**. Delete
the previous cluster first, then create a new one:

```bash
cd scenario-10-egress-gateway
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

[`light-lab.yaml`](light-lab.yaml) is the same as in Scenario 8: 1 control-plane + 2
workers, `disableDefaultCNI: true` and `kubeProxyMode: none`.

### Cilium settings

The script installs Cilium with [`cilium-values.yaml`](cilium-values.yaml):

```yaml
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
kubeProxyReplacement: true
ipam:
  mode: kubernetes
bpf:
  masquerade: true
egressGateway:
  enabled: true
```

- `kubeProxyReplacement: true` and `bpf.masquerade: true`: the Egress Gateway is built
  on Cilium's eBPF masquerading, which replaces the iptables-based one. Both are required.
- `egressGateway.enabled: true`: turns on the Egress Gateway feature in the agents.

The script runs the equivalent of:

```bash
helm upgrade --install cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

Check the settings:

```bash
$ cilium config view | grep -E 'kube-proxy-replacement |enable-bpf-masquerade|enable-ipv4-egress-gateway'
enable-bpf-masquerade                             true
enable-ipv4-egress-gateway                        true
kube-proxy-replacement                            true
```

## Start a Server Outside the Cluster

You need something **outside** the cluster that shows which IP a request comes from.
[`traefik/whoami`](https://github.com/traefik/whoami) is a tiny web server that answers
every request with details about it, including `RemoteAddr`, the caller's IP and port.

Run it as a plain Docker container on the `kind` network. It sits next to the kind
nodes, but it is not part of the cluster, just like a partner's server on your network:

```bash
docker run -d --name external-server --network kind traefik/whoami
EXTERNAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' external-server)
echo $EXTERNAL_IP
```

Note the IP of every node, so you can recognise them in the server's answers:

```bash
$ kubectl get nodes -o wide
NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP   ...
kind-control-plane   Ready    control-plane   10m   v1.34.0   172.18.0.2    ...
kind-worker          Ready    <none>          10m   v1.34.0   172.18.0.3    ...
kind-worker2         Ready    <none>          10m   v1.34.0   172.18.0.4    ...
```

Your IPs may be in a different order. Use your own values in the rest of the scenario.

## Default Behaviour: Pods Leave with Their Node's IP

[`app-clients.yaml`](app-clients.yaml) creates two client pods, `payments` and
`catalog`, both on `kind-worker`:

```bash
kubectl apply -f app-clients.yaml
kubectl wait --for=condition=Ready pod/payments pod/catalog --timeout=120s
kubectl get pods -o wide
```

Call the external server from both pods:

```bash
$ kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
RemoteAddr: 172.18.0.3:41234
$ kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
RemoteAddr: 172.18.0.3:52610
```

Both requests come from `172.18.0.3`, the IP of **kind-worker**, not from the pod IPs
(`10.244.x.x`). Cilium masqueraded the traffic on the node where the pods run. If the
`payments` pod were rescheduled to `kind-worker2`, the server would suddenly see
`172.18.0.4` instead.

## Send `payments` Through an Egress Gateway

First pick the gateway node. Give `kind-worker2` a label that the policy can select:

```bash
kubectl label node kind-worker2 egress-gateway=true
```

[`egress-gateway-policy.yaml`](egress-gateway-policy.yaml) selects the `payments` pod
and sends all its traffic leaving the cluster through the labelled node:

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-egress
spec:
  selectors:
    - podSelector:
        matchLabels:
          app: payments
          io.kubernetes.pod.namespace: default
  destinationCIDRs:
    - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
```

- `selectors`: pods are chosen by label. `CiliumEgressGatewayPolicy` is cluster-scoped,
  so the namespace is also given as a label (`io.kubernetes.pod.namespace`).
- `destinationCIDRs`: `0.0.0.0/0` means every destination. Traffic to pods, Services
  and nodes **inside** the cluster is never redirected, so in-cluster traffic is not
  affected.
- `egressGateway.nodeSelector`: the node that sends the traffic out. Without `egressIP`
  or `interface`, Cilium uses the IP of the gateway node's default-route interface
  (`eth0` in kind). On real clusters you usually set `egressIP` to a dedicated address.

```bash
kubectl apply -f egress-gateway-policy.yaml
kubectl get ciliumegressgatewaypolicies
```

Call the server again from both pods:

```bash
$ kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
RemoteAddr: 172.18.0.4:38810
$ kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
RemoteAddr: 172.18.0.3:47718
```

- `payments` now comes from `172.18.0.4`, the IP of **kind-worker2**, although the pod
  still runs on `kind-worker`. Its traffic was tunnelled to the gateway node and left
  the cluster there.
- `catalog` is not selected by the policy, so it still leaves with its own node's IP.

The external server's firewall now needs to allow only `172.18.0.4` for the payments
app, wherever its pods run.

## Under the Hood: the BPF Egress Map

The Cilium agents turn the policy into entries in an eBPF map. Look at the map on
`kind-worker`, where the `payments` pod runs:

```bash
$ CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
$ kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf egress list
Source IP     Destination CIDR   Egress IP   Gateway IP
10.244.1.37   0.0.0.0/0          0.0.0.0     172.18.0.4
```

Every packet the `payments` pod (`Source IP`) sends to a matching destination is
forwarded to the `Gateway IP`. `Egress IP` is only filled in on the gateway node
itself, where the packet is actually masqueraded. There is one entry per selected pod:
if you scale an app to more pods, each gets its own entry.

### What if the gateway disappears?

Remove the label, so no node matches the policy any more:

```bash
kubectl label node kind-worker2 egress-gateway-
kubectl exec payments -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
kubectl exec catalog -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
```

`payments` gets no answer (the request times out), while `catalog` still works. Cilium
**drops** the selected traffic instead of letting it leave with the wrong IP. The
external server would reject that IP anyway, and failing closed makes the problem easy
to see.

Put the label back and `payments` works again through `kind-worker2`:

```bash
kubectl label node kind-worker2 egress-gateway=true
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

> **Note:** In this open-source setup a policy picks one gateway node. If several nodes
> match the `nodeSelector`, Cilium uses only one of them. Run the gateway on a node
> that is stable, and keep it out of node pools that scale down.

## Cleanup

Remove the policy, the label, the pods and the external server:

```bash
kubectl delete -f egress-gateway-policy.yaml -f app-clients.yaml
kubectl label node kind-worker2 egress-gateway-
docker rm -f external-server
```

`external-server` is a plain Docker container, so deleting the cluster does **not**
remove it. Remove it with `docker rm -f` as above.

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
