### Ağ Politikaları (Layer 7)

#### Adım 3 — Yalnızca Belirli HTTP Çağrılarına İzin Verin

`web` podunun API'yi 8080 portundan çağırmasına izin verin, ancak yalnızca şu isteklerle:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-web-to-api-http
  namespace: backend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: api
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: frontend
            app.kubernetes.io/name: web
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
          rules:
            http:
              - method: GET
                path: "/api/products"
              - method: POST
                path: "/api/orders"
              - method: DELETE
                path: "/api/orders/[0-9]+"
                headers:
                  - "X-Team: ops"
EOF
```

- L3/L4 kısmı (`fromEndpoints` + `ports`) L3/L4 senaryosundaki gibi çalışır.
- `rules.http` yenidir: her satır izin verilen bir isteği tanımlar. Bir istek **en az
  bir** satırla eşleşmelidir; aksi halde Envoy isteği reddeder.
- `method` ve `path` değerin tamamıyla eşleşen **düzenli ifadelerdir** (regex).
  `/api/orders/[0-9]+`, `/api/orders/42` ile eşleşir.
- `DELETE` kuralı ayrıca `X-Team: ops` header'ını gerektirir. Bir kural, ancak **tüm**
  alanları eşleştiğinde geçerli olur.

**Sonuçları nasıl okumalı?** L7 kuralları ile Envoy her isteği okur:

| Gördüğünüz | Anlamı |
| --- | --- |
| API'den gelen JSON | izin verildi |
| `Access denied` | bir **L7** kuralı reddetti: Envoy `403` döndü, nginx isteği hiç görmedi |
| `exit code 28` (zaman aşımı) | **L3/L4** seviyesinde düşürüldü |

Test edin:

```bash
# İzin verilir: GET /api/products
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products

# İzin verilir: POST /api/orders
kubectl exec -n frontend web -- curl -s --max-time 3 -X POST http://api.backend:8080/api/orders

# Access denied: /admin yolu kurallarda yok
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/admin

# Access denied: header olmadan DELETE
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE http://api.backend:8080/api/orders/42

# İzin verilir: header ile DELETE
kubectl exec -n frontend web -- curl -s --max-time 3 -X DELETE -H 'X-Team: ops' http://api.backend:8080/api/orders/42

# Zaman aşımı (exit code 28): intruder, Envoy'a ulaşmadan L3 kontrolüne takılır
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080/api/products
```

> **Not:** Header bir kimlik doğrulama yöntemi değildir: L3'te izin verilen her istemci
> bu header'ı ekleyebilir. Burada bir L7 kuralının ne kadar ayrıntılı olabileceğini
> gösterir.
