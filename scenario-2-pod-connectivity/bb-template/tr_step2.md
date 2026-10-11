### Pod Bağlantısı

#### Adım 2 — Uygulamaları Farklı Düğümlere Dağıtın

İki uygulama dağıtın ve her birini `nodeSelector` ile farklı bir worker düğümüne
sabitleyin:

- **nginx** (web sunucusu) `kind-worker2` üzerinde
- **netshoot-client** (`curl` gibi ağ araçları içeren bir pod) `kind-worker` üzerinde

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

İki pod da çalışana kadar bekleyin, ardından nerede çalıştıklarını görüntüleyin:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -o wide
```

`IP` ve `NODE` sütunlarına bakın: nginx `kind-worker2` üzerinde, netshoot-client ise
`kind-worker` üzerinde çalışır; her birinin kendi pod IP'si vardır (örneğin
`10.244.2.127` ve `10.244.1.67`). IP'ler farklı aralıklardan gelir, çünkü her düğümün
kendi pod adres aralığı vardır.
