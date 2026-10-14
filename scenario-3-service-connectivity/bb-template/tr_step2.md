### Servis Bağlantısı

#### Adım 2 — Uygulamaları Dağıtın ve Service'i Oluşturun

**Neden Service?** Pod IP'leri, pod her yeniden oluşturulduğunda değişir; bu yüzden
istemciler bunlara güvenemez. Service, uygulamaya sabit bir sanal IP (**ClusterIP**) ve
bir DNS adı verir, trafiği de seçicisiyle eşleşen podlara yönlendirir.

nginx'i `kind-worker2` üzerine, istemci podunu `kind-worker` üzerine dağıtın ve nginx'in
önüne `nginx-service` adında bir Service oluşturun:

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

Service tanımında:

- `selector` arka uç podlarını seçer: `app.kubernetes.io/name: nginx` etiketine sahip tüm
  podlar, yani nginx podları.
- `port` istemcilerin Service üzerinde çağırdığı port, `targetPort` ise podun portudur.
- `type: ClusterIP` Service'e yalnızca küme içinden erişilebilmesini sağlar.

Podları bekleyin, ardından Service'i ve podları görüntüleyin:

```bash
kubectl wait --for=condition=Ready pod --all --timeout=120s
```
```bash
kubectl get service nginx-service
```
```bash
kubectl get pods -o wide
```

Service'in nginx podunu bulduğunu kontrol edin:

```bash
kubectl get endpointslices -l kubernetes.io/service-name=nginx-service
```

`ENDPOINTS` sütunu nginx'in **pod IP**'sini gösterir. Boşsa, selector çalışan hiçbir podla
eşleşmiyor demektir.
