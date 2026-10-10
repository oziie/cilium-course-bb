### Service Connectivity

#### Step 1 — Create the Cluster and Install Cilium

In this scenario you put a Kubernetes **Service** in front of an nginx application and
reach it from a client pod **by name** instead of by pod IP. First, build the lab
cluster: 1 control-plane and 2 worker nodes, with Cilium as the network plugin (CNI).

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
kind create cluster --config light-lab.yaml
```

Install Cilium with Helm:

```bash
helm repo add cilium https://helm.cilium.io/
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
kubectl get nodes
```

All three nodes must be `Ready`.
