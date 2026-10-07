# Scenario 3 — Service Connectivity

**Scope:** Expose the nginx application through a Kubernetes `ClusterIP` Service and reach
it from the client pod by name instead of by pod IP. The client and the server still run
on different nodes.

## Prepare the kind cluster (no need for BB)

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, skip this section.

Otherwise, create (or reuse) the cluster with the script in this folder:

```bash
cd scenario-3-service-connectivity
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster, installs Cilium with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) and waits until
all nodes are `Ready`. If Cilium is already installed, it is left as is. Check it with:

```bash
cilium status
```

## Why a Service?

In scenario 2 the client called nginx by its **pod IP**. Pod IPs change every time a pod
is recreated, so clients cannot rely on them. A Service gives the application a stable
virtual IP (the `ClusterIP`) and a DNS name, and load-balances to whichever pods match
its selector.

```
 kind-worker                                kind-worker2
┌──────────────────┐                       ┌──────────────────┐
│ netshoot-client  │── nginx-service:80 ─▶ │ nginx-deployment │
│                  │   (ClusterIP)         │ pod :80          │
└──────────────────┘                       └──────────────────┘
```

## Deploy the Applications

The same nginx Deployment and client pod as in scenario 2: nginx on `kind-worker2`, the
client on `kind-worker`.

```bash
$ kubectl apply -f app-nginx.yaml -f app-netshoot.yaml
```

```bash
$ kubectl get pods -o wide
NAME                                READY   IP              NODE
nginx-deployment-979f5455f-tjd2w    1/1     10.244.2.127    kind-worker2
netshoot-client                     1/1     10.244.1.67     kind-worker
```

## Create the Service

```yaml
# svc-nginx.yaml
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
  type: ClusterIP
```

- `selector` picks the backend pods: every pod labeled `app.kubernetes.io/name: nginx`,
  which is the label of the nginx Deployment's pods.
- `port` is the port clients call on the Service, `targetPort` is the port on the pod.
- `type: ClusterIP` makes the Service reachable from inside the cluster only.

```bash
$ kubectl apply -f svc-nginx.yaml
```

```bash
$ kubectl get service nginx-service
NAME            TYPE        CLUSTER-IP     EXTERNAL-IP   PORT(S)   AGE
nginx-service   ClusterIP   10.96.142.31   <none>        80/TCP    5s
```

Check that the Service found the nginx pod. The endpoint IP is the pod IP from above:

```bash
$ kubectl get endpointslices -l kubernetes.io/service-name=nginx-service
NAME                  ADDRESSTYPE   PORTS   ENDPOINTS      AGE
nginx-service-x7k2p   IPv4          80      10.244.2.127   5s
```

> **Note:** If `ENDPOINTS` is empty, the selector does not match any running pod. Compare
> it with the pod labels using `kubectl get pods --show-labels`.

## Connectivity Tests

### Reach nginx by Service name

```bash
$ kubectl exec pod/netshoot-client -- curl -s http://nginx-service
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
[OUTPUT TRUNCATED]
```

The short name works because both pods are in the same namespace (`default`). From
another namespace, use `nginx-service.default` or the full name
`nginx-service.default.svc.cluster.local`.

### See how the name is resolved

```bash
$ kubectl exec pod/netshoot-client -- nslookup nginx-service
Server:         10.96.0.10
Address:        10.96.0.10#53

Name:   nginx-service.default.svc.cluster.local
Address: 10.96.142.31
```

The DNS answer is the **ClusterIP** of the Service, not the pod IP.

### Reach nginx by ClusterIP

```bash
$ CLUSTER_IP=$(kubectl get service nginx-service -o jsonpath='{.spec.clusterIP}')
$ kubectl exec pod/netshoot-client -- \
curl -s -o /dev/null \
-w "%{http_code}\n" \
http://$CLUSTER_IP
200
```

## The Service Survives a Pod Restart

Delete the nginx pod. The Deployment creates a new one with a **new IP**:

```bash
$ kubectl delete pod -l app.kubernetes.io/name=nginx
$ kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nginx --timeout=60s
$ kubectl get pods -l app.kubernetes.io/name=nginx -o wide
NAME                                READY   IP              NODE
nginx-deployment-979f5455f-8qzlm    1/1     10.244.2.45     kind-worker2
```

The Service name and ClusterIP did not change, so the client keeps working:

```bash
$ kubectl exec pod/netshoot-client -- \
curl -s -o /dev/null \
-w "%{http_code}\n" \
http://nginx-service
200
```

## Cilium's View of the Service

Cilium translates the ClusterIP to a backend pod IP in eBPF. Each agent keeps the
Service table, so you can see the ClusterIP and its backend from the agent on the
client's node:

```bash
$ AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium \
  --field-selector spec.nodeName=kind-worker -o name)
$ kubectl -n kube-system exec "$AGENT" -c cilium-agent -- cilium-dbg service list | grep -E "Frontend|:80/"
ID   Frontend            Service Type   Backend
7    10.96.142.31:80/TCP ClusterIP      1 => 10.244.2.45:80/TCP (active)
```

The frontend is the ClusterIP, and the backend is the current nginx pod IP.

## Cleanup

Remove the test applications and the Service:

```bash
kubectl delete -f svc-nginx.yaml -f app-nginx.yaml -f app-netshoot.yaml
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```

> **Note:** Deleting the cluster removes the Cilium installation with it. The next
> scenario recreates it, Cilium included, with its own `create-kind-cluster.sh`.
