### Servis Bağlantısı

#### Adım 3 — nginx'e Service Üzerinden Erişin

İstemci podundan nginx'i **Service adı** ile çağırın:

```bash
kubectl exec pod/netshoot-client -- curl -s http://nginx-service
```

**Welcome to nginx!** sayfasını görürsünüz. Kısa ad çalışır, çünkü iki pod da aynı
namespace'tedir (`default`). Başka bir namespace'ten `nginx-service.default` adını
kullanmanız gerekirdi.

Adın nasıl çözümlendiğine bakın:

```bash
kubectl exec pod/netshoot-client -- nslookup nginx-service
```

Cevap, pod IP'si değil, Service'in **ClusterIP**'sidir. Cluster DNS'i (CoreDNS) her zaman bu sabit adresi döndürür.

Şimdi ClusterIP'yi doğrudan çağırın ve yalnızca HTTP durum kodunu yazdırın:

```bash
CLUSTER_IP=$(kubectl get service nginx-service -o jsonpath='{.spec.clusterIP}')
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$CLUSTER_IP
```

Cevap `200` olur. İstemci ClusterIP ile konuşur ve istek yine diğer node daki nginx
poduna ulaşır.
