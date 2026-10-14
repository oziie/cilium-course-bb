### Ağ Politikaları (Layer 7)

#### Adım 4 — İnternet Erişimini Alan Adıyla Sınırlayın

Ön yüzün internette yalnızca tek bir dış servise, `api.github.com`'a ihtiyacı var. Bu
servisin IP'leri sürekli değişir, bu yüzden IP tabanlı bir kural bozulur. `toFQDNs`
kuralı trafiğe **alan adına** göre izin verir:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress-fqdn
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toFQDNs:
        - matchName: api.github.com
      toPorts:
        - ports:
            - port: "443"
              protocol: TCP
EOF
```

Politikada üç egress kuralı vardır:

1. `dns` kuralıyla birlikte `kube-dns`'e **DNS**. Bu kural, podun DNS sorgularını
   Cilium'un **DNS proxy**'si üzerinden geçirir. `matchPattern: "*"` podun her adı
   çözümleyebilmesini sağlar.
2. 8080 portundaki **API**; böylece ön yüz çalışmaya devam eder.
3. 443 portunda **`api.github.com`**. Bu ad için DNS cevabı geldiğinde Cilium IP'leri
   kaydeder ve HTTPS trafiğine yalnızca bu IP'lere izin verir.

`dns` kuralı olmadan Cilium DNS cevaplarını hiç görmez ve `toFQDNs` hiçbir şeyle
eşleşmez.

Test edin:

```bash
# İzin verilir: HTTP/2 200 ve cevap header'ları
kubectl exec -n frontend web -- curl -sI --max-time 5 https://api.github.com
```
```bash
# Zaman aşımı (exit code 28): diğer tüm siteler engellenir
kubectl exec -n frontend web -- curl -sI --max-time 5 https://example.com
```
```bash
# İzin verilir: API hâlâ çalışır
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080/api/products
```

Politikaları listeleyin. Her birinin `VALID` sütunu `True` olmalıdır:

```bash
kubectl get cnp -A
```

Son durum:

| `web` podundan istek | Sonuç |
| --- | --- |
| `GET /api/products`, `POST /api/orders` | izin verilir |
| `GET /admin`, header olmadan `DELETE` | `Access denied` (L7) |
| `X-Team: ops` ile `DELETE` | izin verilir |
| `https://api.github.com` | izin verilir |
| `https://example.com` | zaman aşımı (FQDN) |
| `intruder` podundan herhangi bir istek | zaman aşımı (L3) |
