# Scenario 3 — Service Connectivity

**Scope:** Expose the nginx application through a Kubernetes `ClusterIP` Service and reach
it from the client pod by name instead of by pod IP. The client and the server still run
on different nodes.

## Step 1 — Create the Cluster and Install Cilium

In this scenario you put a Kubernetes **Service** in front of an nginx application and
reach it from a client pod **by name** instead of by pod IP. First, build the lab
cluster: 1 control-plane and 2 worker nodes, with Cilium as the network plugin (CNI).

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, the cluster is
already there. Otherwise, create (or reuse) it with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-3-service-connectivity
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster from [`light-lab.yaml`](light-lab.yaml), installs Cilium
with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) and waits until
all nodes are `Ready`. If Cilium is already installed, it is left as is.

<details>
<summary>Manual alternative (the commands used on BB)</summary>

Write the kind configuration file and create the cluster. `disableDefaultCNI: true` turns
off kind's default network plugin so that Cilium can manage pod networking:

```bash
cat > light-lab.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
EOF
```
```bash
kind create cluster --config light-lab.yaml
```

Install Cilium with Helm:

```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

</details>

Wait until Cilium is ready, then check the nodes:

```bash
cilium status --wait
```
```bash
kubectl get nodes
```

All three nodes must be `Ready`.

## Step 2 — Deploy the Applications and Create the Service

**Why a Service?** Pod IPs change every time a pod is recreated, so clients cannot rely
on them. A Service gives the application a stable virtual IP (the **ClusterIP**) and a
DNS name, and forwards traffic to the pods that match its selector.

Deploy nginx on `kind-worker2`, the client pod on `kind-worker`, and a Service named
`nginx-service` in front of nginx:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 1
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      nodeSelector:
        kubernetes.io/hostname: kind-worker2
      containers:
        - name: nginx
          image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  type: ClusterIP
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
EOF
```

In the Service:

- `selector` picks the backend pods: every pod with the label
  `app.kubernetes.io/name: nginx`, which is the label of the nginx pods.
- `port` is the port clients call on the Service, `targetPort` is the port on the pod.
- `type: ClusterIP` makes the Service reachable from inside the cluster only.

Wait for the pods, then look at the Service and the pods:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
```
```bash
kubectl get service nginx-service
```
```bash
kubectl get pods -o wide
```

Check that the Service found the nginx pod:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=nginx-service
```

The `ENDPOINTS` column shows the **pod IP** of nginx. If it is empty, the selector does
not match any running pod.

## Step 3 — Reach nginx Through the Service

Call nginx from the client pod using the **Service name**:

```bash
kubectl exec pod/netshoot-client -- curl -s http://nginx-service
```

You get the **Welcome to nginx!** page. The short name works because both pods are in
the same namespace (`default`). From another namespace you would use
`nginx-service.default`.

See how the name is resolved:

```bash
kubectl exec pod/netshoot-client -- nslookup nginx-service
```

The answer is the **ClusterIP** of the Service, not the pod IP. The cluster DNS (CoreDNS)
always returns this stable address.

Now call the ClusterIP directly and print only the HTTP status code:

```bash
CLUSTER_IP=$(kubectl get service nginx-service -o jsonpath='{.spec.clusterIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$CLUSTER_IP
```

The answer is `200`. The client talks to the ClusterIP, and the request still reaches the
nginx pod on the other node.

## Step 4 — The Service Survives a Pod Restart

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

## Cleanup

Remove the test applications and the Service:

```bash
kubectl delete service nginx-service
kubectl delete deployment nginx-deployment
kubectl delete pod netshoot-client
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```

> **Note:** Deleting the cluster removes the Cilium installation with it. The next
> scenario recreates it, Cilium included, with its own `create-kind-cluster.sh`.
