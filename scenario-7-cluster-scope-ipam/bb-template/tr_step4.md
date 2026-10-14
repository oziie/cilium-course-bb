### Cluster Scope IPAM (Cluster Kapsamlı IP Yönetimi)

#### Adım 4 — Bir Düğümün Adreslerini Tüketin

Tamamı `kind-worker2` üzerine sabitlenmiş **10** nginx podundan oluşan bir Deployment
oluşturun:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  replicas: 10
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
EOF
```

Yaklaşık 30 saniye bekleyin, ardından podları listeleyin:

```bash
kubectl get pods -o wide -l app.kubernetes.io/name=nginx
```

En fazla **4** pod `Running` durumundadır (`coredns` zaten `kind-worker2` üzerinde adres
kullanıyorsa daha az). Diğerleri IP almadan `ContainerCreating` durumunda kalır: düğümün
onlara verecek adresi kalmamıştır.

Bunu `kind-worker2` üzerindeki Cilium agent ile doğrulayın:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker2 -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status | grep IPAM
```

Çıktı `IPv4: 6/6 allocated` gösterir: tüm adresler kullanımda. Takılan podların event'leri
de aynı şeyi anlatır. Cilium'un atayacak IP'si kalmadığı için Kubernetes podun ağını
oluşturamadı:

```bash
STUCK_POD=$(kubectl get pods -l app.kubernetes.io/name=nginx --field-selector status.phase=Pending -o name | head -n 1)
kubectl describe $STUCK_POD | grep -m 1 "range is full"
```

**Cluster Scope'un sınırları.** Kubernetes Host Scope'tan daha esnektir, ancak:

- **Adres alanı sabittir.** Küme çalışırken havuz ekleyemez veya havuzları
  büyütemezsiniz; bu yüzden buradaki gibi bir adres tükenmesi, kümeyi yeniden kurmadan
  düzeltilemez.
- **Pod IP'leri üzerinde sınırlı kontrol.** İş yükü veya namespace ne olursa olsun, tüm
  podlar aynı ortak havuzlardan adres alır.

Multi-Pool IPAM modu bu kısıtlamaları ortadan kaldırır.
