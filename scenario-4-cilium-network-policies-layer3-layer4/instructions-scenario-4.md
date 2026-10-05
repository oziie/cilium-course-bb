# Scenario 4 — Network Policies (L3/L4)

**Scope:** Lock down a small three-tier shop running in separate namespaces with
`CiliumNetworkPolicy`. Select pods by label across namespaces, allow only the ports each
caller needs, and see that everything else is dropped.

## Prepare the kind cluster (no need for BB)

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, skip this section.

Otherwise, create (or reuse) the cluster with the script in this folder:

```bash
cd scenario-4-cilium-network-policies-layer3-layer4
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script fails fast on errors, sets the `kind-kind` context in `$KUBECONFIG` (default
`~/.kube/config`) and verifies the node layout. A freshly created cluster has **no CNI**:
install Cilium by following
[Scenario 1 — Cilium Installation](../scenario-1-installation-cilium/instructions-scenario-1.md#cilium-installation-via-helm)
before continuing. Check it with `cilium status --wait`.

## The Use Case

Three teams each own a namespace. The frontend calls the API, the API reads from the
database, and nothing else should get through.

```
 ns: frontend           ns: backend                   ns: database
┌─────────────┐  8080  ┌───────────────────┐  6379   ┌─────────────┐
│ web         │──────▶ │ api (nginx)       │──────▶  │ redis       │
│ (netshoot)  │        │  :8080 public API │         │  :6379      │
└─────────────┘        │  :9090 admin      │         └─────────────┘
                       └───────────────────┘
 ns: default
┌─────────────┐
│ intruder    │   should be blocked everywhere
│ (netshoot)  │
└─────────────┘
```

| File | Contents |
| --- | --- |
| [`namespaces.yaml`](namespaces.yaml) | `frontend`, `backend`, `database` namespaces |
| [`app-api.yaml`](app-api.yaml) | nginx `api` Deployment + Service, listening on 8080 (API) and 9090 (admin) |
| [`app-redis.yaml`](app-redis.yaml) | `redis` Deployment + Service on 6379 |
| [`app-clients.yaml`](app-clients.yaml) | `web` pod in `frontend`, `intruder` pod in `default` |
| [`cnp-01-default-deny.yaml`](cnp-01-default-deny.yaml) | Deny all ingress in `backend` and `database` |
| [`cnp-02-allow-web-to-api.yaml`](cnp-02-allow-web-to-api.yaml) | `web` → `api` on TCP 8080 |
| [`cnp-03-allow-api-to-redis.yaml`](cnp-03-allow-api-to-redis.yaml) | `api` → `redis` on TCP 6379 |
| [`cnp-04-web-egress-no-dns.yaml`](cnp-04-web-egress-no-dns.yaml) | `web` egress limited to `api:8080` (DNS missing on purpose) |
| [`cnp-04-web-egress.yaml`](cnp-04-web-egress.yaml) | Same, with DNS to `kube-dns` allowed |

## Deploy the Applications

```bash
cd scenario-4-cilium-network-policies-layer3-layer4

kubectl apply -f namespaces.yaml
kubectl apply -f app-api.yaml -f app-redis.yaml -f app-clients.yaml

kubectl wait --for=condition=Ready pod --all -n backend  --timeout=120s
kubectl wait --for=condition=Ready pod --all -n database --timeout=120s
kubectl wait --for=condition=Ready pod/web -n frontend   --timeout=120s
kubectl wait --for=condition=Ready pod/intruder -n default --timeout=120s
```

## Baseline: Everything Can Reach Everything

Without any policy, Cilium allows all traffic. Each command prints `ALLOWED` or `BLOCKED`.
A blocked connection is dropped silently, so the commands use a 3-second timeout.

```bash
# web -> api public port
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED

# web -> api admin port
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 \
  && echo ALLOWED || echo BLOCKED

# web -> redis
kubectl exec -n frontend web -- nc -z -w 3 redis.database 6379 \
  && echo ALLOWED || echo BLOCKED

# intruder -> api
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED

# api -> redis (the nginx alpine image ships busybox nc)
kubectl exec -n backend deploy/api -- sh -c "printf 'PING\r\n' | nc -w 3 redis.database 6379"
```

All five succeed: the frontend, and even the intruder, can talk to the database and the
admin port directly.

## Step 1 — Default Deny Ingress

```yaml
# cnp-01-default-deny.yaml (backend copy; the database copy is identical)
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: backend
spec:
  endpointSelector: {}
  ingress:
    - {}
```

- `endpointSelector: {}` selects **every pod in the policy's namespace**.
- The single empty rule `- {}` allows nothing. As soon as a pod is selected by any ingress
  rule, Cilium switches it to **deny by default** for ingress, and only traffic that some
  rule explicitly allows gets through.

```bash
kubectl apply -f cnp-01-default-deny.yaml
kubectl get cnp -A
```

Re-run the baseline commands: every connection into `backend` and `database` is now
`BLOCKED`, including the legitimate ones.

> **Note:** A `CiliumNetworkPolicy` is namespaced and only selects pods in its own
> namespace. That is why the file contains one copy per namespace. To cover the whole
> cluster at once, use a `CiliumClusterwideNetworkPolicy`.

## Step 2 — Allow the Frontend to Call the API

```yaml
# cnp-02-allow-web-to-api.yaml
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
```

- `endpointSelector` picks the **destination**: the `api` pods in `backend`.
- `fromEndpoints` picks the **source**. Without a namespace label it only matches pods in
  the policy's own namespace (`backend`). Adding
  `k8s:io.kubernetes.pod.namespace: frontend` selects the `web` pod in `frontend`.
- `toPorts` opens **TCP 8080 only**. The admin port 9090 on the same pod stays closed.

```bash
kubectl apply -f cnp-02-allow-web-to-api.yaml

