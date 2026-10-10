### Ingress

#### Step 3 — Assign an External IP with LB-IPAM

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
