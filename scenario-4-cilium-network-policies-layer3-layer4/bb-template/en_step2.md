### Network Policies (L3/L4)

#### Step 2 — Deploy the Shop and Deny All Ingress

The shop has three tiers, each in its own namespace:

| Namespace | Pod | Role |
| --- | --- | --- |
| `frontend` | `web` | the shop frontend, calls the API |
| `backend` | `api` | nginx with a public API on port **8080** and an admin page on port **9090** |
| `database` | `redis` | the database on port **6379**, only the API should use it |
| `default` | `intruder` | an unrelated pod that should be blocked everywhere |

Create the namespaces and the applications:

```bash
kubectl create namespace frontend
```
```bash
kubectl create namespace backend
```
```bash
kubectl create namespace database
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: api-nginx-conf, namespace: backend}
data:
  default.conf: |
    server { listen 8080; location / { return 200 'api: public\n'; } }
    server { listen 9090; location / { return 200 'api: admin\n'; } }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: backend}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: api}}
  template:
    metadata: {labels: {app.kubernetes.io/name: api}}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          volumeMounts: [{name: conf, mountPath: /etc/nginx/conf.d}]
      volumes: [{name: conf, configMap: {name: api-nginx-conf}}]
---
apiVersion: v1
kind: Service
metadata: {name: api, namespace: backend}
spec:
  selector: {app.kubernetes.io/name: api}
  ports: [{name: http, port: 8080}, {name: admin, port: 9090}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: database}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: redis}}
  template:
    metadata: {labels: {app.kubernetes.io/name: redis}}
    spec:
      containers: [{name: redis, image: "redis:7-alpine"}]
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: database}
spec:
  selector: {app.kubernetes.io/name: redis}
  ports: [{port: 6379}]
EOF
```
```bash
kubectl run web -n frontend --image=nicolaka/netshoot -l app.kubernetes.io/name=web -- sleep infinity
```
```bash
kubectl run intruder -n default --image=nicolaka/netshoot -l app.kubernetes.io/name=intruder -- sleep infinity
```
```bash
kubectl wait --for=condition=Ready pod --all -A --timeout=180s
```

**Baseline.** Without any policy, Cilium allows all traffic. Each test prints `ALLOWED` or
`BLOCKED`. A blocked connection is dropped silently, so the commands give up after 3
seconds:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
```
```bash
kubectl exec -n default intruder -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

All three are `ALLOWED`: even the intruder can reach the database.

**Default deny.** Apply a policy that selects every pod in `backend` and `database`:

```bash
for ns in backend database; do
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: $ns
spec:
  endpointSelector: {}
  ingress:
    - {}
EOF
done
```

- `endpointSelector: {}` selects **every pod in the policy's namespace**.
- The empty rule `- {}` allows nothing. As soon as a pod is selected by an ingress policy,
  Cilium switches it to **deny by default**: only traffic that a rule explicitly allows
  gets in.

Run the three tests above again: all of them are now `BLOCKED`, including the legitimate
`web` → `api:8080`. You fix that in the next step.
