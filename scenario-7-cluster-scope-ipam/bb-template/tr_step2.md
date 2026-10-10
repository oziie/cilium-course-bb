### Cluster Scope IPAM (Küme Kapsamlı IP Yönetimi)

#### Adım 2 — Her Düğümün Alt Ağını Kontrol Edin

Cilium operator, her düğümün alt ağını o düğümün `CiliumNode` kaynağına yazar:

```bash
kubectl get ciliumnode -o custom-columns=NODE:.metadata.name,CIDR:.spec.ipam.podCIDRs[0]
```

Örnek çıktı (sizdeki dağılım farklı olabilir):

```
NODE                 CIDR
kind-control-plane   10.0.42.8/29
kind-worker          10.0.42.0/29
kind-worker2         10.0.84.8/29
```

Bir `/28` yalnızca iki `/29` alt ağ alır. İlk havuz (`10.0.42.0/28`) iki düğümden sonra
tükenir; bu yüzden üçüncü düğüm alt ağını ikinci havuzdan (`10.0.84.0/28`) alır.

**Bir düğüme kaç pod sığar?** Bir `/29` içinde 8 adres vardır:

| Adres | Kullanımı |
| --- | --- |
| 2 | ağ ve yayın (broadcast) adresi, hiç kullanılmaz |
| 1 | `cilium_host`, Cilium'un düğümdeki router arayüzü |
| 1 | `cilium-health`, Cilium'un sağlık kontrolü endpoint'i |
| **4** | **podlar** |

Cilium düğüm başına **6 atanabilir** adres sayar (8 eksi ağ ve yayın adresi), ancak
podlara yalnızca **4 adres kalır**.
