# Scenario 10 — Egress Gateway

**Scope:** Give one application a fixed, predictable source IP for traffic leaving the
cluster with a `CiliumEgressGatewayPolicy`, see the eBPF map behind it, and check what
happens when no gateway node is available.

## Step 1 — Create the Cluster and Install Cilium with the Egress Gateway

When a pod talks to something outside the cluster, Cilium **masquerades** the traffic:
it replaces the pod IP with the IP of the node the pod runs on. Pods move between nodes,
so the outside world sees a different IP depending on where the pod happens to run.
That breaks partner APIs, databases and firewalls that only accept **allowlisted IPs**.

An **Egress Gateway** fixes this. A `CiliumEgressGatewayPolicy` says:

| Field | Question it answers |
| --- | --- |
| `selectors` | **which pods** does this apply to? |
| `destinationCIDRs` | **which destinations** outside the cluster? |
| `egressGateway` | **which node** sends the traffic out, and with **which IP**? |

Matching traffic is tunnelled to the gateway node, which sends it out with its own IP.
The outside world sees one IP, wherever the pod runs.

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

The IPs above are examples; you will see your own in Step 2.

Like Scenarios 8 and 9, the Egress Gateway needs a cluster **without kube-proxy**.
Delete any previous cluster, then create the new one with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-10-egress-gateway
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
bpf:
  masquerade: true
egressGateway:
  enabled: true
```

- `kubeProxyReplacement: true` and `bpf.masquerade: true`: the Egress Gateway is built
  on Cilium's eBPF masquerading, which replaces the iptables-based one. Both are required.
- `egressGateway.enabled: true`: turns on the Egress Gateway feature in the agents.

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
bpf:
  masquerade: true
egressGateway:
  enabled: true
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

Wait until Cilium is ready:

```bash
cilium status --wait
```

Check the settings:

```bash
cilium config view | grep -E 'kube-proxy-replacement |enable-bpf-masquerade|enable-ipv4-egress-gateway'
```

All three settings are `true`.

## Step 2 — Start an External Server and See the Default Source IP

You need something **outside** the cluster that shows which IP a request comes from.
`traefik/whoami` is a tiny web server that answers every request with details about it,
including `RemoteAddr`: the caller's IP and port.

Run it as a plain Docker container on the `kind` network. It sits next to the kind
nodes but is not part of the cluster, just like a partner's server on your network:

```bash
docker run -d --name external-server --network kind traefik/whoami
```
```bash
EXTERNAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' external-server)
echo $EXTERNAL_IP
```

Note the `INTERNAL-IP` of every node, so you can recognise them in the server's answers:

```bash
kubectl get nodes -o wide
```

Usually `kind-control-plane` is `172.18.0.2`, `kind-worker` is `172.18.0.3` and
`kind-worker2` is `172.18.0.4`, but the order can differ. Use your own values below.

Create two client pods, `payments` and `catalog`, both on `kind-worker`:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: payments
  labels:
    app: payments
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  labels:
    app: catalog
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
kubectl wait --for=condition=Ready pod/payments pod/catalog --timeout=120s
```
```bash
kubectl get pods -o wide
```

Call the external server from both pods:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

Both requests come from the IP of **kind-worker**, not from the pod IPs (`10.244.x.x`
in `kubectl get pods -o wide`). Cilium masqueraded the traffic on the node where the
pods run. If `payments` were rescheduled to `kind-worker2`, the server would suddenly
see a different IP.

## Step 3 — Send `payments` Through an Egress Gateway

First pick the gateway node. Give `kind-worker2` a label that the policy can select:

```bash
kubectl label node kind-worker2 egress-gateway=true
```

Now create the policy. It selects the `payments` pod and sends all of its traffic that
leaves the cluster through the labelled node:

```bash
kubectl apply -f - <<EOF
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
EOF
```
```bash
kubectl get ciliumegressgatewaypolicies
```

- `selectors`: pods are chosen by label. The policy is cluster-scoped, so the namespace
  is also given as a label (`io.kubernetes.pod.namespace`).
- `destinationCIDRs`: `0.0.0.0/0` means every destination. Traffic to pods, Services
  and nodes **inside** the cluster is never redirected.
- `egressGateway.nodeSelector`: the node that sends the traffic out. Without `egressIP`
  or `interface`, Cilium uses the IP of the gateway node's main interface (`eth0` in
  kind). On real clusters you usually set `egressIP` to a dedicated address.

Call the server again from both pods:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

- `payments` now comes from the IP of **kind-worker2**, although the pod still runs on
  `kind-worker`. Its traffic was tunnelled to the gateway node and left the cluster there.
- `catalog` is not selected by the policy, so it still leaves with kind-worker's IP.

The external server's firewall now only needs to allow kind-worker2's IP for the
payments app, wherever its pods run.

## Step 4 — Under the Hood, and What Happens When the Gateway Is Gone

The Cilium agents turn the policy into entries in an eBPF map. Look at the map on
`kind-worker`, where the `payments` pod runs:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf egress list
```

There is one entry: the `Source IP` is the `payments` pod IP, the `Destination CIDR` is
`0.0.0.0/0`, and the `Gateway IP` is kind-worker2's IP. Every packet from that pod to a
matching destination is forwarded to the gateway. `Egress IP` is only filled in on the
gateway node itself, where the packet is actually masqueraded. Each selected pod gets
its own entry, so if you scale an app to more pods, the map grows with it.

Now remove the label, so **no node** matches the policy any more:

```bash
kubectl label node kind-worker2 egress-gateway-
```
```bash
kubectl exec payments -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
```

`payments` gets no answer (the request times out), while `catalog` still works. Cilium
**drops** the selected traffic instead of letting it leave with the wrong IP. The
external firewall would reject that IP anyway, and failing closed makes the problem easy
to see.

Put the label back, and `payments` leaves through `kind-worker2` again:

```bash
kubectl label node kind-worker2 egress-gateway=true
```
```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

You gave one application a fixed, predictable source IP without changing the app, the
pod or its node. Only a label and a policy decided which node the traffic leaves from.

## Cleanup

Remove the policy, the label, the pods and the external server:

```bash
kubectl delete ciliumegressgatewaypolicy payments-egress
kubectl delete pod payments catalog
kubectl label node kind-worker2 egress-gateway-
docker rm -f external-server
```

`external-server` is a plain Docker container, so deleting the cluster does **not**
remove it. Remove it with `docker rm -f` as above.

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
