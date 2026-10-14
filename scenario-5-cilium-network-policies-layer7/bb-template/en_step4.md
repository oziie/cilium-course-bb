### Network Policies (Layer 7)

#### Step 4 — Limit Internet Access by Domain Name

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
