### Pod Bağlantısı

#### Adım 1 — Kümeyi Oluşturun ve Cilium'u Kurun

Bu senaryoda **farklı düğümlerde** çalışan iki podun, Cilium'un VXLAN tüneli üzerinden
birbiriyle konuşabildiğini kontrol edeceksiniz. Önce lab kümesini kurun: 1 control-plane
ve 2 worker düğümü, ağ eklentisi (CNI) olarak Cilium.

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

Cilium'u Helm ile kurun. `routingMode=tunnel` ve `tunnelProtocol=vxlan` düğümler arası
trafiği bir VXLAN tüneli içinde taşır; bu senaryoda test edilen de budur:

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

Üç düğüm de `Ready` olmalıdır: `kind-control-plane`, `kind-worker` ve `kind-worker2`.
