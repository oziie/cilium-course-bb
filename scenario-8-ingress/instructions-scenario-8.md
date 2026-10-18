# Scenario 8 — Ingress

**Scope:** Expose the Bookinfo sample application with Cilium's built-in Ingress
controller, give it an external IP with LB-IPAM, make that IP reachable with L2
announcements, and call the application from outside the cluster.

## Step 1 — Create the Cluster and Install Cilium with Ingress

In this scenario you expose the **Bookinfo** sample application with Cilium's built-in
**Ingress controller**, give it an external IP, and call it with `curl` from outside the
cluster. Three Cilium features work together:

| Feature | What it does |
| --- | --- |
| Ingress controller | turns an `Ingress` into Envoy routing rules and a `LoadBalancer` Service |
| LB-IPAM (`CiliumLoadBalancerIPPool`) | gives `LoadBalancer` Services an external IP from a pool you define |
| L2 announcements (`CiliumL2AnnouncementPolicy`) | makes a node answer ARP requests for that IP, so the machine running kind can reach it |

This scenario needs a cluster **without kube-proxy**: Cilium replaces it.
Delete any previous cluster, then create the new one with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-8-ingress
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
ingressController:
  enabled: true
```

- `kubeProxyReplacement: true`: Cilium handles Services with eBPF instead of kube-proxy.
  The Ingress controller and L2 announcements both require it.
- `l2announcements.enabled: true`: lets nodes answer ARP requests for Service IPs.
- `ingressController.enabled: true`: turns on the Cilium Ingress controller and the
  `cilium` IngressClass.

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
ingressController:
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

Without kube-proxy, nothing can route the `kubernetes` Service IP before Cilium runs.
`k8sServiceHost` and `k8sServicePort` tell Cilium to reach the API server directly at
`kind-control-plane:6443`.

Wait until Cilium is ready:

```bash
cilium status --wait
```

Check the settings and the IngressClass:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-ingress-controller'
```
```bash
kubectl get ingressclass
```

All three settings are `true`, and an IngressClass named `cilium` exists.

## Step 2 — Deploy Bookinfo and Create the Ingress

[Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) is a small sample application
from the Istio project: a `productpage` web page that calls the `details`, `reviews` and
`ratings` services. Deploy it:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```
```bash
kubectl wait --for=condition=Ready pod --all --timeout=300s
```
```bash
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

## Step 3 — Assign an External IP with LB-IPAM

LB-IPAM gives `LoadBalancer` Services an IP from a `CiliumLoadBalancerIPPool`. The IP must
be reachable from this machine, so the pool has to be **inside the subnet of the `kind`
Docker network**, where the kind nodes are connected. Check it:

```bash
docker network inspect kind | grep Subnet
```

The IPv4 subnet is usually `172.18.0.0/16`. Create a pool of 8 addresses at the top of
it, far from the IPs Docker gives the nodes (`172.18.0.2`, `172.18.0.3`, ...):

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 172.18.255.200/29
EOF
```

> **Note:** If your IPv4 subnet is different, for example `172.19.0.0/16`, use the same
> range in your subnet (`172.19.255.200/29`) in the command above.

The Service gets an IP from the pool right away:

```bash
kubectl get svc cilium-ingress-basic-ingress
```
```bash
kubectl get ingress basic-ingress
```

The Service's `EXTERNAL-IP` and the Ingress `ADDRESS` show the same IP, for example
`172.18.255.200`. Save it in a variable:

```bash
INGRESS_IP=$(kubectl get ingress basic-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_IP
```

The Service has an IP now, but **no machine claims it on the network yet**. When this
machine sends an ARP request ("who has this IP?"), nobody answers, so `curl` cannot reach
it. The next step fixes that.

## Step 4 — Announce the IP and Call the Application

**Layer 2 announcement** lets nodes advertise Service IPs on the local network with ARP
(IPv4). Machines on the same network, like the one running kind, can then reach those IPs
without a separate load balancer. A `CiliumL2AnnouncementPolicy` selects which nodes and
interfaces announce them.

Make the worker nodes answer ARP requests on their `eth0` interface for the IPs of
`LoadBalancer` Services:

```bash
kubectl apply -f - <<EOF
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

- `loadBalancerIPs: true` announces the external IPs of `LoadBalancer` Services.
- `interfaces` lists the node interfaces to answer on. `eth0` connects kind nodes to the
  Docker network.
- The `nodeSelector` picks every node **without** the control-plane label: the two
  workers.

Only one node answers for a given IP at a time. The nodes elect it with a Kubernetes
`Lease`. See which worker owns the IP:

```bash
kubectl -n kube-system get lease | grep l2announce
```

If that node goes down, another worker takes over the lease and starts answering.

**Call the application from outside the cluster.** If `INGRESS_IP` is empty, set it again with the `INGRESS_IP=...` command of step 3:

```bash
echo $INGRESS_IP
```

`/` goes to `productpage` and returns HTTP code `200`:

```bash
curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_IP/"
```

`/details/1` goes to the `details` service and returns the details of book 1 as JSON:

```bash
curl --fail -s "http://$INGRESS_IP/details/1"
```

The request travelled: this machine → ARP answer from a worker → Cilium's Envoy on that
node → the `details` or `productpage` pod, chosen by the path rules of the Ingress.

```
 this machine  (curl http://$INGRESS_IP/...)
      |
      |  1. ARP: "who has $INGRESS_IP?"
      v
 worker node holding the lease  (answers the ARP request)
      |
      |  2. HTTP request
      v
 Cilium's Envoy on that node
      |
      |  3. path rules of the Ingress
      |
      +-- /details/...           -->  details pod
      |
      +-- /  (everything else)   -->  productpage pod
```

## Cleanup

Remove the Ingress, the Cilium objects and Bookinfo:

```bash
kubectl delete ciliuml2announcementpolicy policy1
kubectl delete ciliumloadbalancerippool pool
kubectl delete ingress basic-ingress
kubectl delete -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```
