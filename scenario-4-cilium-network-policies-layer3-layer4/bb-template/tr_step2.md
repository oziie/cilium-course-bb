### Ağ Politikaları (L3/L4)

#### Adım 2 — Mağazayı Dağıtın ve Tüm Gelen Trafiği Engelleyin

Mağazanın her biri kendi namespace'inde çalışan üç katmanı vardır:

| Namespace | Pod | Görevi |
| --- | --- | --- |
| `frontend` | `web` | mağazanın ön yüzü, API'yi çağırır |
| `backend` | `api` | **8080** portunda genel API, **9090** portunda yönetim sayfası sunan nginx |
| `database` | `redis` | **6379** portundaki veritabanı; yalnızca API kullanmalıdır |
| `default` | `intruder` | her yerde engellenmesi gereken alakasız bir pod |

Namespace'leri ve uygulamaları oluşturun:

```bash
kubectl create namespace frontend
kubectl create namespace backend
kubectl create namespace database

kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata: {name: api-nginx-conf, namespace: backend}
data:
  default.conf: |
    server { listen 8080; location / { return 200 'api: public\n'; } }
    server { listen 9090; location / { return 200 'api: admin\n'; } }
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: api, namespace: backend}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: api}}
  template:
    metadata: {labels: {app.kubernetes.io/name: api}}
    spec:
      containers:
        - name: nginx
          image: nginx:1.27-alpine
          volumeMounts: [{name: conf, mountPath: /etc/nginx/conf.d}]
      volumes: [{name: conf, configMap: {name: api-nginx-conf}}]
---
apiVersion: v1
kind: Service
metadata: {name: api, namespace: backend}
spec:
  selector: {app.kubernetes.io/name: api}
  ports: [{name: http, port: 8080}, {name: admin, port: 9090}]
---
apiVersion: apps/v1
kind: Deployment
metadata: {name: redis, namespace: database}
spec:
  selector: {matchLabels: {app.kubernetes.io/name: redis}}
  template:
    metadata: {labels: {app.kubernetes.io/name: redis}}
    spec:
      containers: [{name: redis, image: "redis:7-alpine"}]
---
apiVersion: v1
kind: Service
metadata: {name: redis, namespace: database}
spec:
  selector: {app.kubernetes.io/name: redis}
  ports: [{port: 6379}]
EOF

kubectl run web -n frontend --image=nicolaka/netshoot -l app.kubernetes.io/name=web -- sleep infinity
kubectl run intruder -n default --image=nicolaka/netshoot -l app.kubernetes.io/name=intruder -- sleep infinity
kubectl wait --for=condition=Ready pod --all -A --timeout=180s
```

**Başlangıç durumu.** Hiçbir politika yokken Cilium tüm trafiğe izin verir. Her test
`ALLOWED` (izin verildi) ya da `BLOCKED` (engellendi) yazdırır. Engellenen bir bağlantı
sessizce düşürülür, bu yüzden komutlar 3 saniye sonra denemeyi bırakır:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
kubectl exec -n default intruder -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

Üçü de `ALLOWED` olur: intruder bile veritabanına erişebiliyor.

**Varsayılan olarak engelle.** `backend` ve `database` içindeki tüm podları seçen bir
politika uygulayın:

```bash
for ns in backend database; do
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: $ns
spec:
  endpointSelector: {}
  ingress:
    - {}
EOF
done
```

- `endpointSelector: {}` **politikanın namespace'indeki tüm podları** seçer.
- Boş kural `- {}` hiçbir şeye izin vermez. Bir pod bir ingress politikası tarafından
  seçildiği anda Cilium onu **varsayılan olarak engelle** moduna alır: yalnızca bir
  kuralın açıkça izin verdiği trafik içeri girebilir.

Yukarıdaki üç testi tekrar çalıştırın: meşru olan `web` → `api:8080` dahil hepsi artık
`BLOCKED` olur. Bunu bir sonraki adımda düzelteceksiniz.
