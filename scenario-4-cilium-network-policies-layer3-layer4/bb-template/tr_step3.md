### Ağ Politikaları (L3/L4)

#### Adım 3 — Yalnızca Mağazanın İhtiyaç Duyduğu Trafiğe İzin Verin

**Frontend'in API'yi yalnızca 8080 portundan çağırmasına izin verin:**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-web-to-api
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
EOF
```

- `endpointSelector` **hedefi** seçer: `backend` içindeki `api` podları.
- `fromEndpoints` **kaynağı** seçer. Namespace etiketi olmadan yalnızca politikanın kendi
  namespace'indeki (`backend`) podlarla eşleşirdi.
  `k8s:io.kubernetes.pod.namespace: frontend` etiketi, `frontend` içindeki `web` podunu
  seçer.
- `toPorts` **yalnızca TCP 8080**'i açar. Aynı poddaki 9090 yönetim portu kapalı kalır.

Test edin:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:9090 && echo ALLOWED || echo BLOCKED
kubectl exec -n default intruder -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```

Beklenen: 8080 portu için `ALLOWED`, 9090 yönetim portu için `BLOCKED`, intruder için de
`BLOCKED` (namespace ve etiketleri yanlış).

Politikalar **toplanır**: `default-deny-ingress` ve `allow-web-to-api` ikisi de `api`
podunu seçer; izin verilen trafik, kurallarının birleşimidir.

**API'nin Redis'e yalnızca 6379 portundan erişmesine izin verin:**

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-api-to-redis
  namespace: database
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: redis
  ingress:
    - fromEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "6379"
              protocol: TCP
EOF
```

Test edin. API, Redis'e bir `PING` gönderir; ön yüz ise Redis'e doğrudan erişmeyi dener:

```bash
kubectl exec -n backend deploy/api -- sh -c "printf 'PING\r\n' | nc -w 3 redis.database 6379"
kubectl exec -n frontend web -- nc -z -w 3 redis.database 6379 && echo ALLOWED || echo BLOCKED
```

Beklenen: API, Redis'ten `+PONG` cevabını alır; ön yüz ise `BLOCKED` olur: API üzerinden
geçmek zorundadır.
