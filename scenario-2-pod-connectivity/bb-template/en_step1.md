### Pod Connectivity

#### Step 1 — Create the Cluster and Install Cilium

In this scenario you check that two pods running on **different nodes** can talk to each
other through Cilium's VXLAN tunnel. First, build the lab cluster: 1 control-plane and 2
worker nodes, with Cilium as the network plugin (CNI).

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

Install Cilium with Helm. `routingMode=tunnel` and `tunnelProtocol=vxlan` carry
traffic between nodes inside a VXLAN tunnel, which is what this scenario tests:

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

Wait until Cilium is ready, then check the nodes:

```bash
cilium status --wait
```
```bash
kubectl get nodes
```

All three nodes must be `Ready`: `kind-control-plane`, `kind-worker` and `kind-worker2`.
