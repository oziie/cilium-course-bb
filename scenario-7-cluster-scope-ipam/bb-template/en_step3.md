### Cluster Scope IPAM

#### Step 3 — Deploy a Sample Pod and Check the Node's Addresses

Deploy a pod on `kind-worker`:

```bash
kubectl run netshoot-client --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"kind-worker"}}}' \
  -- sleep infinity
kubectl wait --for=condition=Ready pod/netshoot-client --timeout=120s
kubectl get pod netshoot-client -o wide
```

The pod IP comes from the `/29` of `kind-worker` that you saw in step 2.

Now look at the IPAM section of `cilium-dbg status` on the Cilium agent of that node:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status --verbose | grep -A 6 '^IPAM'
```

Example output:

```
IPAM:                    IPv4: 3/6 allocated from 10.0.42.0/29,
Allocated addresses:
  10.0.42.1 (router)
  10.0.42.4 (health)
  10.0.42.5 (default/netshoot-client)
```

`3/6` means 3 of the 6 allocatable addresses are in use: the router (`cilium_host`), the
health endpoint and your pod. If `coredns` pods run on this node, they are listed too.
