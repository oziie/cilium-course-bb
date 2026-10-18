# Scenario 5 — Network Policies (Layer 7)

**Scope:** Go beyond IPs and ports. Allow only specific HTTP methods and paths into the
API, require a header for a sensitive call, and limit the frontend's internet access to a
single domain name.

## Step 1 — Create the Cluster and Install Cilium

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

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, the cluster is
already there. Otherwise, create (or reuse) it with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-5-cilium-network-policies-layer7
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster from [`light-lab.yaml`](light-lab.yaml), installs Cilium
with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) and waits until
all nodes are `Ready`. If Cilium is already installed, it is left as is.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

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

</details>

> **Note:** If the namespaces and policies of scenario 4 are still in the cluster, remove
> them first (see the Cleanup section of scenario 4).

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

## Step 2 — Deploy the API and Deny All Ingress

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

## Step 3 — Allow Only Specific HTTP Calls

Allow `web` to call the API on port 8080, but only with these requests:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-web-to-api-http
  namespace: backend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: frontend
            app.kubernetes.io/name: web
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/products"
              - method: POST
                path: "/api/orders"
              - method: DELETE
                path: "/api/orders/[0-9]+"
                headers:
                  - "X-Team: ops"
EOF
```

- The L3/L4 part (`fromEndpoints` + `ports`) works as in the L3/L4 scenario.
- `rules.http` is new: each entry is one allowed request. A request must match **at least
  one** entry, otherwise Envoy rejects it.
- `method` and `path` are **regular expressions** matched against the whole value.
  `/api/orders/[0-9]+` matches `/api/orders/42`.
- The `DELETE` rule also needs the header `X-Team: ops`. A rule matches only when **all**
  its fields match.

**How to read the results.** With L7 rules, Envoy reads each request:

| You see | Meaning |
| --- | --- |
| JSON from the API | allowed |
| `Access denied` | denied by an **L7** rule: Envoy answered `403`, nginx never saw the request |
| `exit code 28` (timeout) | dropped at **L3/L4** |

Test it:

```bash
# Allowed: GET /api/products
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```
```bash
# Allowed: POST /api/orders
kubectl exec -n frontend web -- curl -s --max-time 3 -X POST http://api.backend:8080/api/orders
```
```bash
# Access denied: path /admin is not in the rules
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin
```
```bash
# Access denied: DELETE without the header
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42
```
```bash
# Allowed: DELETE with the header
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE -H 'X-Team: ops' http://api.backend:8080/api/orders/42
```
```bash
# Timeout (exit code 28): the intruder fails the L3 check, before Envoy
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080/api/products
```

> **Note:** A header is not authentication: any client allowed at L3 can set it. It shows
> how precise an L7 rule can be.

## Step 4 — Limit Internet Access by Domain Name

The frontend needs one external service, `api.github.com`, and nothing else on the
internet. Its IPs change all the time, so an IP-based rule would break. A `toFQDNs` rule
allows traffic by **name**:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress-fqdn
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toFQDNs:
        - matchName: api.github.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
EOF
```

The policy has three egress rules:

1. **DNS** to `kube-dns`, with a `dns` rule. This sends the pod's DNS queries through
   Cilium's **DNS proxy**. `matchPattern: "*"` lets the pod resolve any name.
2. The **API** on port 8080, so the frontend keeps working.
3. **`api.github.com`** on port 443. When the DNS answer for this name comes back, Cilium
   records its IPs and allows HTTPS to exactly those IPs.

Without the `dns` rule, Cilium never sees the DNS answers and `toFQDNs` matches nothing.

Test it:

```bash
# Allowed: HTTP/2 200 and the response headers
kubectl exec -n frontend web -- curl -sI --max-time 5 https://api.github.com
```
```bash
# Timeout (exit code 28): any other site is blocked
kubectl exec -n frontend web -- curl -sI --max-time 5 https://example.com
```
```bash
# Allowed: the API still works
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```

List the policies. The `VALID` column must be `True` for each of them:

```bash
kubectl get cnp -A
```

Final result:

| Request from `web` | Result |
| --- | --- |
| `GET /api/products`, `POST /api/orders` | allowed |
| `GET /admin`, `DELETE` without header | `Access denied` (L7) |
| `DELETE` with `X-Team: ops` | allowed |
| `https://api.github.com` | allowed |
| `https://example.com` | timeout (FQDN) |
| any request from `intruder` | timeout (L3) |

## Cleanup

Deleting the namespaces also deletes the policies inside them:

```bash
kubectl delete namespace frontend backend
kubectl delete pod intruder -n default
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
