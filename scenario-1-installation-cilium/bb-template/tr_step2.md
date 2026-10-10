### Cilium Kurulumu

#### Adım 2 — Cilium'u Helm ile Kurun

Cilium Helm deposunu ekleyin:

```bash
helm repo add cilium https://helm.cilium.io/
```

Cilium'u `kube-system` namespace'ine kurun:

```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

Ayarların anlamı:

- `--version 1.18.4` Cilium sürümünü sabitler. Belirtilmezse Helm en son sürümü kurar ve
  bu sürüm her gün değişebilir. Sürümü sabitlemek tüm ortamların aynı kalmasını sağlar.
- `cluster.name=kind-kind` kümeye, kind'ın oluşturduğu kubectl context'i ile aynı adı
  verir.
- `ipam.mode=kubernetes` Cilium'un pod IP'lerini, Kubernetes'in her düğüme atadığı adres
  aralığından vermesini sağlar.
- `operator.replicas=1` tek bir Cilium operator çalıştırır; küçük bir lab kümesi için
  yeterlidir.
- `routingMode=tunnel` ve `tunnelProtocol=vxlan` düğümler arası trafiği bir VXLAN tüneli
  içinde taşır; böylece düğümlerin ağının pod IP'lerini bilmesi gerekmez.

Kurulumun tamamlanmasını bekleyin:

```bash
cilium status --wait
```

Komut, tüm Cilium bileşenleri hazır olduğunda sonlanır. Bu birkaç dakika sürebilir.
