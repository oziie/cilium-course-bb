### eBPF Under the Hood

#### Step 4 — Policies in Maps, and Events from the Kernel

A network policy also ends up as map entries. Allow only pods labelled `app=frontend`
to reach `nginx` on port 80:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
EOF
```

The `client` pod is labelled `app=client`, so it is now blocked. Ingress policy is
enforced on the node of the **destination** pod, so watch for drop **events** on
`kind-worker2` while the client tries again. `timeout 15` stops the monitor after 15
seconds, and `&` runs it in the background so you can use `curl` in the same terminal:

```bash
timeout 15 kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg monitor --type drop &
sleep 3; kubectl exec client -- curl -s --max-time 3 http://nginx; wait
```

You see lines like this one:

```
xx drop (Policy denied) flow 0x0 to endpoint 1342, ifindex 9, file bpf_lxc.c:2112, , identity 21915->8429: 10.244.1.52:41030 -> 10.244.2.15:80 tcp SYN
```

- `Policy denied`: why the packet was dropped.
- `file bpf_lxc.c`: the eBPF program that dropped it, the one in front of the nginx pod.
- `identity 21915->8429`: Cilium does not compare IPs. It compares **security
  identities**, numbers derived from the pods' labels.

The program sent this event to user space through a ring buffer. Hubble (Scenario 6)
reads the same events.

Now look at the nginx pod's **policy map**. Each endpoint has its own:

```bash
NGINX_POD=$(kubectl get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')
EP_ID=$(kubectl get ciliumendpoint $NGINX_POD -o jsonpath='{.status.id}')
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
```

There is no `Ingress` entry for any pod: no pod has the label `app=frontend` yet, so
no identity matches the policy. Give the client that label and check again:

```bash
kubectl label pod client app=frontend --overwrite
sleep 5
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

- The client got a **new identity** for its new labels.
- The policy map now has an `Allow` `Ingress` entry for that identity (labels
  `k8s:app=frontend ...`) on `80/TCP`.
- `curl` prints `200` again.

No program changed and no pod restarted. The agent wrote one new map entry, and the
next packet was allowed. Programs at hooks, data in maps, events to user space: that is
how Cilium uses eBPF for everything you did in this course.
