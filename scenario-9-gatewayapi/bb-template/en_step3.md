### Gateway API

#### Step 3 — Route by Path with an HTTPRoute

An **HTTPRoute** is the application team's part: it attaches to a Gateway and says
where requests go. Create one that does what the Ingress did in Scenario 8: `/details`
goes to `details`, everything else to `productpage`:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /details
      backendRefs:
        - name: details
          port: 9080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: productpage
          port: 9080
EOF
```

- `parentRefs` attaches the route to `my-gateway`.
- `backendRefs` points to Services and ports directly.
- When several rules match, the **most specific** one wins, so `/details/1` goes to
  `details` even though `/` also matches. Rule order does not matter.

Check that the Gateway accepted the route:

```bash
kubectl get httproute bookinfo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
```

It prints `True`.

**Call the application from outside the cluster.** If `GATEWAY_IP` is empty, set it
again with the `GATEWAY_IP=...` command of step 2.

```bash
echo $INGRESS_IP
```

`/` goes to `productpage` and returns HTTP code `200`:

```bash
curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
```

`/details/1` goes to the `details` service and returns the details of book 1 as JSON:

```bash
curl --fail -s "http://$GATEWAY_IP/details/1"
```

So far this is the same result as the Ingress. The next step does something an `Ingress`
cannot describe.
