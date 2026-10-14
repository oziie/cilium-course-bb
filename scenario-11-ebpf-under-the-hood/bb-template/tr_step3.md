### eBPF ile Cilium'un Perde Arkası

#### Adım 3 — Map'ler: Verinin Yaşadığı Yer

eBPF programları kendi durumlarını tutmaz. Bir paketle ne yapacaklarına karar vermek
için ihtiyaç duydukları her şey **map'lerde** durur: hem programların hem de Cilium
agent'ının okuyup yazabildiği, çekirdekteki anahtar/değer depoları. Client'ın çalıştığı
`kind-worker` üzerindeki map'leri listeleyin:

```bash
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg map list
```

Her satır bir map'tir ve tuttuğu kayıt sayısını gösterir. Tam adlar bir sürüm eki taşır
(örneğin `_v2`); şu öneklere bakın:

| Map adı şununla başlar | İçerik |
| --- | --- |
| `cilium_lb4_services`, `cilium_lb4_backends` | Service'ler ve backend pod'ları |
| `cilium_ipcache` | bilinen her IP → güvenlik kimliği (identity) |
| `cilium_policy` | izin verilen kimlikler ve portlar, endpoint başına bir map |
| `cilium_ct4_global` | bağlantı takibi (connection tracking): açık bağlantılar |

Şimdi `nginx` Service'ini yük dengeleme map'inde arayın:

```bash
NGINX_IP=$(kubectl get svc nginx -o jsonpath='{.spec.clusterIP}')
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
```

ClusterIP'nin her backend için bir satırı vardır ve her satırda bir `nginx` pod IP'si
bulunur. Client `http://nginx` adresini çağırdığında, client'ın `lxc` arayüzündeki
program bu map'e bakar, bir backend seçer ve hedef adresi hemen yeniden yazar.

Deployment'ı ölçekleyin ve tekrar bakın:

```bash
kubectl scale deployment nginx --replicas=4
```
```bash
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
```
```bash
kubectl -n kube-system exec $AGENT1 -c cilium-agent -- cilium-dbg bpf lb list | grep $NGINX_IP
```

Artık dört backend var. Cilium'da eBPF'in ana fikri budur: **programlar mantıktır ve
aynı kalır; map'ler veridir ve sürekli değişir.** Agent yalnızca map'e iki kayıt ekledi.
Hiçbir program yeniden yüklenmedi.

kube-proxy olsaydı her Service, her düğümde `KUBE-SVC-...` iptables zincirleri de
oluştururdu. Düğümde bunları sayın:

```bash
docker exec kind-worker iptables-save | grep -c KUBE-SVC
```

Sayı `0`: Service yük dengelemesi tamamen eBPF programları ve map'lerle yapılır.
Sonraki adımdan önce replikaları geri azaltın:

```bash
kubectl scale deployment nginx --replicas=2
```
