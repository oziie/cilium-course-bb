### Pod Bağlantısı

#### Adım 3 — Podlar Arası Bağlantıyı Test Edin

nginx podunun IP'sini bir değişkene kaydedin:

```bash
NGINX_IP=$(kubectl get pod -l app.kubernetes.io/name=nginx -o jsonpath='{.items[0].status.podIP}')
echo $NGINX_IP
```

`kind-worker` üzerindeki istemci podundan, `kind-worker2` üzerindeki nginx sayfasını
isteyin:

```bash
kubectl exec pod/netshoot-client -- curl -s http://$NGINX_IP
```

**Welcome to nginx!** sayfasının HTML içeriğini görürsünüz.

Şimdi yalnızca HTTP durum kodunu yazdırın:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://$NGINX_IP
```

Cevap `200` olur: istek başarılı.

İki pod farklı düğümlerde çalıştığı için istek `kind-worker`'dan çıktı, Cilium'un
düğümler arasında kurduğu **VXLAN tüneli** içinden geçti ve `kind-worker2` üzerindeki
nginx poduna ulaştı. Hiçbir rota tanımlamadınız: düğümler arası pod bağlantısını Cilium
kendisi sağlar.
