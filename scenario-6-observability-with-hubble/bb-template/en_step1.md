### Observability with Hubble

#### Step 1 — Create the Cluster, Install Cilium and Deploy the Applications

In this scenario you turn on **Hubble**, Cilium's observability layer, and watch the
traffic of a small application: pod to pod, pod to Service, DNS lookups, traffic leaving
the cluster and a failed connection. No network policy is used: Hubble only observes.

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

Install Cilium with Helm and wait until it is ready:

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
