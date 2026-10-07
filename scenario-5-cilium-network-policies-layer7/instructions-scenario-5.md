# Scenario 5 — Network Policies (Layer 7)

**Scope:** Go beyond IPs and ports. Allow only specific HTTP methods and paths into the
API, require a header for a sensitive call, and limit the frontend's internet access to a
single domain name. Same shop and namespaces as scenario 4.

## Prepare the kind cluster (no need for BB)

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, skip this section.

Otherwise, create (or reuse) the cluster with the script in this folder:

```bash
cd scenario-5-cilium-network-policies-layer7
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script fails fast on errors, sets the `kind-kind` context in `$KUBECONFIG` (default
`~/.kube/config`) and verifies the node layout. A freshly created cluster has **no CNI**:
install Cilium by following
[Scenario 1 — Cilium Installation](../scenario-1-installation-cilium/instructions-scenario-1.md#cilium-installation-via-helm)
before continuing. Check it with `cilium status --wait`.

L7 policies are enforced by Envoy. The Scenario 1 install already runs it as the
`cilium-envoy` DaemonSet, so there is nothing extra to enable:

```bash
kubectl get -n kube-system daemonset cilium-envoy
```

## The Use Case

In scenario 4 the frontend could call the API on port 8080, and that was it: any method,
any path. Now the API serves a public catalog, an orders endpoint and an internal admin
page **on the same port**. An L4 rule cannot tell them apart, an L7 rule can.

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

| File | Contents |
| --- | --- |
| [`namespaces.yaml`](namespaces.yaml) | `frontend`, `backend`, `database` namespaces (same as scenario 4) |
| [`app-api.yaml`](app-api.yaml) | nginx `api` on 8080 with `/api/products`, `/api/orders` and `/admin` |
| [`app-redis.yaml`](app-redis.yaml) | `redis` Deployment + Service on 6379 (same as scenario 4) |
| [`app-clients.yaml`](app-clients.yaml) | `web` pod in `frontend`, `intruder` pod in `default` (same as scenario 4) |
| [`cnp-00-baseline.yaml`](cnp-00-baseline.yaml) | Scenario 4 baseline: default deny ingress + `api` → `redis` |
| [`cnp-01-api-http.yaml`](cnp-01-api-http.yaml) | `web` → `api`: only `GET /api/products`, `GET` and `POST /api/orders` |
| [`cnp-02-api-http-header.yaml`](cnp-02-api-http-header.yaml) | Same, plus `DELETE /api/orders/<id>` with header `X-Team: ops` |
| [`cnp-03-web-egress-fqdn.yaml`](cnp-03-web-egress-fqdn.yaml) | `web` egress: DNS, `api:8080` and `api.github.com:443` only |

## Deploy the Applications

If scenario 4 is still deployed, clean it up first (see its Cleanup section). Then:

```bash
cd scenario-5-cilium-network-policies-layer7

kubectl apply -f namespaces.yaml
kubectl apply -f app-api.yaml -f app-redis.yaml -f app-clients.yaml

kubectl wait --for=condition=Ready pod --all -n backend  --timeout=120s
kubectl wait --for=condition=Ready pod --all -n database --timeout=120s
kubectl wait --for=condition=Ready pod/web -n frontend   --timeout=120s
kubectl wait --for=condition=Ready pod/intruder -n default --timeout=120s
```

## How to Read the Results

In scenario 4 a blocked connection was **dropped**, so the client timed out. With L7
rules the TCP connection is accepted and Envoy reads the request. If no rule matches, Envoy
answers **`403 Forbidden`** with the body `Access denied`.

So the output of each command tells you what happened:

| You see | Meaning |
| --- | --- |
| JSON from the API | Allowed, answered by nginx |
| `Access denied` | Denied by an **L7** rule (Envoy answered, nginx never saw the request) |
| `command terminated with exit code 28` | Timeout: dropped at **L3/L4**, as in scenario 4 |

## Baseline: Everything Can Reach Everything

```bash
# GET the product list
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products

# DELETE an order
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42

# Read the admin page
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin

# The intruder calls the API
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080/api/products
```

Every command returns JSON from the API, including deleting orders and reading the admin
page.

## Step 1 — L3/L4 Baseline from Scenario 4

Apply the default deny and the `api` → `redis` rule you built in scenario 4:

```bash
kubectl apply -f cnp-00-baseline.yaml
kubectl get cnp -A
```

```bash
# expected: command terminated with exit code 28 (dropped)
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```

Nothing reaches the API yet. Redis stays reachable from the API only, as in scenario 4.

> **Note:** Cilium has no L7 parser for the Redis protocol, so `api` → `redis` stays an
> L4 rule. L7 rules are available for HTTP (including gRPC), Kafka and DNS.

## Step 2 — Allow Only Specific HTTP Calls

```yaml
# cnp-01-api-http.yaml
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
              - method: GET
                path: "/api/orders"
              - method: POST
                path: "/api/orders"
```

- The L3/L4 part (`fromEndpoints` + `ports`) is the same as scenario 4.
- `rules.http` is new. Each entry is one allowed request shape. A request must match
  **at least one** entry. Anything else on this port gets `Access denied`.
- `method` and `path` are **regular expressions** that must match the whole value.
  `/api/products` does not match `/api/products/1`. Use `/api/products(/.*)?` for that.

```bash
kubectl apply -f cnp-01-api-http.yaml

