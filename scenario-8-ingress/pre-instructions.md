- Deploy a kind cluster using the kind.yaml config, then install Cilium with the following Helm values:

```bash
kubeProxyReplacement: true
l2announcements:
enabled: true
ipam:
mode: kubernetes
ingressController:
enabled: true
```

- Use [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/) application as example.

- Create basic ingress:

```bash
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


- This creates a LoadBalancer service for the Ingress, but it won’t have an external IP
yet:

```bash
$ kubectl get svc
NAME TYPE CLUSTER-IP EXTERNAL-IP
cilium-ingress-basic-ingress LoadBalancer 10.96.162.89 <pending>
```

- For an IP to be assigned we need to create a CiliumLoadBalancerIPPool object:

```bash
apiVersion: "cilium.io/v2"
kind: CiliumLoadBalancerIPPool
metadata:
name: "pool"
spec:
blocks:
- cidr: "172.18.255.200/29"
```



- Deploy the pool with kubectl and verify that an IP address has been assigned to the
service:


```bash
$ kubectl get svc
NAME TYPE CLUSTER-IP EXTERNAL-IP
cilium-ingress-basic-ingress LoadBalancer 10.96.68.41 172.18.255.201
```

- You can also verify that the same external IP address is associated with the Ingress
resource:

```bash
$ kubectl get ingress
NAME CLASS HOSTS ADDRESS PORTS AGE
basic-ingress cilium * 172.18.255.200 80 13m
```

Export it as a variable (INGRESS_IP=172.18.255.200, for example) so that you can
reuse it.

- Let’s now make this IP address accessible locally by deploying the following Cilium layer 2 announcement policy:

```bash
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


- NOTE: Layer 2 announcement lets nodes advertise service IPs on the local network using the Address Resolution Protocol (ARP) for IPv4 or Neighbor Discovery (ND) for IPv6 so external hosts can reach those IPs without a separate load balancer if they share a layer 2 domain. In Cilium, you enable this with a CiliumL2AnnouncementPolicy that selects which nodes and interfaces announce their IPs. Essentially the policy shown here will ensure Cilium answers ARP requests received on the worker node’s eth0 interfaces for IPs assigned to LoadBalancer services (in this case, 172.18.255.200).


- From outside the cluster, let’s send an HTTP request to the / path with curl. It takes us to the productpage service and returns HTTP code 200:

```bash
$ curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_IP/"
200
```

- A cURL request to the /details/1 path takes us to the book’s details:

```bash
$ curl --fail -s "http://$INGRESS_IP/details/1"
```

