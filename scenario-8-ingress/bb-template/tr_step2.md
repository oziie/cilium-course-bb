### Ingress ile Uygulama Yayınlama

#### Adım 2 — Bookinfo'yu Dağıtın ve Ingress'i Oluşturun

[Bookinfo](https://istio.io/latest/docs/examples/bookinfo/), Istio projesine ait küçük
bir örnek uygulamadır: `details`, `reviews` ve `ratings` servislerini çağıran bir
`productpage` web sayfası. Uygulamayı dağıtın:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl wait --for=condition=Ready pod --all --timeout=300s
kubectl get svc
```

Tüm Bookinfo servisleri `ClusterIP` türündedir; yalnızca küme içinden erişilebilirler.

`/details` isteklerini `details` servisine, geri kalan her şeyi (`/`) `productpage`'e
gönderen bir Ingress oluşturun:

```bash
kubectl apply -f - <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: basic-ingress
  namespace: default
spec:
  ingressClassName: cilium
  rules:
    - http:
        paths:
          - path: /details
            pathType: Prefix
            backend:
              service:
                name: details
                port:
                  number: 9080
          - path: /
            pathType: Prefix
            backend:
              service:
                name: productpage
                port:
                  number: 9080
EOF
```

- `ingressClassName: cilium` bu Ingress'i Cilium Ingress controller'a verir.
- `pathType: Prefix` yolu ve altındaki her şeyi eşleştirir: `/details`, `/details/1` ile
  de eşleşir.

Cilium, Ingress için bir `LoadBalancer` Service'i oluşturur:

```bash
kubectl get svc cilium-ingress-basic-ingress
```

`EXTERNAL-IP` değeri `<pending>` durumundadır. Bir bulut ortamında bunu sağlayıcının
load balancer'ı doldururdu. kind'da böyle bir şey yok; bu yüzden bir sonraki adımda
Cilium'a kullanacağı bir IP havuzu vereceksiniz.
