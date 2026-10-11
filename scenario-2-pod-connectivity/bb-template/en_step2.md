### Pod Connectivity

#### Step 2 — Deploy the Applications on Different Nodes

Deploy two applications and pin each one to a different worker node with a
`nodeSelector`:

- **nginx**, a web server, on `kind-worker2`
- **netshoot-client**, a pod with network tools such as `curl`, on `kind-worker`

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 1
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
  labels:
    app.kubernetes.io/name: netshoot-client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
EOF
```

Wait until both pods are running, then show where they run:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -o wide
```

Look at the `IP` and `NODE` columns: nginx runs on `kind-worker2` and the netshoot-client on
`kind-worker`, each with its own pod IP (for example `10.244.2.127` and `10.244.1.67`).
The IPs come from different ranges because each node has its own pod address range.
