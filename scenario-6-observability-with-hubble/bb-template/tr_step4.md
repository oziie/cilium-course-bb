### Hubble ile Gözlemlenebilirlik

#### Adım 4 — Akışları Filtreleyin, Clusterdan Çıkan Trafik ve Başarısız Bir Bağlantı

**Filtreler.** Filtresiz `hubble observe` tüm cluster akışlarını gösterir ve bu çok
kalabalıktır. Birkaç filtre çoğu soruyu cevaplar:

```bash
# nginx'i kim çağırıyor?
hubble observe --to-pod default/nginx-deployment --last 10

# Clusterdaki tüm DNS trafiği
hubble observe --port 53 --last 10

# Yalnızca tek bir düğümde olanlar
hubble observe --node-name kind-worker2 --last 10
```

`--to-pod default/nginx-deployment`, adı `nginx-deployment` ile **başlayan** tüm podlarla
eşleşir; bu yüzden rastgele son eke ihtiyacınız yoktur.

> **Not:** Her akışı hangi düğümün kaydettiğini görmek için herhangi bir `hubble observe`
> komutuna `--print-node-name` ekleyin. Her satırda düğüm adı da görünür, örneğin
> `kind-kind/kind-worker2`.

**Clusterdan çıkan trafik.** İnternetteki bir siteyi çağırın, ardından Cilium'un cluster
dışındaki her şeye verdiği `world` kimliğine göre filtreleyin:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" https://google.com
hubble observe --pod default/netshoot-client --to-label reserved:world --last 10
```

- Hedef, bir IP ve ardından `(world)` olarak gösterilir.
- `to-stack`, paketin düğümün ağ yığınına teslim edildiği anlamına gelir; düğüm de paketi
  cluster dışına gönderir.

**Başarısız bir bağlantı.** Her hata bir ağ sorunu değildir. nginx'i, hiçbir şeyin
dinlemediği 8081 portundan çağırın:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
kubectl exec pod/netshoot-client -- curl -s -m 3 http://$NGINX_IP:8081
hubble observe --port 8081 --last 10
```

`curl`, `exit code 7` ile başarısız olur. Hubble'da:

- `SYN` paketi `FORWARDED` olarak görünür: ağ onu nginx poduna teslim etti;
- pod `TCP Flags: ACK, RST` ile cevap verdi: "bu portta dinleyen yok".

Bu bir ağ sorunu değil, uygulama veya yapılandırma sorunudur. Bir politika engeli farklı
görünürdü: `DROPPED` kararı ve hiç cevap görünmezdi.

> **Not:** `--pod` ve `--port` birlikte kullanıldığında, yalnızca pod **ve** port akışın
> aynı tarafındaysa eşleşir. İstemci rastgele bir port kullanır, 8081 portu ise nginx'e
> aittir; bu yüzden `--pod default/netshoot-client --port 8081` hiçbir şey göstermez.
> Yalnızca porta göre filtreleyin.
