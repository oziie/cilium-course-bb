### Network Policies (Layer 7)

#### Step 3 — Allow Only Specific HTTP Calls

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
