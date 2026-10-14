### Gateway API ile Uygulama Yayınlama

#### Adım 3 — HTTPRoute ile Yola Göre Yönlendirin

**HTTPRoute** uygulama ekibinin parçasıdır: bir Gateway'e bağlanır ve isteklerin nereye
gideceğini söyler. Senaryo 8'deki Ingress'in yaptığını yapan bir HTTPRoute oluşturun:
`/details` istekleri `details`'e, geri kalan her şey `productpage`'e gider:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: bookinfo
  namespace: default
spec:
  parentRefs:
    - name: my-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /details
      backendRefs:
        - name: details
          port: 9080
    - matches:
        - path:
            type: PathPrefix
            value: /
      backendRefs:
        - name: productpage
          port: 9080
EOF
```

- `parentRefs`, route'u `my-gateway`'e bağlar.
- `backendRefs`, doğrudan Service'leri ve portları gösterir.
- Birden fazla kural eşleştiğinde **en detaylı belirtilen** kazanır; bu yüzden `/` da eşleşse
  `/details/1` isteği `details`'e gider. Kuralların sırası önemli değildir.

Gateway'in route'u kabul ettiğini kontrol edin:

```bash
kubectl get httproute bookinfo -o jsonpath='{.status.parents[0].conditions[?(@.type=="Accepted")].status}{"\n"}'
```

Çıktı `True` olur.

**Uygulamayı kümenin dışından çağırın.** `GATEWAY_IP` boşsa, 2. adımdaki
`GATEWAY_IP=...` komutuyla tekrar ayarlayın.

```bash
echo $GATEWAY_IP
```

`/` isteği `productpage`'e gider ve `200` HTTP kodunu döndürür:

```bash
curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
```

`/details/1` isteği `details` servisine gider ve 1 numaralı kitabın bilgilerini JSON
olarak döndürür:

```bash
curl --fail -s "http://$GATEWAY_IP/details/1"
```

Buraya kadar sonuç Ingress ile aynı. Bir sonraki adım, bir `Ingress`'in
tanımlayamayacağı bir şey yapıyor.
