# Scenario 8 — Ingress

**Scope:** Expose the Bookinfo sample application with Cilium's built-in Ingress
controller. Give the Ingress an external IP with LB-IPAM, make that IP reachable with an
L2 announcement policy, and call the application with `curl` from outside the cluster.

## How the Pieces Fit Together

| Piece | What it does |
| --- | --- |
| Cilium Ingress controller | turns an `Ingress` with `ingressClassName: cilium` into Envoy routing rules and a `LoadBalancer` Service |
| LB-IPAM (`CiliumLoadBalancerIPPool`) | gives `LoadBalancer` Services an external IP from a pool you define |
| L2 announcements (`CiliumL2AnnouncementPolicy`) | makes a node answer ARP requests for that IP, so hosts on the same network can reach it |

```
curl (Docker host) ──▶ 172.18.255.200 ──ARP──▶ kind-worker (eth0)
                                                    │
                                              Cilium Envoy
                                        /details ──┴── /
                                           ▼           ▼
                                        details    productpage
```

## Prepare the kind cluster (no need for BB)

This scenario needs Cilium features that the previous clusters do not have, and a
cluster **without kube-proxy**. Delete the previous cluster first, then create a new one:

```bash
cd scenario-8-ingress
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
./create-kind-cluster.sh
kubectl config current-context      # should print kind-kind
```

The kind config [`light-lab.yaml`](light-lab.yaml) is the usual 1 control-plane + 2
workers, plus `kubeProxyMode: none`: Cilium replaces kube-proxy in this scenario.

The script installs Cilium with the values in [`cilium-values.yaml`](cilium-values.yaml):

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
ingressController:
  enabled: true
```

- `kubeProxyReplacement: true`: Cilium handles Services in eBPF. The Ingress controller and
  L2 announcements both require it.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs.
- `ingressController.enabled: true`: turns on the Cilium Ingress controller and the
  `cilium` IngressClass.

The script runs the equivalent of:

```bash
helm upgrade --install cilium cilium --repo https://helm.cilium.io/ -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```

> **Note:** Without kube-proxy, nothing translates the `kubernetes` Service IP before Cilium
> is running. `k8sServiceHost` and `k8sServicePort` tell the Cilium agent to reach the API
> server directly instead.

Check the settings and the IngressClass:

```bash
$ cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-ingress-controller'
enable-ingress-controller                         true
enable-l2-announcements                           true
kube-proxy-replacement                            true
$ kubectl get ingressclass
NAME     CONTROLLER                     PARAMETERS   AGE
cilium   cilium.io/ingress-controller   <none>       2m
```

## Deploy the Bookinfo Application

[Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) is a small sample application
from the Istio project: a `productpage` web page that calls the `details`, `reviews` and
`ratings` services.

```bash
$ kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
$ kubectl wait --for=condition=Ready pod --all --timeout=180s
$ kubectl get svc
NAME          TYPE        CLUSTER-IP      EXTERNAL-IP   PORT(S)
details       ClusterIP   10.96.120.33    <none>        9080/TCP
kubernetes    ClusterIP   10.96.0.1       <none>        443/TCP
productpage   ClusterIP   10.96.211.5     <none>        9080/TCP
ratings       ClusterIP   10.96.48.170    <none>        9080/TCP
reviews       ClusterIP   10.96.92.14     <none>        9080/TCP
```

> **Note:** Your IPs and names will differ. The outputs in this scenario are examples,
> so read them for their shape, not their exact values.

## Create the Ingress

[`ingress-basic.yaml`](ingress-basic.yaml) sends `/details` to the `details` service and
everything else (`/`) to `productpage`:

```yaml
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
          - backend:
              service:
                name: details
                port:
                  number: 9080
            path: /details
            pathType: Prefix
          - backend:
              service:
                name: productpage
                port:
                  number: 9080
            path: /
            pathType: Prefix
```

```bash
kubectl apply -f ingress-basic.yaml
```

Cilium creates a `LoadBalancer` Service for the Ingress, but it has no external IP yet:

```bash
$ kubectl get svc cilium-ingress-basic-ingress
NAME                           TYPE           CLUSTER-IP     EXTERNAL-IP   PORT(S)
cilium-ingress-basic-ingress   LoadBalancer   10.96.162.89   <pending>     80:31734/TCP,443:30947/TCP
```

