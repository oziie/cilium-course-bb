### Gateway API

#### Step 2 — Deploy Bookinfo and Create the Gateway

Deploy [Bookinfo](https://istio.io/latest/docs/examples/bookinfo/), the same sample
application as in Scenario 8:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
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
