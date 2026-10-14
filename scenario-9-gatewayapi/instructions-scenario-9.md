# Scenario 9 — Gateway API

**Scope:** Expose the Bookinfo sample application with Cilium's **Gateway API**
implementation, the successor to Ingress. Install the Gateway API CRDs, create a
`Gateway`, route traffic with `HTTPRoute`s by path and header, and run a 90/10 canary
rollout that the `Ingress` API cannot describe.

## Why Gateway API

Scenario 8 used an `Ingress`. Ingress is simple, but it only routes by host and path.
Everything else (traffic splitting, header matching, rewrites) lives in
controller-specific annotations that differ between implementations. Upstream
ingress-nginx, the most widely used controller, has been retired, and the Kubernetes
project points users to Gateway API instead.

Gateway API splits the old `Ingress` object into resources owned by different roles:

| Resource | Owned by | What it describes |
| --- | --- | --- |
| `GatewayClass` | infrastructure provider | which controller implements Gateways (here: `cilium`) |
| `Gateway` | platform / cluster operator | an entry point: listeners, ports, protocols, an IP |
| `HTTPRoute` | application team | routing rules: matches, filters, backends, weights |

Several teams can attach their own `HTTPRoute`s to one shared `Gateway` without touching
each other's rules.

```
curl (Docker host) ──▶ 172.18.255.200 ──ARP──▶ kind-worker (eth0)
                                                    │
                                     Gateway my-gateway (Cilium Envoy)
                                                    │
               HTTPRoute bookinfo            HTTPRoute reviews
              /details ──┬── /           /reviews ──┬── 90% ── reviews-v1
                         ▼    ▼                     └── 10% ── reviews-v2
                    details  productpage        (x-canary: true ──▶ reviews-v2)
```

## Prepare the kind cluster (no need for BB)

Like Scenario 8, this scenario needs a cluster **without kube-proxy**. Delete the
previous cluster first, then create a new one:

```bash
cd scenario-9-gatewayapi
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

[`light-lab.yaml`](light-lab.yaml) is the same as in Scenario 8: 1 control-plane + 2
workers, `disableDefaultCNI: true` and `kubeProxyMode: none`.

### Gateway API CRDs come first

Gateway API resources are not part of Kubernetes itself: they are CRDs maintained by the
Kubernetes SIG Network project. **Install them before Cilium.** The Cilium operator only
starts its Gateway API controller if the CRDs exist when it starts, and the Helm chart
only creates the `cilium` GatewayClass if it sees the CRDs at install time.

Cilium 1.18 supports Gateway API **v1.3.0**. The script installs the standard-channel
CRDs that Cilium needs:

```bash
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes; do
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml
done
```

> **Note:** Always match the CRD version to your Cilium version (see the Gateway API page
> of the Cilium docs for your release). `TLSRoute` lives in the *experimental* channel
> and is not needed here.

### Cilium settings

The script then installs Cilium with [`cilium-values.yaml`](cilium-values.yaml):

```yaml
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
kubeProxyReplacement: true
l2announcements:
  enabled: true
ipam:
  mode: kubernetes
gatewayAPI:
  enabled: true
```

- `kubeProxyReplacement: true`: required by Cilium's Gateway API support and by L2
  announcements.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs, as in
  Scenario 8.
- `gatewayAPI.enabled: true`: turns on the Gateway API controller in the Cilium operator.

The script runs the equivalent of:

```bash
helm upgrade --install cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

Check the settings and the GatewayClass:

```bash
$ cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-gateway-api '
enable-gateway-api                                true
enable-l2-announcements                           true
kube-proxy-replacement                            true
$ kubectl get gatewayclass
NAME     CONTROLLER                     ACCEPTED   AGE
cilium   io.cilium/gateway-controller   True       2m
```

`ACCEPTED True` means the Cilium operator has taken ownership of the `cilium` class.

> **Troubleshooting:** If `kubectl get gatewayclass` returns `No resources found` or
> `error: the server doesn't have a resource type "gatewayclass"`, the CRDs were missing
> when Cilium was installed. Install the CRDs, then restart the operator:
> `kubectl -n kube-system rollout restart deployment/cilium-operator`. If the class is
> still missing, recreate the cluster.

## Deploy Bookinfo and Prepare the External IP

