### Egress Gateway

#### Step 1 — Create the Cluster and Install Cilium with the Egress Gateway

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
If exists, delete any previous cluster, then create the new one:

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

Write the Cilium settings to a values file:

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

- `kubeProxyReplacement: true` and `bpf.masquerade: true`: the Egress Gateway is built
  on Cilium's eBPF masquerading, which replaces the iptables-based one. Both are required.
- `egressGateway.enabled: true`: turns on the Egress Gateway feature in the agents.

Install Cilium and wait until it is ready:

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
```bash
cilium status --wait
```

Check the settings:

```bash
cilium config view | grep -E 'kube-proxy-replacement |enable-bpf-masquerade|enable-ipv4-egress-gateway'
```

All three settings are `true`.
