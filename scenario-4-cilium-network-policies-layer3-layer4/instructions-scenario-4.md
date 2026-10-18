# Scenario 4 — Network Policies (L3/L4)

**Scope:** Lock down a small three-tier shop running in separate namespaces with
`CiliumNetworkPolicy`. Select pods by label across namespaces, allow only the ports each
caller needs, and see that everything else is dropped.

## Step 1 — Create the Cluster and Install Cilium

In this scenario you lock down a small three-tier shop with `CiliumNetworkPolicy`. Each
tier runs in its own namespace, and only the traffic each tier really needs is allowed.

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

First, build the lab cluster: 1 control-plane and 2 worker nodes, with Cilium as the
network plugin (CNI).

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, the cluster is
already there. Otherwise, create (or reuse) it with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-4-cilium-network-policies-layer3-layer4
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

Wait until Cilium is ready, then check the nodes:

```bash
cilium status --wait
```
```bash
kubectl get nodes
```

All three nodes must be `Ready`.

## Step 2 — Deploy the Shop and Deny All Ingress

The shop has three tiers, each in its own namespace:

| Namespace | Pod | Role |
| --- | --- | --- |
| `frontend` | `web` | the shop frontend, calls the API |
| `backend` | `api` | nginx with a public API on port **8080** and an admin page on port **9090** |
| `database` | `redis` | the database on port **6379**, only the API should use it |
| `default` | `intruder` | an unrelated pod that should be blocked everywhere |

Create the namespaces and the applications:

```bash
kubectl create namespace frontend
```
```bash
kubectl create namespace backend
```
```bash
kubectl create namespace database
```
```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: api-nginx-conf, namespace: backend}
data:
  default.conf: |
    server { listen 8080; location / { return 200 'api: public\n'; } }
    server { listen 9090; location / { return 200 'api: admin\n'; } }
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
  ports: [{name: http, port: 8080}, {name: admin, port: 9090}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: database}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: redis}}
  template:
    metadata: {labels: {app.kubernetes.io/name: redis}}
    spec:
      containers: [{name: redis, image: "redis:7-alpine"}]
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: database}
spec:
  selector: {app.kubernetes.io/name: redis}
  ports: [{port: 6379}]
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

**Baseline.** Without any policy, Cilium allows all traffic. Each test prints `ALLOWED` or
`BLOCKED`. A blocked connection is dropped silently, so the commands give up after 3
seconds:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
```
```bash
kubectl exec -n default intruder -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

All three are `ALLOWED`: even the intruder can reach the database.

**Default deny.** Apply a policy that selects every pod in `backend` and `database`:

```bash
for ns in backend database; do
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: $ns
spec:
  endpointSelector: {}
  ingress:
    - {}
EOF
done
```

- `endpointSelector: {}` selects **every pod in the policy's namespace**.
- The empty rule `- {}` allows nothing. As soon as a pod is selected by an ingress policy,
  Cilium switches it to **deny by default**: only traffic that a rule explicitly allows
  gets in.

Run the three tests above again: all of them are now `BLOCKED`, including the legitimate
`web` → `api:8080`. You fix that in the next step.

## Step 3 — Allow Only the Traffic the Shop Needs

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
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
```
```bash
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
```
```bash
kubectl exec -n frontend web -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

Expected: the API gets `+PONG` from Redis, and the frontend is `BLOCKED`: it has to go
through the API.

## Step 4 — Restrict What the Frontend Can Call (Egress)

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

## Cleanup

Deleting the namespaces also deletes the policies inside them:

```bash
kubectl delete namespace frontend backend database
kubectl delete pod intruder -n default
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
