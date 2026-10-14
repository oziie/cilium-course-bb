### Servis Bağlantısı

#### Adım 4 — Service, Podun Yeniden Başlatılmasından Etkilenmez

nginx podunun şu anki IP'sine bakın, ardından podu silin. Deployment hemen yeni bir pod
oluşturur:

```bash
kubectl get pods -l app.kubernetes.io/name=nginx -o wide
```
```bash
kubectl delete pod -l app.kubernetes.io/name=nginx
```
```bash
kubectl wait --for=condition=Ready pod -l app.kubernetes.io/name=nginx --timeout=60s
```
```bash
kubectl get pods -l app.kubernetes.io/name=nginx -o wide
```

Yeni podun IP'si **farklıdır**. Service'i tekrar çağırın:

```bash
kubectl exec pod/netshoot-client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx-service
```

Cevap yine `200`: Service adı ve ClusterIP değişmedi; Service artık trafiği yeni poda
yönlendiriyor. İstemcilerin pod IP'leri yerine Service kullanmasının nedeni budur.

**Service'e Cilium'un gözünden bakış.** Cilium, ClusterIP'yi doğrudan istemcinin
düğümünde, eBPF ile bir pod IP'sine çevirir. Her Cilium agent bir Service tablosu tutar.
Bu tabloyu, istemcinin çalıştığı `kind-worker` düğümündeki agent üzerinde görüntüleyin:

```bash
AGENT=$(kubectl get pod -n kube-system -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $AGENT -c cilium-agent -- cilium-dbg service list
```

`nginx-service`'in ClusterIP'sini ve 80 portunu içeren satırı bulun (`Frontend`). Bu
satırın `Backend` değeri **yeni** nginx pod IP'sidir. Cilium, pod değişir değişmez
tabloyu güncelledi.
