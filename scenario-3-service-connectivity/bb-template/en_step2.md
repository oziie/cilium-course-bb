### Service Connectivity

#### Step 2 — Deploy the Applications and Create the Service

**Why a Service?** Pod IPs change every time a pod is recreated, so clients cannot rely
on them. A Service gives the application a stable virtual IP (the **ClusterIP**) and a
DNS name, and forwards traffic to the pods that match its selector.

Deploy nginx on `kind-worker2`, the client pod on `kind-worker`, and a Service named
`nginx-service` in front of nginx:

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
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF
```

In the Service:

- `selector` picks the backend pods: every pod with the label
  `app.kubernetes.io/name: nginx`, which is the label of the nginx pods.
- `port` is the port clients call on the Service, `targetPort` is the port on the pod.
- `type: ClusterIP` makes the Service reachable from inside the cluster only.

Wait for the pods, then look at the Service and the pods:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get service nginx-service
kubectl get pods -o wide
```

Check that the Service found the nginx pod:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=nginx-service
```

The `ENDPOINTS` column shows the **pod IP** of nginx. If it is empty, the selector does
not match any running pod.
