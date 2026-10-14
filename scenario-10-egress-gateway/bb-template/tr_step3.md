### Egress Gateway ile Sabit Çıkış IP'si

#### Adım 3 — `payments` Trafiğini Egress Gateway Üzerinden Gönderin

Önce gateway düğümünü seçin. `kind-worker2`'ye politikanın seçebileceği bir etiket
verin:

```bash
kubectl label node kind-worker2 egress-gateway=true
```

Şimdi politikayı oluşturun. Politika `payments` pod'unu seçer ve onun kümeden çıkan tüm
trafiğini etiketli düğüm üzerinden gönderir:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-egress
spec:
  selectors:
    - podSelector:
        matchLabels:
          app: payments
          io.kubernetes.pod.namespace: default
  destinationCIDRs:
    - "0.0.0.0/0"
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gateway: "true"
EOF
```
```bash
kubectl get ciliumegressgatewaypolicies
```

- `selectors`: pod'lar etiketle seçilir. Politika küme kapsamlıdır (cluster-scoped), bu
  yüzden namespace de bir etiket olarak verilir (`io.kubernetes.pod.namespace`).
- `destinationCIDRs`: `0.0.0.0/0` her hedef demektir. Küme **içindeki** pod'lara,
  Service'lere ve düğümlere giden trafik hiçbir zaman yönlendirilmez.
- `egressGateway.nodeSelector`: trafiği dışarı çıkaran düğüm. `egressIP` veya
  `interface` verilmezse Cilium, gateway düğümünün ana arayüzünün (kind'da `eth0`)
  IP'sini kullanır. Gerçek kümelerde genellikle `egressIP` ile özel bir adres verilir.

Sunucuyu iki pod'dan tekrar çağırın:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

- `payments` pod'u hâlâ `kind-worker` üzerinde çalışmasına rağmen istekleri artık
  **kind-worker2**'nin IP'sinden gelir. Trafiği tünel ile gateway düğümüne gönderildi
  ve kümeden oradan çıktı.
- `catalog` politika tarafından seçilmediği için hâlâ kind-worker'ın IP'si ile çıkar.

Harici sunucunun güvenlik duvarının, payments uygulaması için artık yalnızca
kind-worker2'nin IP'sine izin vermesi yeterlidir; pod'lar nerede çalışırsa çalışsın.
