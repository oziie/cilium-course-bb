### Ağ Politikaları (L3/L4)

#### Adım 1 — Kümeyi Oluşturun ve Cilium'u Kurun

Bu senaryoda üç katmanlı küçük bir mağaza uygulamasını `CiliumNetworkPolicy` ile
kısıtlayacaksınız. Her katman kendi namespace'inde çalışır ve yalnızca her katmanın
gerçekten ihtiyaç duyduğu trafiğe izin verilir.

```
 ns: frontend           ns: backend                   ns: database
┌─────────────┐  8080  ┌───────────────────┐  6379   ┌─────────────┐
│ web         │──────▶ │ api (nginx)       │──────▶  │ redis       │
│ (netshoot)  │        │  :8080 public API │         │  :6379      │
└─────────────┘        │  :9090 admin      │         └─────────────┘
                       └───────────────────┘
 ns: default
┌─────────────┐
│ intruder    │   her yerde engellenmeli
│ (netshoot)  │
└─────────────┘
```

Önce lab kümesini kurun: 1 control-plane ve 2 worker düğümü, ağ eklentisi (CNI)
olarak Cilium.

kind yapılandırma dosyasını yazın ve kümeyi oluşturun. `disableDefaultCNI: true`,
kind'ın varsayılan ağ eklentisini kapatır; böylece pod ağını Cilium yönetebilir:

```bash
cat > light-lab.yaml <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true
EOF
```
```bash
kind create cluster --config light-lab.yaml
```

Cilium'u Helm ile kurun:

```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

Cilium hazır olana kadar bekleyin, ardından düğümleri kontrol edin:

```bash
cilium status --wait
```
```bash
kubectl get nodes
```

Üç düğüm de `Ready` olmalıdır.
