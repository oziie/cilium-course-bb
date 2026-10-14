### Ağ Politikaları (Layer 7)

#### Adım 2 — API'yi Dağıtın ve Tüm Gelen Trafiği Engelleyin

`backend` namespace'indeki `api`, **aynı 8080 portunda** birkaç yol sunar:

| İstek | Cevap |
| --- | --- |
| `GET /api/products` | ürün listesi |
| `GET`, `POST`, `DELETE /api/orders...` | sipariş servisi |
| `GET /admin` | dahili yönetim sayfası |

Bir L3/L4 kuralı (IP ve port) bu yolları birbirinden ayıramaz. Bir L7 kuralı ayırabilir.

API'yi iki istemci podu çağırır: `frontend` içindeki `web` (mağazanın ön yüzü) ve
`default` içindeki `intruder` (her yerde engellenmelidir).

```bash
kubectl create namespace frontend
```
```bash
kubectl create namespace backend
```
```bash
kubectl apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata: {name: api-nginx-conf, namespace: backend}
data:
  default.conf: |
    server {
      listen 8080;
      default_type application/json;
      location /api/products { return 200 '{"products":["socks","mug","sticker"]}\n'; }
      location /api/orders   { return 200 '{"service":"orders","method":"$request_method"}\n'; }
      location /admin        { return 200 '{"admin":"internal settings"}\n'; }
    }
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
  ports: [{port: 8080}]
EOF
```
```bash
kubectl run web -n frontend --image=nicolaka/netshoot -l app.kubernetes.io/name=web -- sleep infinity
```
```bash
kubectl run intruder -n default --image=nicolaka/netshoot -l app.kubernetes.io/name=intruder -- sleep infinity
```
```bash
kubectl wait --for=condition=Ready pod --all -A --timeout=180s
```

**Başlangıç durumu.** Hiçbir politika yokken her şeye izin verilir. Sipariş silmek ve
yönetim sayfasını okumak bile çalışır:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin
```

İkisi de API'den JSON döndürür.

**Varsayılan olarak engelle.** L3/L4 senaryosundaki gibi `backend` içine gelen tüm
trafiği engelleyin:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: default-deny-ingress
  namespace: backend
spec:
  endpointSelector: {}
  ingress:
    - {}
EOF
```
```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```

Son komut `command terminated with exit code 28` ile biter: bu bir **zaman aşımıdır**.
Paketler L3/L4 seviyesinde düşürüldü; henüz hiçbir şey API'ye ulaşmıyor.
