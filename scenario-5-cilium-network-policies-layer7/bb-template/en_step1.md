### Network Policies (Layer 7)

#### Step 1 — Create the Cluster and Install Cilium

In this scenario you go beyond IPs and ports: you allow only specific **HTTP methods and
paths** into an API, require a **header** for a sensitive call, and limit a pod's
internet access to a single **domain name**.

```
 ns: frontend           ns: backend                       ns: database
┌─────────────┐  8080  ┌───────────────────────────┐ 6379 ┌─────────────┐
│ web         │──────▶ │ api (nginx)               │────▶ │ redis       │
│ (netshoot)  │  HTTP  │  GET    /api/products     │      │  :6379      │
└─────┬───────┘        │  GET    /api/orders       │      └─────────────┘
      │ 443            │  POST   /api/orders       │
      ▼                │  DELETE /api/orders/{id}  │
 api.github.com        │  GET    /admin            │
 (only this name)      └───────────────────────────┘
 ns: default
┌─────────────┐
│ intruder    │   should be blocked everywhere
│ (netshoot)  │
└─────────────┘
```

First, build the lab cluster: 1 control-plane and 2 worker nodes, with Cilium as the
network plugin (CNI).

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

Wait until Cilium is ready:

```bash
cilium status --wait
```
```bash
kubectl get nodes
```

Layer 7 (L7) policies are enforced by the **Envoy** proxy. Cilium already runs it on every
node as the `cilium-envoy` DaemonSet, so there is nothing extra to enable:

```bash
kubectl get -n kube-system daemonset cilium-envoy
```

The DaemonSet shows `3` ready pods, one per node.
