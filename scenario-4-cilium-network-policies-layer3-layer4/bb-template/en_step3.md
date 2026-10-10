### Network Policies (L3/L4)

#### Step 3 — Allow Only the Traffic the Shop Needs

**Allow the frontend to call the API, on port 8080 only:**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-web-to-api
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
EOF
```

- `endpointSelector` picks the **destination**: the `api` pods in `backend`.
- `fromEndpoints` picks the **source**. Without a namespace label it would only match pods
  in the policy's own namespace (`backend`). The label
  `k8s:io.kubernetes.pod.namespace: frontend` selects the `web` pod in `frontend`.
- `toPorts` opens **TCP 8080 only**. The admin port 9090 on the same pod stays closed.

Test it:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```

Expected: `ALLOWED` for port 8080, `BLOCKED` for the admin port 9090, and `BLOCKED` for
the intruder (wrong namespace and labels).

Policies are **additive**: `default-deny-ingress` and `allow-web-to-api` both select the
`api` pod, and what is allowed is the union of their rules.

**Allow the API to reach Redis, on port 6379 only:**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-to-redis
  namespace: database
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: redis
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
EOF
```

Test it. The API sends a Redis `PING`, and the frontend tries to reach Redis directly:

```bash
kubectl exec -n backend deploy/api -- sh -c "printf 'PING\r\n' | nc -w 3 redis.database 6379"
kubectl exec -n frontend web -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

Expected: the API gets `+PONG` from Redis, and the frontend is `BLOCKED`: it has to go
through the API.
