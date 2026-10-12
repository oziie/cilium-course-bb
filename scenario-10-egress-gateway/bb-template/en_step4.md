### Egress Gateway

#### Step 4 — Under the Hood, and What Happens When the Gateway Is Gone

The Cilium agents turn the policy into entries in an eBPF map. Look at the map on
`kind-worker`, where the `payments` pod runs:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf egress list
```

There is one entry: the `Source IP` is the `payments` pod IP, the `Destination CIDR` is
`0.0.0.0/0`, and the `Gateway IP` is kind-worker2's IP. Every packet from that pod to a
matching destination is forwarded to the gateway. `Egress IP` is only filled in on the
gateway node itself, where the packet is actually masqueraded. Each selected pod gets
its own entry, so if you scale an app to more pods, the map grows with it.

Now remove the label, so **no node** matches the policy any more:

```bash
kubectl label node kind-worker2 egress-gateway-
kubectl exec payments -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
kubectl exec catalog -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
```

`payments` gets no answer (the request times out), while `catalog` still works. Cilium
**drops** the selected traffic instead of letting it leave with the wrong IP. The
external firewall would reject that IP anyway, and failing closed makes the problem easy
to see.

Put the label back, and `payments` leaves through `kind-worker2` again:

```bash
kubectl label node kind-worker2 egress-gateway=true
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

You gave one application a fixed, predictable source IP without changing the app, the
pod or its node. Only a label and a policy decided which node the traffic leaves from.
