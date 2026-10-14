### Gateway API

#### Step 1 — Create the Cluster, Install the Gateway API CRDs and Cilium

In Scenario 8 you exposed Bookinfo with an `Ingress`. Ingress only routes by host and
path; anything more needs controller-specific annotations. **Gateway API** is its
successor, and it splits the job into resources owned by different roles:

| Resource | Owned by | What it describes |
| --- | --- | --- |
| `GatewayClass` | infrastructure provider | which controller implements Gateways (here: `cilium`) |
| `Gateway` | platform team | an entry point: listeners, ports, an IP |
| `HTTPRoute` | application team | routing rules: matches, backends, weights |

This scenario needs a cluster **without kube-proxy**: Cilium replaces it.`kubeProxyMode: none` tells kind not to
install kube-proxy:

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

Gateway API resources are CRDs, not built into Kubernetes. **Install them before
Cilium:** Cilium only starts its Gateway API controller, and the Helm chart only creates
the `cilium` GatewayClass, if the CRDs already exist. Cilium 1.18 supports Gateway API
**v1.3.0**:

```bash
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes; do
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml
done
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
l2announcements:
  enabled: true
gatewayAPI:
  enabled: true
EOF
```

- `kubeProxyReplacement: true`: required by Gateway API support and L2 announcements.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs.
- `gatewayAPI.enabled: true`: turns on the Gateway API controller in the Cilium operator.

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

Check the settings and the GatewayClass:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-gateway-api '
```
```bash
kubectl get gatewayclass
```

All three settings are `true`, and the `cilium` GatewayClass shows `ACCEPTED` `True`:
the Cilium operator has taken ownership of it.
