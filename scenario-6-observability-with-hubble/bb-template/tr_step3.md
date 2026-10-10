### Hubble ile Gözlemlenebilirlik

#### Adım 3 — Poddan Poda ve Poddan Service'e Trafiği Gözlemleyin

**Poddan poda.** nginx'i pod IP'siyle çağırın, ardından istemci podunun son akışlarını
görüntüleyin:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
hubble observe --pod default/netshoot-client --last 10
```

Tek bir `curl`, eksiksiz bir TCP konuşması üretir. Bir akış şöyle görünür:

```
default/netshoot-client:51522 (ID:28634) -> default/nginx-deployment-...:80 (ID:4512) to-overlay FORWARDED (TCP Flags: SYN)
```

Nasıl okunur:

| Bölüm | Anlamı |
| --- | --- |
| `default/netshoot-client:51522` | namespace/pod ve port: Hubble yalnızca IP değil, isim gösterir |
| `(ID:28634)` | podun etiketlerinden türetilen Cilium **güvenlik kimliği** (security identity) |
| `->` / `<-` | istek yönü / cevap yönü |
| `to-overlay` | paket düğümden VXLAN tüneli üzerinden çıktı |
| `to-endpoint` | paket hedef poda teslim edildi |
| `FORWARDED` | pakete izin verildi. Diğer karar `DROPPED`'dır |
| `TCP Flags` | `SYN` → `SYN, ACK` → `ACK` el sıkışmadır, `PSH` veri taşır, `FIN` bağlantıyı kapatır |

Aynı `SYN` iki kez görünür: bir kez `kind-worker`'dan çıkarken (`to-overlay`), bir kez de
`kind-worker2`'ye varırken (`to-endpoint`). Her düğüm gördüğünü kaydeder, Relay de
bunları birleştirir.

**Poddan Service'e.** Şimdi nginx'i **Service adıyla** çağırın:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx-service
hubble observe --pod default/netshoot-client --last 20
```

İki yeni şey görünür:

1. 53 portunda (`UDP`) bir `kube-system/coredns-...` poduna giden **DNS sorgusu**: istemci
   önce CoreDNS'e `nginx-service`'in IP'sini sorar.
2. **TCP akışları ClusterIP'ye değil, nginx poduna gider.** Cilium, paket istemciden
   çıkmadan önce ClusterIP'yi eBPF ile bir pod IP'sine çevirir; bu yüzden akışlar
   poddan poda olanlarla tamamen aynı görünür.

> **Not:** Hubble 80 portunda trafik olduğunu gösterir, ancak HTTP metodunu, yolunu veya
> durum kodunu göstermez. Bu ayrıntı, trafiği Envoy üzerinden geçiren bir L7 politikası
> gerektirir. L7 politikası olmadan Hubble L3/L4 seviyesinde çalışır.
