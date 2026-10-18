# Scenario 2 — Pod Connectivity

**Scope:** Verify internode connectivity between two different applications that are
scheduled on different Kubernetes nodes through Cilium's VXLAN-based tunneling.

## Step 1 — Create the Cluster and Install Cilium

In this scenario you check that two pods running on **different nodes** can talk to each
other through Cilium's VXLAN tunnel. First, build the lab cluster: 1 control-plane and 2
worker nodes, with Cilium as the network plugin (CNI). `routingMode=tunnel` and
`tunnelProtocol=vxlan` carry traffic between nodes inside a VXLAN tunnel, which is what
this scenario tests.

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, the cluster is
already there. Otherwise, create (or reuse) it with the
[`create-kind-cluster.sh`](create-kind-cluster.sh) script in this folder:

```bash
cd scenario-2-pod-connectivity
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

All three nodes must be `Ready`: `kind-control-plane`, `kind-worker` and `kind-worker2`.

## Step 2 — Deploy the Applications on Different Nodes

Deploy two applications and pin each one to a different worker node with a
`nodeSelector`:

- **nginx**, a web server, on `kind-worker2`
- **netshoot-client**, a pod with network tools such as `curl`, on `kind-worker`

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
  labels:
    app.kubernetes.io/name: netshoot-client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
EOF
```

Wait until both pods are running, then show where they run:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
```
```bash
kubectl get pods -o wide
```

Look at the `IP` and `NODE` columns: nginx runs on `kind-worker2` and the netshoot-client on
`kind-worker`, each with its own pod IP (for example `10.244.2.127` and `10.244.1.67`).
The IPs come from different ranges because each node has its own pod address range.

## Step 3 — Test Pod-to-Pod Connectivity

Save the IP of the nginx pod in a variable:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
echo $NGINX_IP
```

From the client pod on `kind-worker`, request the nginx page on `kind-worker2`:

```bash
kubectl exec pod/netshoot-client -- curl -s http://$NGINX_IP
```

You get the HTML of the **Welcome to nginx!** page.

Now print only the HTTP status code:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
```

The answer is `200`: the request succeeded.

The two pods run on different nodes, so the request left `kind-worker`, travelled inside
the **VXLAN tunnel** that Cilium set up between the nodes, and was delivered to the nginx
pod on `kind-worker2`. You did not configure any route: Cilium handles pod-to-pod
connectivity across nodes on its own.

## Cleanup

Remove the test applications:

```bash
kubectl delete deployment nginx-deployment
kubectl delete pod netshoot-client
```

If you are done with the lab, delete the cluster too (no need for BB):

```bash
./create-kind-cluster.sh --delete   # or: kind delete cluster --name kind
```

> **Note:** Deleting the cluster removes the Cilium installation with it. The next
> scenario recreates it, Cilium included, with its own `create-kind-cluster.sh`.