# GET /api/products   expected: product list
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products

# POST /api/orders   expected: {"service":"orders","method":"POST",...}
kubectl exec -n frontend web -- curl -s --max-time 3 -X POST http://api.backend:8080/api/orders

# DELETE /api/orders/42   expected: Access denied (method not allowed)
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42

# GET /admin   expected: Access denied (path not allowed)
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin

# intruder   expected: command terminated with exit code 28 (dropped at L3)
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080/api/products
```

> **Note:** The `intruder` still times out instead of getting `Access denied`. It fails
> the L3 check (`fromEndpoints`), so its packets are dropped before they reach Envoy.

## Step 3 — Require a Header for Sensitive Calls

Support staff use the frontend to cancel orders. Deleting must stay possible, but only
for requests tagged by the ops tooling with `X-Team: ops`.

```yaml
# cnp-02-api-http-header.yaml (only the added rule is shown)
              - method: DELETE
                path: "/api/orders/[0-9]+"
                headers:
                  - "X-Team: ops"
```

A rule matches only when **all** its fields match: method, path and every listed header.

```bash
kubectl apply -f cnp-02-api-http-header.yaml   # same name, replaces cnp-01


# Without the header   expected: Access denied
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42

# With the header   expected: {"service":"orders","method":"DELETE",...}
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE -H 'X-Team: ops' http://api.backend:8080/api/orders/42

# Wrong header value   expected: Access denied
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE -H 'X-Team: dev' http://api.backend:8080/api/orders/42
```

> **Note:** A header is not authentication: any client allowed at L3 can set it. In real
> life you would match on something the client cannot forge, or combine this with
> mutual authentication. Here it shows how fine-grained an L7 rule can be.

## Step 4 — Limit the Frontend's Egress by Domain Name

The frontend needs one external service, `api.github.com`, and nothing else on the
internet. Its IPs change all the time, so an IP-based (`toCIDR`) rule would break.
`toFQDNs` allows traffic by **name**.

```yaml
# cnp-03-web-egress-fqdn.yaml
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
              protocol: UDP
            - port: "53"
              protocol: TCP
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
```

How it works:

1. The `dns` rule sends the pod's DNS traffic through Cilium's **DNS proxy**. This is an
   L7 rule too. `matchPattern: "*"` lets the pod resolve any name.
2. When the answer for `api.github.com` comes back, Cilium records its IPs.
3. The `toFQDNs` rule allows TCP 443 to exactly those IPs.

Without the `dns` rule, Cilium never sees the DNS answers and `toFQDNs` matches nothing.

```bash
kubectl apply -f cnp-03-web-egress-fqdn.yaml


# Allowed domain   expected: HTTP/2 200 (followed by headers)
kubectl exec -n frontend web -- curl -sI --max-time 3 https://api.github.com

# Any other domain   expected: command terminated with exit code 28 (dropped)
kubectl exec -n frontend web -- curl -sI --max-time 3 https://example.com

# The API is still allowed   expected: product list
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products

# Resolving other names still works, connecting to them does not
kubectl exec -n frontend web -- nslookup example.com
```

See the names and IPs Cilium learned, on the agent running next to `web`:

```bash
NODE=$(kubectl get pod web -n frontend -o jsonpath='{.spec.nodeName}')
AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName="$NODE" -o name)

kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg fqdn cache list
```

> **Note:** This needs internet access from the kind nodes. If `api.github.com` times
> out too, check that `curl https://api.github.com` works from your machine first.

## Final Check

With all policies applied, the commands from the steps above give:

| Request | Expected |
| --- | --- |
| web → `GET /api/products` | JSON (allowed) |
| web → `POST /api/orders` | JSON (allowed) |
| web → `GET /admin` | `Access denied` (L7) |
| web → `DELETE /api/orders/42` | `Access denied` (L7) |
| web → `DELETE /api/orders/42` + `X-Team: ops` | JSON (allowed) |
| intruder → `GET /api/products` | Timeout (L3) |
| web → `https://api.github.com` | `HTTP/2 200` (allowed) |
| web → `https://example.com` | Timeout (FQDN) |

## Inspect the Policies

Confirm Cilium accepted the policies (`VALID` should be `True`):

```bash
kubectl get cnp -A
```

Watch L7 verdicts live on the agent next to the `api` pod, then re-run a few `curl`
commands in another terminal:

```bash
NODE=$(kubectl get pod -n backend -l app.kubernetes.io/name=api -o jsonpath='{.items[0].spec.nodeName}')
AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName="$NODE" -o name)

kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg monitor -t l7
```

Each request is logged with its method, URL and verdict: `Forwarded` for allowed calls,
`Denied` for the ones that got `Access denied`. The `intruder` requests do not show up here
because they are dropped before reaching Envoy. Use `cilium-dbg monitor --type drop` for
those, as in scenario 4. Scenario 6 explores all of this with Hubble.

## Cleanup

Deleting the namespaces also deletes the policies inside them:

```bash
kubectl delete -f namespaces.yaml
kubectl delete pod intruder -n default
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
