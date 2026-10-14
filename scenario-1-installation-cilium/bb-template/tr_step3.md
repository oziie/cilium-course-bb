### Cilium Kurulumu

#### Adım 3 — Kurulumu Doğrulayın

Cilium'un durumunu görüntüleyin:

```bash
cilium status
```

`Cilium`, `Operator` ve `Envoy DaemonSet` değerleri `OK` olmalıdır. `Hubble Relay` ve
`ClusterMesh` ise `disabled` görünür; bu beklenen bir durumdur, çünkü bu kurulumun
parçası değillerdir.

Cilium üç bileşenden oluşur:

| Bileşen | Tür | Görevi |
| --- | --- | --- |
| `cilium` | DaemonSet (her düğümde bir pod) | agent: pod ağını yöneten eBPF programlarını yükler |
| `cilium-envoy` | DaemonSet (her düğümde bir pod) | Layer 7 özellikleri için kullanılan Envoy proxy |
| `cilium-operator` | Deployment (1 kopya) | tüm agent'ların ortak kullandığı kaynakları yönetmek gibi cluster genelindeki işler |

Bileşenleri kubectl ile kontrol edin:

```bash
kubectl get -n kube-system daemonset cilium cilium-envoy
```
```bash
kubectl get -n kube-system deployment cilium-operator
```

İki DaemonSet de `3` istenen ve `3` hazır pod gösterir; her düğümde bir tane. Operator
ise `1/1` gösterir.

Artık bir CNI kurulu olduğu için cluster normal çalışır:

```bash
kubectl get nodes
```
```bash
kubectl get pods -A
```

Üç düğüm de `Ready` durumundadır; 1. adımda `Pending` olan `coredns` ve
`local-path-provisioner` podları artık `Running` durumundadır.
