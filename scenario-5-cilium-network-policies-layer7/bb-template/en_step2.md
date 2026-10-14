### Network Policies (Layer 7)

#### Step 2 — Deploy the API and Deny All Ingress

The `api` in the `backend` namespace serves several routes **on the same port 8080**:

| Request | Answer |
| --- | --- |
| `GET /api/products` | the product list |
| `GET`, `POST`, `DELETE /api/orders...` | the orders service |
| `GET /admin` | an internal admin page |

An L3/L4 rule (IP and port) cannot tell these routes apart. An L7 rule can.

Two client pods call it: `web` in `frontend` (the shop frontend) and `intruder` in
`default` (should be blocked everywhere).

```bash
kubectl create namespace frontend
```
```bash
kubectl create namespace backend
```
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: api-nginx-conf, namespace: backend}
data:
  default.conf: |
    server {
      listen 8080;
      default_type application/json;
      location /api/products { return 200 '{"products":["socks","mug","sticker"]}\n'; }
      location /api/orders   { return 200 '{"service":"orders","method":"$request_method"}\n'; }
      location /admin        { return 200 '{"admin":"internal settings"}\n'; }
    }
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
  ports: [{port: 8080}]
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

**Baseline.** Without any policy, everything is allowed. Even deleting an order and
reading the admin page work:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin
```

Both return JSON from the API.

**Default deny.** As in the L3/L4 scenario, deny all ingress into `backend`:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: backend
spec:
  endpointSelector: {}
  ingress:
    - {}
EOF
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```

The last command ends with `command terminated with exit code 28`: a **timeout**. The
packets were dropped at L3/L4, so nothing reaches the API yet.
