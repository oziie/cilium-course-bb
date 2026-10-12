### Egress Gateway

#### Step 2 — Start an External Server and See the Default Source IP

You need something **outside** the cluster that shows which IP a request comes from.
`traefik/whoami` is a tiny web server that answers every request with details about it,
including `RemoteAddr`: the caller's IP and port.

Run it as a plain Docker container on the `kind` network. It sits next to the kind
nodes but is not part of the cluster, just like a partner's server on your network:

```bash
docker run -d --name external-server --network kind traefik/whoami
EXTERNAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' external-server)
echo $EXTERNAL_IP
```

Note the `INTERNAL-IP` of every node, so you can recognise them in the server's answers:

```bash
kubectl get nodes -o wide
```

Usually `kind-control-plane` is `172.18.0.2`, `kind-worker` is `172.18.0.3` and
`kind-worker2` is `172.18.0.4`, but the order can differ. Use your own values below.

Create two client pods, `payments` and `catalog`, both on `kind-worker`:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: payments
  labels:
    app: payments
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  labels:
    app: catalog
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
EOF
kubectl wait --for=condition=Ready pod/payments pod/catalog --timeout=120s
kubectl get pods -o wide
```

Call the external server from both pods:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

Both requests come from the IP of **kind-worker**, not from the pod IPs (`10.244.x.x`
in `kubectl get pods -o wide`). Cilium masqueraded the traffic on the node where the
pods run. If `payments` were rescheduled to `kind-worker2`, the server would suddenly
see a different IP.