In a cloud, the provider's load balancer would fill in `EXTERNAL-IP`. kind has none, so
Cilium has to assign the IP itself.

## Assign an External IP with LB-IPAM

LB-IPAM assigns IPs to `LoadBalancer` Services from a `CiliumLoadBalancerIPPool`. The IPs
must be reachable from where you run `curl`, so the pool has to sit **inside the subnet
of the `kind` Docker network**. Check it:

```bash
$ docker network inspect kind | grep Subnet
                    "Subnet": "172.18.0.0/16",
                    "Subnet": "fc00:f853:ccd:e793::/64",
```

[`lb-ippool.yaml`](lb-ippool.yaml) uses `172.18.255.200/29`, at the top of `172.18.0.0/16`,
far from the IPs Docker gives the nodes (`172.18.0.2`, `172.18.0.3`, ...):

```yaml
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
  name: "pool"
spec:
  blocks:
    - cidr: "172.18.255.200/29"
```

> **Note:** If your IPv4 subnet is different (for example `172.19.0.0/16`), change the
> `cidr` to the same range in your subnet (`172.19.255.200/29`) before applying.

```bash
$ kubectl apply -f lb-ippool.yaml
$ kubectl get svc cilium-ingress-basic-ingress
NAME                           TYPE           CLUSTER-IP     EXTERNAL-IP      PORT(S)
cilium-ingress-basic-ingress   LoadBalancer   10.96.162.89   172.18.255.200   80:31734/TCP,443:30947/TCP
```

The Ingress shows the same address:

```bash
$ kubectl get ingress
NAME            CLASS    HOSTS   ADDRESS          PORTS   AGE
basic-ingress   cilium   *       172.18.255.200   80      13m
```

Save it in a variable to reuse it:

```bash
INGRESS_IP=$(kubectl get ingress basic-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_IP
```

## Make the IP Reachable with L2 Announcements

The Service has an IP now, but no machine on the network claims it yet. When the Docker
host sends an ARP request for `172.18.255.200`, nobody answers.

**Layer 2 announcement** lets nodes advertise Service IPs on the local network with ARP
(IPv4) or Neighbor Discovery (IPv6). Hosts in the same layer 2 domain can then reach those
IPs without a separate load balancer. A `CiliumL2AnnouncementPolicy` selects which nodes
and interfaces announce them.

[`l2-announcement-policy.yaml`](l2-announcement-policy.yaml) makes Cilium answer ARP
requests on the `eth0` interface of the **worker** nodes for the IPs of `LoadBalancer`
Services:

```yaml
apiVersion: "cilium.io/v2alpha1"
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
```

```bash
kubectl apply -f l2-announcement-policy.yaml
```

Only one node answers for a given IP at a time. The nodes elect it with a Kubernetes
`Lease`, so you can see which worker currently owns the IP:

```bash
$ kubectl -n kube-system get lease | grep l2announce
cilium-l2announce-default-cilium-ingress-basic-ingress   kind-worker   1m
```

If that node goes down, another worker takes over the lease and starts answering.

## Call the Application from Outside the Cluster

Run these on the **Docker host** (the machine where kind runs), not inside a pod.

`/` goes to `productpage`, which returns HTTP 200:

```bash
$ curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_IP/"
200
```

`/details/1` goes to the `details` service and returns the details of book 1:

```bash
$ curl --fail -s "http://$INGRESS_IP/details/1"
{"id":1,"author":"William Shakespeare","year":1595,"type":"paperback","pages":200,"publisher":"PublisherA","language":"English","ISBN-10":"1234567890","ISBN-13":"123-1234567890"}
```

> **Note:** On macOS (Docker Desktop, OrbStack), Docker runs in a VM and the `kind` network
> lives inside it, so `curl` from the Mac cannot reach the IP. Run `curl` inside that VM,
> or from a container attached to the `kind` network:
>
> ```bash
> docker run --rm --network kind curlimages/curl -s "http://$INGRESS_IP/details/1"
> ```

## Cleanup

Remove the Ingress, the Cilium objects and Bookinfo:

```bash
kubectl delete -f l2-announcement-policy.yaml -f lb-ippool.yaml -f ingress-basic.yaml
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
