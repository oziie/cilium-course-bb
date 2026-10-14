### Ingress ile Uygulama Yayınlama

#### Adım 4 — IP'yi Duyurun ve Uygulamayı Çağırın

**Layer 2 duyurusu** (L2 announcement), düğümlerin Service IP'lerini yerel ağda ARP
(IPv4) ile duyurmasını sağlar. Böylece aynı ağdaki makineler, örneğin kind'ı çalıştıran
makine, ayrı bir load balancer olmadan bu IP'lere ulaşabilir. Hangi düğümlerin ve
arayüzlerin bu IP'leri duyuracağını bir `CiliumL2AnnouncementPolicy` belirler.

Worker düğümlerinin, `LoadBalancer` Service IP'leri için `eth0` arayüzüne gelen ARP
isteklerine cevap vermesini sağlayın:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  loadBalancerIPs: true
  interfaces:
    - eth0
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
EOF
```

- `loadBalancerIPs: true`, `LoadBalancer` Service'lerinin harici IP'lerini duyurur.
- `interfaces`, cevap verilecek düğüm arayüzlerini listeler. `eth0`, kind düğümlerini
  Docker ağına bağlar.
- `nodeSelector`, control-plane etiketi **olmayan** tüm düğümleri seçer: iki worker
  düğümü.

Belirli bir IP için aynı anda yalnızca bir düğüm cevap verir. Düğümler bunu bir
Kubernetes `Lease` nesnesiyle seçer. IP'nin hangi worker'da olduğuna bakın:

```bash
kubectl -n kube-system get lease | grep l2announce
```

O düğüm çökerse, başka bir worker lease'i devralır ve cevap vermeye başlar.

**Uygulamayı kümenin dışından çağırın.** `INGRESS_IP` değişkeni dolu mu kontrol edin. Eğer boşsa, 3.adımdaki son komutuyla tekrar ayarlayın.

```bash
echo $INGRESS_IP
```

`/` isteği `productpage`'e gider ve `200` HTTP kodunu döndürür:

```bash
curl --fail -s -o /dev/null -w "%{http_code}\n" "http://$INGRESS_IP/"
```

`/details/1` isteği `details` servisine gider ve 1 numaralı kitabın bilgilerini JSON
olarak döndürür:

```bash
curl --fail -s "http://$INGRESS_IP/details/1"
```

İsteğin yolu: bu makine → bir worker'dan gelen ARP cevabı → o düğümdeki Cilium Envoy →
Ingress'in yol kurallarına göre seçilen `details` veya `productpage` podu.

```
 bu makine  (curl http://$INGRESS_IP/...)
      |
      |  1. ARP: "$INGRESS_IP kimde?"
      v
 lease sahibi worker düğüm  (ARP isteğine cevap verir)
      |
      |  2. HTTP isteği
      v
 o düğümdeki Cilium Envoy
      |
      |  3. Ingress'in yol kuralları
      |
      +-- /details/...           -->  details podu
      |
      +-- /  (diğer her şey)     -->  productpage podu
```
