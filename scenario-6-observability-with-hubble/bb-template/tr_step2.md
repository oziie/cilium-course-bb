### Hubble ile Gözlemlenebilirlik

#### Adım 2 — Hubble Relay'i Etkinleştirin ve CLI'ı Bağlayın

Cilium'un eBPF programları, bir poda giren ya da poddan çıkan her paketi zaten görür.
Hubble bunları okunabilir **akışlara** (flow) dönüştürür:

| Bileşen | Nerede çalışır | Görevi |
| --- | --- | --- |
| Hubble sunucusu | her `cilium` agent'ın içinde | kendi düğümünün akışlarını kaydeder (varsayılan olarak açık) |
| Hubble Relay | `hubble-relay` Deployment'ı | **tüm** düğümlerin akışlarını tek bir API'de toplar |
| `hubble` CLI | terminaliniz | akışları Relay'den okur |

Hubble Relay'i bir Helm upgrade ile etkinleştirin. `--reuse-values` kurulumdaki ayarları
korur ve yalnızca Relay'i ekler:

```bash
helm upgrade cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --reuse-values \
  --set hubble.relay.enabled=true
kubectl -n kube-system rollout status deployment/hubble-relay
cilium status
```

`cilium status` artık `Hubble Relay: OK` gösterir.

`hubble` CLI, Relay'e `localhost:4245` üzerinden bağlanır. Relay'e bir port-forward açın.
Sondaki `&` komutu arka planda çalışır durumda tutar; böylece bu terminali kullanmaya
devam edebilirsiniz:

```bash
cilium hubble port-forward > /dev/null 2>&1 &
sleep 3
hubble status
```

`hubble status`, `Healthcheck (via localhost:4245): Ok` ve `Connected Nodes: 3/3`
gösterir: Relay her düğümdeki Hubble sunucusuna ulaşıyor.

```bash
hubble list nodes
```

Her düğüm en son akışlarını bellekte tutar (düğüm başına 4095); bu yüzden Hubble tüm
geçmişi değil, yakın zamandaki trafiği gösterir.

> **Not:** `hubble status` komutu `connect: connection refused` hatası verirse
> port-forward çalışmıyor demektir. Yukarıdaki `cilium hubble port-forward` komutuyla
> tekrar başlatın.
