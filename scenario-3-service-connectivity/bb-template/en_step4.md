### Service Connectivity

#### Step 4 — The Service Survives a Pod Restart

Note the current IP of the nginx pod, then delete the pod. The Deployment immediately
creates a new one:

```bash
kubectl get pods -l app.kubernetes.io/name=nginx -o wide
```
```bash
kubectl delete pod -l app.kubernetes.io/name=nginx
```
```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nginx --timeout=60s
```
```bash
kubectl get pods -l app.kubernetes.io/name=nginx -o wide
```

The new pod has a **different IP**. Call the Service again:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx-service
```

Still `200`: the Service name and ClusterIP did not change, and the Service now forwards
to the new pod. This is why clients should use Services, not pod IPs.

**Cilium's view of the Service.** Cilium translates the ClusterIP to a pod IP with eBPF,
directly on the client's node. Every Cilium agent keeps a table of Services. Show it on
the agent of `kind-worker`, where the client runs:

```bash
AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $AGENT -c cilium-agent -- cilium-dbg service list
```

Find the line with the ClusterIP of `nginx-service` on port 80 (`Frontend`). Its
`Backend` is the **new** nginx pod IP. Cilium updated the table as soon as the pod
changed.
