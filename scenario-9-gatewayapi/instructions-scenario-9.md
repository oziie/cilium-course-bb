# Scenario 9 — Gateway API

**Scope:** Expose Bookinfo with Gateway API instead of Ingress: a `Gateway` owned by the
platform team, `HTTPRoute`s owned by the application teams, path routing, and a canary
rollout with weights and headers.

## Step 1 — Create the Cluster, Install the Gateway API CRDs and Cilium

In Scenario 8 you exposed Bookinfo with an `Ingress`. Ingress only routes by host and
path; anything more needs controller-specific annotations. **Gateway API** is its
successor, and it splits the job into resources owned by different roles:

| Resource | Owned by | What it describes |
| --- | --- | --- |
| `GatewayClass` | infrastructure provider | which controller implements Gateways (here: `cilium`) |
| `Gateway` | platform team | an entry point: listeners, ports, an IP |
| `HTTPRoute` | application team | routing rules: matches, backends, weights |

This scenario needs a cluster **without kube-proxy**: Cilium replaces it.
Delete any previous cluster, then create the new one with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-9-gatewayapi
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

The kind config [`light-lab.yaml`](light-lab.yaml) is the usual 1 control-plane + 2
workers with `disableDefaultCNI: true`, plus `kubeProxyMode: none`, which tells kind not
to install kube-proxy. The script installs Cilium with the values in
[`cilium-values.yaml`](cilium-values.yaml):

```yaml
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
l2announcements:
  enabled: true
gatewayAPI:
  enabled: true
```

- `kubeProxyReplacement: true`: required by Gateway API support and L2 announcements.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs.
- `gatewayAPI.enabled: true`: turns on the Gateway API controller in the Cilium operator.

Gateway API resources are CRDs, not built into Kubernetes. **They must be installed before
Cilium:** Cilium only starts its Gateway API controller, and the Helm chart only creates
the `cilium` GatewayClass, if the CRDs already exist. Cilium 1.18 supports Gateway API
**v1.3.0**. The script installs these CRDs before Cilium for you.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

```bash
kind delete cluster --name kind
```
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
  kubeProxyMode: none
EOF
```
```bash
kind create cluster --config light-lab.yaml
```
```bash
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes; do
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml
done
```
```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
l2announcements:
  enabled: true
gatewayAPI:
  enabled: true
EOF
```
```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

</details>

Wait until Cilium is ready:

```bash
cilium status --wait
```

Check the settings and the GatewayClass:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-gateway-api '
```
```bash
kubectl get gatewayclass
```

All three settings are `true`, and the `cilium` GatewayClass shows `ACCEPTED` `True`:
the Cilium operator has taken ownership of it.

## Step 2 — Deploy Bookinfo and Create the Gateway

Deploy [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/), the same sample
application as in Scenario 8:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```
```bash
kubectl wait --for=condition=Ready pod --all --timeout=300s
```

A `Gateway` gets a `LoadBalancer` Service, so it needs an external IP exactly like the
Ingress in Scenario 8: an LB-IPAM pool inside the `kind` Docker network, and an L2
announcement policy so a worker answers ARP requests for that IP. Check the subnet:

```bash
docker network inspect kind | grep Subnet
```

It is usually `172.18.0.0/16`. Create the pool and the policy:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 172.18.255.200/29
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  loadBalancerIPs: true
  interfaces:
    - eth0
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
EOF
```

> **Note:** If your IPv4 subnet is different, for example `172.19.0.0/16`, use the same
> range in your subnet (`172.19.255.200/29`) in the command above.

Now create the **Gateway**: one HTTP listener on port 80, implemented by the `cilium`
GatewayClass. This is the platform team's part:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
EOF
```

Cilium creates a `LoadBalancer` Service named `cilium-gateway-my-gateway`, and LB-IPAM
gives it an IP:

```bash
kubectl get gateway my-gateway
```
```bash
kubectl get svc cilium-gateway-my-gateway
```

The Gateway shows the same IP in `ADDRESS` and `PROGRAMMED` `True`. Save the IP:

```bash
GATEWAY_IP=$(kubectl get gateway my-gateway -o jsonpath='{.status.addresses[0].value}')
echo $GATEWAY_IP
```

The Gateway has no routes yet, so every request returns `404`:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
```

## Step 3 — Route by Path with an HTTPRoute

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
again with the `GATEWAY_IP=...` command of step 2:

```bash
echo $GATEWAY_IP
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

## Step 4 — Canary Rollout with Weights and Headers

Bookinfo runs three versions of the `reviews` service (`v1`, `v2`, `v3`) behind one
`reviews` Service. This step uses only `v1` (the current version) and `v2` (the canary),
so it creates Services for those two. The `v3` pods keep running, but the route below
never sends traffic to them.

To send a chosen share of traffic to each version, give each version its own Service,
selected by the pods' `version` label:

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

## Cleanup

Remove the routes, the Gateway, the Cilium objects and Bookinfo:

```bash
kubectl delete httproute reviews bookinfo
kubectl delete service reviews-v1 reviews-v2
kubectl delete gateway my-gateway
kubectl delete ciliuml2announcementpolicy policy1
kubectl delete ciliumloadbalancerippool pool
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
