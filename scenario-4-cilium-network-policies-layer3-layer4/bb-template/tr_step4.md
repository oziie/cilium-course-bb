### Ağ Politikaları (L3/L4)

#### Adım 4 — Ön Yüzün Neleri Çağırabileceğini Kısıtlayın (Egress)

Şimdiye kadarki tüm politikalar **ingress** idi: hedefi korurlar. Bir **egress**
politikası ise bir kaynağın neleri çağırabileceğini sınırlar. `web` podunu yalnızca
8080 portundaki API ile sınırlayın:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
EOF
```

API'yi önce adıyla, sonra Service IP'siyle çağırın:

```bash
kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED

API_IP=$(kubectl get svc api -n backend -o jsonpath='{.spec.clusterIP}')
kubectl exec -n frontend web -- curl -s --max-time 3 http://$API_IP:8080 && echo ALLOWED || echo BLOCKED
```

Adıyla `BLOCKED`, IP ile `ALLOWED` olur. Neden? `web` artık egress için varsayılan olarak
engelle modunda ve `kube-dns`'e giden **DNS sorguları** izin listesinde değil; bu yüzden
`api.backend` adı artık çözümlenemiyor. DNS'i unutmak, egress politikalarındaki en yaygın
hatadır.

Aynı politikayı, `kube-dns`'e DNS (UDP ve TCP 53) trafiğine izin veren ikinci bir kuralla
uygulayarak düzeltin. Politikanın adı aynı olduğu için öncekinin yerini alır:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: web-egress
  namespace: frontend
spec:
  endpointSelector:
    matchLabels:
      app.kubernetes.io/name: web
  egress:
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: backend
            app.kubernetes.io/name: api
      toPorts:
        - ports:
            - port: "8080"
              protocol: TCP
    - toEndpoints:
        - matchLabels:
            k8s:io.kubernetes.pod.namespace: kube-system
            k8s-app: kube-dns
      toPorts:
        - ports:
            - port: "53"
              protocol: UDP
            - port: "53"
              protocol: TCP
EOF

kubectl exec -n frontend web -- curl -s --max-time 3 http://api.backend:8080 && echo ALLOWED || echo BLOCKED
```

Adıyla çağırmak yeniden `ALLOWED` olur.

Tüm politikaları listeleyin. Her birinin `VALID` sütunu `True` olmalıdır:

```bash
kubectl get cnp -A
```

Son durum:

| Yol | Sonuç |
| --- | --- |
| web → api:8080 | ALLOWED |
| web → api:9090 | BLOCKED |
| web → redis:6379 | BLOCKED |
| intruder → api / redis | BLOCKED |
| api → redis:6379 | ALLOWED |
