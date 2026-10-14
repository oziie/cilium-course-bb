### Network Policies (L3/L4)

#### Step 4 — Restrict What the Frontend Can Call (Egress)

So far every policy was **ingress**: it protects the destination. An **egress** policy
limits what a source can call. Limit `web` to the API on port 8080:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
EOF
```

Call the API by name, then by its Service IP:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```
```bash
API_IP=$(kubectl get svc api -n backend -o jsonpath='{.spec.clusterIP}')
kubectl exec -n frontend web -- curl -s --max-time 3 http://$API_IP:8080 && echo ALLOWED || echo BLOCKED
```

By name it is `BLOCKED`, by IP it is `ALLOWED`. Why? `web` is now in deny-by-default for
egress, and its **DNS queries** to `kube-dns` are not on the allow list, so the name
`api.backend` can no longer be resolved. Forgetting DNS is the most common mistake with
egress policies.

Fix it by applying the same policy with a second rule that allows DNS (UDP and TCP 53)
to `kube-dns`. The policy has the same name, so it replaces the previous one:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
EOF
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```

Calling by name is `ALLOWED` again.

List all the policies. The `VALID` column must be `True` for each of them:

```bash
kubectl get cnp -A
```

Final result:

| Path | Result |
| --- | --- |
| web → api:8080 | ALLOWED |
| web → api:9090 | BLOCKED |
| web → redis:6379 | BLOCKED |
| intruder → api / redis | BLOCKED |
| api → redis:6379 | ALLOWED |
