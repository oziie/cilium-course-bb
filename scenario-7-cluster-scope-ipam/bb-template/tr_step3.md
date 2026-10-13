### Cluster Scope IPAM (Cluster Kapsamlı IP Yönetimi)

#### Adım 3 — Örnek Bir Pod Dağıtın ve Düğümün Adreslerini Kontrol Edin

`kind-worker` üzerinde bir pod dağıtın:

```bash
kubectl run netshoot-client --image=nicolaka/netshoot \
  --overrides='{"spec":{"nodeSelector":{"kubernetes.io/hostname":"kind-worker"}}}' \
  -- sleep infinity
kubectl wait --for=condition=Ready pod/netshoot-client --timeout=120s
kubectl get pod netshoot-client -o wide
```

Pod IP'si, 2. adımda gördüğünüz `kind-worker` düğümünün `/29` alt ağından gelir.

Şimdi bu düğümdeki Cilium agent üzerinde `cilium-dbg status` çıktısının IPAM bölümüne
bakın:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg status --verbose | grep -A 6 '^IPAM'
```

Örnek çıktı:

```
IPAM:                    IPv4: 3/6 allocated from 10.0.42.0/29,
Allocated addresses:
  10.0.42.1 (router)
  10.0.42.4 (health)
  10.0.42.5 (default/netshoot-client)
```

`3/6`, 6 atanabilir adresten 3'ünün kullanımda olduğunu gösterir: router
(`cilium_host`), sağlık endpoint'i ve sizin podunuz. Bu düğümde `coredns` podları
çalışıyorsa onlar da listelenir.
