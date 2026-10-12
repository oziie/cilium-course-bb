### Hubble ile Gözlemlenebilirlik

#### Adım 3 — Poddan Poda ve Poddan Service'e Trafiği Gözlemleyin

**Poddan poda.** nginx'i pod IP'siyle çağırın, ardından istemci podunun son akışlarını
görüntüleyin:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
hubble observe --pod default/netshoot-client --last 10
```

Tek bir `curl`, eksiksiz bir TCP konuşması üretir. Çıktı şuna benzer (isimler, portlar
ve ID'ler sizin kümenizde farklı olur):

```
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.286: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:53:59.287: default/netshoot-client:38958 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
```

Nasıl okunur:

| Bölüm | Anlamı |
| --- | --- |
| `default/netshoot-client:38958` | namespace/pod ve port: Hubble yalnızca IP değil, isim gösterir |
| `(ID:48603)` | podun etiketlerinden türetilen Cilium **güvenlik kimliği** (security identity) |
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

Çıktı şuna benzer. Önceki poddan poda çağrının akışları da bu satırların üstünde görünür;
burada çıkarılmıştır:

```
Oct 12 21:58:27.585: default/netshoot-client:52192 (ID:48603) -> kube-system/coredns-559f6c778d-shp78:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.588: default/netshoot-client:52192 (ID:48603) <- kube-system/coredns-559f6c778d-shp78:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.839: default/netshoot-client:41963 (ID:48603) -> kube-system/coredns-559f6c778d-tpm7h:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: SYN)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: SYN, ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.840: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, PSH)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.842: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) <- default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-overlay FORWARDED (TCP Flags: ACK, FIN)
Oct 12 21:58:27.843: default/netshoot-client:39002 (ID:48603) -> default/nginx-deployment-6fdd9c87dd-4ts4d:80 (ID:30621) to-endpoint FORWARDED (TCP Flags: ACK)
Oct 12 21:58:28.627: default/netshoot-client:41963 (ID:48603) <- kube-system/coredns-559f6c778d-tpm7h:53 (ID:17890) to-endpoint FORWARDED (UDP)
Oct 12 21:58:28.628: default/netshoot-client (ID:48603) -> 10.96.0.10 (world) to-stack FORWARDED (ICMPv4 DestinationUnreachable(Port))
```

İki yeni şey görünür:

1. 53 portunda (`UDP`) bir `kube-system/coredns-...` poduna giden **DNS sorgusu**: istemci
   önce CoreDNS'e `nginx-service`'in IP'sini sorar.
2. **TCP akışları ClusterIP'ye değil, nginx poduna gider.** Cilium, paket istemciden
   çıkmadan önce ClusterIP'yi eBPF ile bir pod IP'sine çevirir; bu yüzden akışlar
   poddan poda olanlarla tamamen aynı görünür.

Son iki satır geç gelen bir DNS cevabıdır: cevap, `curl` soketini kapattıktan sonra
ulaşır; bu yüzden istemcinin çekirdeği bir ICMP `DestinationUnreachable(Port)` ile cevap
verir. Bu paket, `kube-dns` Service'inin ClusterIP'si olan `10.96.0.10` adresine gider.
ClusterIP hiçbir poda ait değildir ve kimliği yoktur, bu yüzden Hubble onu `world` olarak
etiketler. Zararsızdır.

> **Not:** Hubble 80 portunda trafik olduğunu gösterir, ancak HTTP metodunu, yolunu veya
> durum kodunu göstermez. Bu ayrıntı, trafiği Envoy üzerinden geçiren bir L7 politikası
> gerektirir. L7 politikası olmadan Hubble L3/L4 seviyesinde çalışır.
