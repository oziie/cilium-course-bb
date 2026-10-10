### Ingress

#### Step 2 — Deploy Bookinfo and Create the Ingress

[Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) is a small sample application
from the Istio project: a `productpage` web page that calls the `details`, `reviews` and
`ratings` services. Deploy it:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl wait --for=condition=Ready pod --all --timeout=300s
kubectl get svc
```

All Bookinfo services are `ClusterIP`, reachable only from inside the cluster.

Create an Ingress that sends `/details` to the `details` service and everything else
(`/`) to `productpage`:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: basic-ingress
  namespace: default
spec:
  ingressClassName: cilium
  rules:
    - http:
        paths:
          - path: /details
            pathType: Prefix
            backend:
              service:
                name: details
                port:
                  number: 9080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: productpage
                port:
                  number: 9080
EOF
```

- `ingressClassName: cilium` hands this Ingress to the Cilium Ingress controller.
- `pathType: Prefix` matches the path and everything below it: `/details` also matches
  `/details/1`.

Cilium creates a `LoadBalancer` Service for the Ingress:

```bash
kubectl get svc cilium-ingress-basic-ingress
```

Its `EXTERNAL-IP` is `<pending>`. In a cloud, the provider's load balancer would fill it
in. kind has none, so you give Cilium a pool of IPs to use in the next step.
