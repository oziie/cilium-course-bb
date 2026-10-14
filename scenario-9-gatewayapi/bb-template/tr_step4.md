### Gateway API ile Uygulama Yayınlama

#### Adım 4 — Ağırlık ve Header ile Canary Yayını

Bookinfo, `reviews` servisinin üç sürümünü (`v1`, `v2`, `v3`) tek bir `reviews`
Service'inin arkasında çalıştırır. Bu adım yalnızca `v1` (mevcut sürüm) ve `v2` (canary)
sürümlerini kullanır, bu yüzden yalnızca bu ikisi için Service oluşturur. `v3` podları
çalışmaya devam eder, ancak aşağıdaki route onlara hiç trafik göndermez.

Her sürüme trafiğin belirli bir payını göndermek için her sürüme, podların `version`
etiketiyle seçilen kendi Service'ini verin:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Service
metadata:
  name: reviews-v1
spec:
  selector:
    app: reviews
    version: v1
  ports:
    - name: http
      port: 9080
---
apiVersion: v1
kind: Service
metadata:
  name: reviews-v2
spec:
  selector:
    app: reviews
    version: v2
  ports:
    - name: http
      port: 9080
EOF
```

Şimdi aynı Gateway'e, başka bir ekibin yazacağı gibi **ikinci** bir HTTPRoute ekleyin.
Bu route, `/reviews` trafiğinin %90'ını v1'e, %10'unu yeni v2'ye gönderir;
`x-canary: true` header'ını gönderen test kullanıcılarını ise her zaman v2'ye yollar:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: reviews
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /reviews
          headers:
            - name: x-canary
              value: "true"
      backendRefs:
        - name: reviews-v2
          port: 9080
    - matches:
        - path:
            type: PathPrefix
            value: /reviews
      backendRefs:
        - name: reviews-v1
          port: 9080
          weight: 90
        - name: reviews-v2
          port: 9080
          weight: 10
EOF
```

- `weight`, trafiği backend'ler arasında orantılı olarak böler: 90 + 10 = 100, yani %90
  ve %10.
- İki kural da `/reviews` ile eşleşir, ancak ilki bir header ile de eşleştiği için daha
  özeldir ve `x-canary: true` içeren isteklerde kazanır.

Her reviews cevabı, isteği karşılayan podun adını içerir. 100 istek gönderin ve
sürümleri sayın:

```bash
for i in $(seq 1 100); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

Yaklaşık 90 istek `reviews-v1`'e, 10 istek `reviews-v2`'ye gider. Dağılım her istekte
rastgeledir, bu yüzden sayılarınız biraz farklı olabilir. Header ile her istek v2'ye
gider:

```bash
for i in $(seq 1 20); do curl -s -H "x-canary: true" "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

Canary sağlıklı görünüyor; tüm ağırlığı ona vererek **v2'yi yükseltin**, sonra tekrar
sayın:

```bash
kubectl patch httproute reviews --type=json -p '[
  {"op": "replace", "path": "/spec/rules/1/backendRefs/0/weight", "value": 0},
  {"op": "replace", "path": "/spec/rules/1/backendRefs/1/weight", "value": 100}
]'
```
```bash
for i in $(seq 1 50); do curl -s "http://$GATEWAY_IP/reviews/0" | grep -o 'reviews-v[0-9]'; done | sort | uniq -c
```

50 isteğin hepsi artık `reviews-v2`'ye gider. Hiçbir pod yeniden başlamadı: Cilium
yalnızca Envoy proxy'sini yeniden programladı. İki ekibin route'ları tek bir Gateway'i
ve tek bir IP'yi paylaşıyor; trafik bölme ise controller'a özel annotation'larda değil,
standart API'de duruyor.