# web -> api:8080   expected: ALLOWED
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED

# web -> api:9090   expected: BLOCKED (port not in toPorts)
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 \
  && echo ALLOWED || echo BLOCKED

# intruder -> api:8080   expected: BLOCKED (wrong namespace and labels)
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED
```

> **Note:** Policies are additive. `default-deny-ingress` and `allow-web-to-api` both
> select the `api` pod, and the allowed traffic is the union of their rules. Order does
> not matter, and there is no "deny wins" between these two.

## Step 3 — Allow the API to Reach Redis

```yaml
# cnp-03-allow-api-to-redis.yaml
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
```

```bash
kubectl apply -f cnp-03-allow-api-to-redis.yaml

# api -> redis   expected: +PONG
kubectl exec -n backend deploy/api -- sh -c "printf 'PING\r\n' | nc -w 3 redis.database 6379"

# web -> redis   expected: BLOCKED (the frontend must go through the API)
kubectl exec -n frontend web -- nc -z -w 3 redis.database 6379 \
  && echo ALLOWED || echo BLOCKED
```

## Step 4 — Restrict What the Frontend Can Call (Egress)

So far every policy was **ingress**: it protects the destination. An **egress** policy
limits what a source can call, which is useful when the frontend is the most exposed part
of the system.

First apply a version that looks correct but forgets DNS:

```yaml
# cnp-04-web-egress-no-dns.yaml
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
```

```bash
kubectl apply -f cnp-04-web-egress-no-dns.yaml

# By name   expected: BLOCKED (the DNS lookup itself is dropped)
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED

# By Service IP   expected: ALLOWED (no DNS needed)
API_IP=$(kubectl get svc api -n backend -o jsonpath='{.spec.clusterIP}')
kubectl exec -n frontend web -- curl -s --max-time 3 "http://${API_IP}:8080" \
  && echo ALLOWED || echo BLOCKED
```

The `web` pod is now in deny-by-default for **egress**, and its DNS queries to `kube-dns`
in `kube-system` are not on the allow list. This is the most common mistake with egress
policies.

Fix it by allowing UDP and TCP 53 to `kube-dns`:

```yaml
# cnp-04-web-egress.yaml (only the added rule is shown)
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
```

```bash
kubectl apply -f cnp-04-web-egress.yaml   # same name, replaces the no-dns version

# expected: ALLOWED
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 \
  && echo ALLOWED || echo BLOCKED
```

> **Note:** Traffic to a Service is checked against the **backend pod** it is load-balanced
> to, not the ClusterIP. That is why `toEndpoints` matching the `api` pod labels also
> covers `http://api.backend:8080`.

## Final Check

```bash
check() {  # usage: check <description> <namespace> <pod|deploy/name> <command...>
  local desc="$1" ns="$2" pod="$3"; shift 3
  if kubectl exec -n "$ns" "$pod" -- "$@" >/dev/null 2>&1; then
    printf '%-28s ALLOWED\n' "$desc"
  else
    printf '%-28s BLOCKED\n' "$desc"
  fi
}

check "web -> api:8080"      frontend web      curl -s --max-time 3 http://api.backend:8080
check "web -> api:9090"      frontend web      curl -s --max-time 3 http://api.backend:9090
check "web -> redis:6379"    frontend web      nc -z -w 3 redis.database 6379
check "intruder -> api:8080" default  intruder curl -s --max-time 3 http://api.backend:8080
check "intruder -> redis"    default  intruder nc -z -w 3 redis.database 6379
check "api -> redis:6379"    backend  deploy/api \
  sh -c "printf 'PING\r\n' | nc -w 3 redis.database 6379 | grep -q PONG"
```

| Path | Expected |
| --- | --- |
| web → api:8080 | ALLOWED |
| web → api:9090 | BLOCKED |
| web → redis:6379 | BLOCKED |
| intruder → api:8080 | BLOCKED |
| intruder → redis | BLOCKED |
| api → redis:6379 | ALLOWED |

## Inspect the Policies

List the policies and confirm Cilium accepted them (`VALID` should be `True`):

```bash
kubectl get cnp -A
```

Check enforcement per endpoint. Each Cilium agent only knows the endpoints on its own
node, so run this on the agent next to the pod you are interested in:

```bash
NODE=$(kubectl get pod -n backend -l app.kubernetes.io/name=api -o jsonpath='{.items[0].spec.nodeName}')
AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName="$NODE" -o name)

kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg endpoint list
```

The `POLICY (ingress) ENFORCEMENT` column shows `Enabled` for `api` and `redis`, and
`POLICY (egress) ENFORCEMENT` shows `Enabled` for `web`.

Watch drops live while you re-run a blocked command in another terminal:

```bash
kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg monitor --type drop
```

You should see `Policy denied` drops for the blocked connections. Scenario 6 explores this
in depth with Hubble.

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
