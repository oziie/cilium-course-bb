### Hubble ile Gözlemlenebilirlik

#### Adım 4 — Akışları Filtreleyin, Kümeden Çıkan Trafik ve Başarısız Bir Bağlantı

**Filtreler.** Filtresiz `hubble observe` tüm kümenin akışlarını gösterir ve bu çok
kalabalıktır. Birkaç filtre çoğu soruyu cevaplar:

```bash
# nginx'i kim çağırıyor?
hubble observe --to-pod default/nginx-deployment --last 10

# Kümedeki tüm DNS trafiği
hubble observe --port 53 --last 10

# Yalnızca tek bir düğümde olanlar
hubble observe --node kind-worker2 --last 10
```

`--to-pod default/nginx-deployment`, adı `nginx-deployment` ile **başlayan** tüm podlarla
eşleşir; bu yüzden rastgele son eke ihtiyacınız yoktur.

**Kümeden çıkan trafik.** İnternetteki bir siteyi çağırın, ardından Cilium'un küme
dışındaki her şeye verdiği `world` kimliğine göre filtreleyin:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" https://example.com
hubble observe --pod default/netshoot-client --to-label reserved:world --last 10
```

- Hedef, bir IP ve ardından `(world)` olarak gösterilir.
- `to-stack`, paketin düğümün ağ yığınına teslim edildiği anlamına gelir; düğüm de paketi
  kümenin dışına gönderir.

**Başarısız bir bağlantı.** Her hata bir ağ sorunu değildir. nginx'i, hiçbir şeyin
dinlemediği 8081 portundan çağırın:

```bash
kubectl exec pod/netshoot-client -- curl -s -m 3 http://$NGINX_IP:8081
hubble observe --pod default/netshoot-client --port 8081 --last 10
```

`curl`, `exit code 7` ile başarısız olur. Hubble'da:

- `SYN` paketi `FORWARDED` olarak görünür: ağ onu nginx poduna teslim etti;
- pod `TCP Flags: ACK, RST` ile cevap verdi: "bu portta dinleyen yok".

Bu bir ağ sorunu değil, uygulama veya yapılandırma sorunudur. Bir politika engeli farklı
görünürdü: `DROPPED` kararı ve hiç cevap yok.

> **Not:** `$NGINX_IP` boşsa (örneğin yeni bir terminalde), 3. adımın ilk komutuyla
> tekrar ayarlayın.
