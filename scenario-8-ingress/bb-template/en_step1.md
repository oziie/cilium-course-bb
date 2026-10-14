### Ingress

#### Step 1 — Create the Cluster and Install Cilium with Ingress

In this scenario you expose the **Bookinfo** sample application with Cilium's built-in
**Ingress controller**, give it an external IP, and call it with `curl` from outside the
cluster. Three Cilium features work together:

| Feature | What it does |
| --- | --- |
| Ingress controller | turns an `Ingress` into Envoy routing rules and a `LoadBalancer` Service |
| LB-IPAM (`CiliumLoadBalancerIPPool`) | gives `LoadBalancer` Services an external IP from a pool you define |
| L2 announcements (`CiliumL2AnnouncementPolicy`) | makes a node answer ARP requests for that IP, so the machine running kind can reach it |

This scenario needs a cluster **without kube-proxy**: Cilium replaces it.`kubeProxyMode: none` tells kind not to
install kube-proxy:

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
l2announcements:
  enabled: true
ingressController:
  enabled: true
EOF
```

- `kubeProxyReplacement: true`: Cilium handles Services with eBPF instead of kube-proxy.
  The Ingress controller and L2 announcements both require it.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs.
- `ingressController.enabled: true`: turns on the Cilium Ingress controller and the
  `cilium` IngressClass.

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

Without kube-proxy, nothing can route the `kubernetes` Service IP before Cilium runs.
`k8sServiceHost` and `k8sServicePort` tell Cilium to reach the API server directly at
`kind-control-plane:6443`.

Check the settings and the IngressClass:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-ingress-controller'
```
```bash
kubectl get ingressclass
```

All three settings are `true`, and an IngressClass named `cilium` exists.
