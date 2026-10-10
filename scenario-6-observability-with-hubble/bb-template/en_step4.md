### Observability with Hubble

#### Step 4 — Filter Flows, Traffic Leaving the Cluster and a Failed Connection

**Filters.** Without filters, `hubble observe` shows the flows of the whole cluster, which
is noisy. A few filters answer most questions:

```bash
# Who is calling nginx?
hubble observe --to-pod default/nginx-deployment --last 10

# All DNS traffic in the cluster
hubble observe --port 53 --last 10

# Only what happens on one node
hubble observe --node kind-worker2 --last 10
```

`--to-pod default/nginx-deployment` matches every pod whose name **starts with**
`nginx-deployment`, so you don't need the random suffix.

**Traffic leaving the cluster.** Call a site on the internet, then filter on `world`, the
identity Cilium gives to everything outside the cluster:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
hubble observe --pod default/netshoot-client --to-label reserved:world --last 10
```

- The destination is shown as an IP followed by `(world)`.
- `to-stack` means the packet was handed to the node's network stack, which sends it out
  of the cluster.

**A failed connection.** Not every failure is a network problem. Call nginx on port 8081,
where nothing listens:

```bash
kubectl exec pod/netshoot-client -- curl -s -m 3 http://$NGINX_IP:8081
hubble observe --pod default/netshoot-client --port 8081 --last 10
```

`curl` fails with `exit code 7`. In Hubble:

- the `SYN` was `FORWARDED`: the network delivered it to the nginx pod;
- the pod answered with `TCP Flags: ACK, RST`: "nothing is listening on this port".

This is an application or configuration problem, not a network one. A policy drop would
look different: a `DROPPED` verdict and no reply.

> **Note:** If `$NGINX_IP` is empty (for example in a new terminal), set it again with the
> first command of step 3.
