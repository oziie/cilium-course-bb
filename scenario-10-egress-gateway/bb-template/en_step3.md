### Egress Gateway

#### Step 3 — Send `payments` Through an Egress Gateway

First pick the gateway node. Give `kind-worker2` a label that the policy can select:

```bash
kubectl label node kind-worker2 egress-gateway=true
```

Now create the policy. It selects the `payments` pod and sends all of its traffic that
leaves the cluster through the labelled node:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-egress
spec:
  selectors:
    - podSelector:
        matchLabels:
          app: payments
          io.kubernetes.pod.namespace: default
  destinationCIDRs:
    - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
EOF
```
```bash
kubectl get ciliumegressgatewaypolicies
```

- `selectors`: pods are chosen by label. The policy is cluster-scoped, so the namespace
  is also given as a label (`io.kubernetes.pod.namespace`).
- `destinationCIDRs`: `0.0.0.0/0` means every destination. Traffic to pods, Services
  and nodes **inside** the cluster is never redirected.
- `egressGateway.nodeSelector`: the node that sends the traffic out. Without `egressIP`
  or `interface`, Cilium uses the IP of the gateway node's main interface (`eth0` in
  kind). On real clusters you usually set `egressIP` to a dedicated address.

Call the server again from both pods:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

- `payments` now comes from the IP of **kind-worker2**, although the pod still runs on
  `kind-worker`. Its traffic was tunnelled to the gateway node and left the cluster there.
- `catalog` is not selected by the policy, so it still leaves with kind-worker's IP.

The external server's firewall now only needs to allow kind-worker2's IP for the
payments app, wherever its pods run.
