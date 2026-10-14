### Ingress

#### Step 4 — Announce the IP and Call the Application

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

**Call the application from outside the cluster.** Check whether`INGRESS_IP` is empty with below command. If it's not set, run the last command of step 3 to set.

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
