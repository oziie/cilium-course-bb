### Ağ Politikaları (Layer 7)

#### Adım 1 — Kümeyi Oluşturun ve Cilium'u Kurun

Bu senaryoda IP ve portların ötesine geçeceksiniz: bir API'ye yalnızca belirli **HTTP
metot ve yollarına** izin verecek, hassas bir çağrı için bir **header** zorunlu kılacak
ve bir podun internet erişimini tek bir **alan adıyla** sınırlayacaksınız.

```
 ns: frontend           ns: backend                       ns: database
┌─────────────┐  8080  ┌───────────────────────────┐ 6379 ┌─────────────┐
│ web         │──────▶ │ api (nginx)               │────▶ │ redis       │
│ (netshoot)  │  HTTP  │  GET    /api/products     │      │  :6379      │
└─────┬───────┘        │  GET    /api/orders       │      └─────────────┘
      │ 443            │  POST   /api/orders       │
      ▼                │  DELETE /api/orders/{id}  │
 api.github.com        │  GET    /admin            │
 (yalnızca bu ad)      └───────────────────────────┘
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
kind create cluster --config light-lab.yaml
```

Cilium'u Helm ile kurun:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
```

Cilium hazır olana kadar bekleyin:

```bash
cilium status --wait
kubectl get nodes
```

Katman 7 (L7) politikaları **Envoy** proxy tarafından uygulanır. Cilium bunu zaten her
düğümde `cilium-envoy` DaemonSet'i olarak çalıştırır; ek bir şey etkinleştirmeniz
gerekmez:

```bash
kubectl get -n kube-system daemonset cilium-envoy
```

DaemonSet, her düğümde bir tane olmak üzere `3` hazır pod gösterir.