Deploy [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/), the same sample
application as in Scenario 8:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl wait --for=condition=Ready pod --all --timeout=300s
```

A `Gateway` gets a `LoadBalancer` Service, so it needs LB-IPAM and an L2 announcement
policy, exactly like the Ingress in Scenario 8. Check the subnet of the `kind` Docker
network and apply [`lb-ippool.yaml`](lb-ippool.yaml) and
[`l2-announcement-policy.yaml`](l2-announcement-policy.yaml):

```bash
docker network inspect kind | grep Subnet   # usually 172.18.0.0/16
kubectl apply -f lb-ippool.yaml -f l2-announcement-policy.yaml
```

> **Note:** If your IPv4 subnet is different (for example `172.19.0.0/16`), change the
> `cidr` in `lb-ippool.yaml` to the same range in your subnet (`172.19.255.200/29`)
> before applying.

## Create the Gateway

[`gateway.yaml`](gateway.yaml) opens one HTTP listener on port 80, implemented by the
`cilium` GatewayClass:

```yaml
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
```

```bash
$ kubectl apply -f gateway.yaml
$ kubectl get gateway my-gateway
NAME         CLASS    ADDRESS          PROGRAMMED   AGE
my-gateway   cilium   172.18.255.200   True         10s
```

Cilium creates a `LoadBalancer` Service named `cilium-gateway-<gateway name>`, and
LB-IPAM gives it an IP right away:

```bash
$ kubectl get svc cilium-gateway-my-gateway
NAME                        TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
cilium-gateway-my-gateway   LoadBalancer   10.96.53.120   172.18.255.200   80:30412/TCP
```

Save the address:

```bash
GATEWAY_IP=$(kubectl get gateway my-gateway -o jsonpath='{.status.addresses[0].value}')
echo $GATEWAY_IP
```

The Gateway has an IP, but no routes yet. Any request returns `404`:

```bash
$ curl -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
404
```

## Route by Path with an HTTPRoute

[`httproute-bookinfo.yaml`](httproute-bookinfo.yaml) does what the Ingress did in
Scenario 8: `/details` goes to `details`, everything else to `productpage`:

```yaml
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
```

- `parentRefs` attaches the route to `my-gateway`. The route belongs to the app team,
  the Gateway to the platform team.
- `backendRefs` points to Services and ports directly.
- When several rules match, the **most specific** match wins, so `/details/1` goes to
  `details` even though `/` also matches. Rule order does not matter.

```bash
$ kubectl apply -f httproute-bookinfo.yaml
$ kubectl get httproute bookinfo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
True
$ curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
200
$ curl --fail -s "http://$GATEWAY_IP/details/1"
{"id":1,"author":"William Shakespeare","year":1595,...}
```

> **Note:** On macOS (Docker Desktop, OrbStack), Docker runs in a VM, so `curl` from the
> Mac cannot reach the IP. Run it from a container on the `kind` network:
>
> ```bash
> docker run --rm --network kind curlimages/curl -s "http://$GATEWAY_IP/details/1"
> ```

## Canary Rollout with Weights and Headers

Bookinfo runs three versions of the `reviews` service (`v1`, `v2`, `v3`) behind a single
`reviews` Service. This section uses only `v1` (the current version) and `v2` (the
canary), so it creates Services for those two. The `v3` pods keep running, but the route
below never sends traffic to them.

To send a chosen share of traffic to each version, give each version its own Service. [`reviews-services.yaml`](reviews-services.yaml) creates `reviews-v1`
and `reviews-v2`, selecting pods by their `version` label:

```bash
kubectl apply -f reviews-services.yaml
```

[`httproute-reviews-canary.yaml`](httproute-reviews-canary.yaml) is a **second**
`HTTPRoute` on the same Gateway, as another team would write it:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    # Testers who send "x-canary: true" always get v2.
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
    # Everyone else: 90% v1, 10% v2.
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
```

- `weight` splits traffic between backends in proportion: 90 + 10 = 100, so 90% and 10%.
- Both rules match `/reviews`, but the first one also matches a header, so it is more
  specific and wins for requests with `x-canary: true`.

Neither of these can be written with a plain `Ingress`.

```bash
kubectl apply -f httproute-reviews-canary.yaml
```

Each reviews response includes the name of the pod that served it. Send 100 requests and
count the versions:

```bash
$ for i in $(seq 1 100); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
     91 reviews-v1
      9 reviews-v2
```

The split is about 90/10. It is random per request, so your numbers vary a little.

With the header, every request goes to v2:

```bash
$ for i in $(seq 1 20); do curl -s -H "x-canary: true" "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
     20 reviews-v2
```

The canary looks healthy, so **promote v2** by moving all weight to it:

```bash
kubectl patch httproute reviews --type=json -p '[
  {"op": "replace", "path": "/spec/rules/1/backendRefs/0/weight", "value": 0},
  {"op": "replace", "path": "/spec/rules/1/backendRefs/1/weight", "value": 100}
]'
for i in $(seq 1 50); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

All 50 requests now go to `reviews-v2`. No pods restarted: Cilium only reprogrammed Envoy.

## Cleanup

Remove the routes, the Gateway, the Cilium objects and Bookinfo:

```bash
kubectl delete -f httproute-reviews-canary.yaml -f reviews-services.yaml -f httproute-bookinfo.yaml -f gateway.yaml
kubectl delete -f l2-announcement-policy.yaml -f lb-ippool.yaml
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
