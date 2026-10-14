### Gateway API

#### Step 4 — Canary Rollout with Weights and Headers

Bookinfo runs three versions of the `reviews` service (`v1`, `v2`, `v3`) behind one
`reviews` Service. To send a chosen share of traffic to each version, give each version
its own Service, selected by the pods' `version` label:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1
spec:
  selector:
    app: reviews
    version: v1
  ports:
    - name: http
      port: 9080
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2
spec:
  selector:
    app: reviews
    version: v2
  ports:
    - name: http
      port: 9080
EOF
```

Now add a **second** HTTPRoute on the same Gateway, as another team would. It sends 90%
of `/reviews` traffic to v1 and 10% to the new v2, and always sends testers who set the
`x-canary: true` header to v2:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /reviews
          headers:
            - name: x-canary
              value: "true"
      backendRefs:
        - name: reviews-v2
          port: 9080
    - matches:
        - path:
            type: PathPrefix
            value: /reviews
      backendRefs:
        - name: reviews-v1
          port: 9080
          weight: 90
        - name: reviews-v2
          port: 9080
          weight: 10
EOF
```

- `weight` splits traffic between backends in proportion: 90 + 10 = 100, so 90% and 10%.
- Both rules match `/reviews`, but the first also matches a header, so it is more
  specific and wins for requests with `x-canary: true`.

Each reviews response includes the name of the pod that served it. Send 100 requests and
count the versions:

```bash
for i in $(seq 1 100); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

About 90 go to `reviews-v1` and 10 to `reviews-v2`. The split is random per request, so
your numbers vary a little. With the header, every request goes to v2:

```bash
for i in $(seq 1 20); do curl -s -H "x-canary: true" "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

The canary looks healthy, so **promote v2** by moving all weight to it, then count again:

```bash
kubectl patch httproute reviews --type=json -p '[
  {"op": "replace", "path": "/spec/rules/1/backendRefs/0/weight", "value": 0},
  {"op": "replace", "path": "/spec/rules/1/backendRefs/1/weight", "value": 100}
]'
```
```bash
for i in $(seq 1 50); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

All 50 requests now go to `reviews-v2`. No pod restarted: Cilium only reprogrammed its
Envoy proxy. Two teams' routes share one Gateway and one IP, and the traffic split lives
in the standard API instead of in controller-specific annotations.
