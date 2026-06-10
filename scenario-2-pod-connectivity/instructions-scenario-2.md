**Scope:** Verify internode connectivity between two different applications that are scheduled on different Kubernetes nodes through Cilium's VXLAN-based tunneling.

## Deploy nginx application on `kind-worker2` node

```yaml
# app-nginx.yaml
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
```

```bash
$ kubectl apply -f app-nginx.yaml
```

```bash
$ kubectl get pods -o wide
NAME                                READY   IP              NODE
nginx-deployment-979f5455f-tjd2w    1/1     10.244.2.127    kind-worker2
```

## Deploy a client app on `kind-worker` node

```yaml
# app-netshoot.yaml
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
```

```bash
$ kubectl apply -f app-netshoot.yaml
```

```bash
$ kubectl get pods -o wide
NAME               READY   IP             NODE
netshoot-client    1/1     10.244.1.67    kind-worker
```

## Connectivity Tests

### Verify connectivity from `netshoot-client` to `nginx-server`

```bash
$ kubectl exec pod/netshoot-client -- curl -s http://10.244.2.127
<!DOCTYPE html>
<html>
<head>
<title>Welcome to nginx!</title>
[OUTPUT TRUNCATED]
```

### Verify HTTP connectivity

```bash
$ kubectl exec pod/netshoot-client -- \
curl -s -o /dev/null \
-w "%{http_code}\n" \
http://10.244.2.127
200
```
