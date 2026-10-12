### Hubble ile Gözlemlenebilirlik

#### Adım 1 — Kümeyi Oluşturun, Cilium'u Kurun ve Uygulamaları Dağıtın

Bu senaryoda Cilium'un gözlemlenebilirlik katmanı **Hubble**'ı açacak ve küçük bir
uygulamanın trafiğini izleyeceksiniz: poddan poda, poddan Service'e, DNS sorguları,
kümeden çıkan trafik ve başarısız bir bağlantı. Hiçbir ağ politikası kullanılmaz: Hubble
yalnızca gözlemler.

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

Cilium'u Helm ile kurun ve hazır olana kadar bekleyin:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set ipam.mode=kubernetes \
  --set operator.replicas=1 \
  --set routingMode=tunnel \
  --set tunnelProtocol=vxlan
cilium status --wait
```

`hubble` CLI'ı Cilium ile aynı ara sürümden (1.18) kurun. Daha yeni bir CLI, Hubble
sunucusundan Cilium 1.18'in tanımadığı akış alanlarını ister ve `hubble observe`
`invalid fieldmask` hatasıyla başarısız olur:

```bash
HUBBLE_VERSION=v1.18.6
HUBBLE_ARCH=$(dpkg --print-architecture)
curl -fsSL --remote-name-all \
  "https://github.com/cilium/hubble/releases/download/${HUBBLE_VERSION}/hubble-linux-${HUBBLE_ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "hubble-linux-${HUBBLE_ARCH}.tar.gz.sha256sum"
sudo tar -C /usr/local/bin -xzf "hubble-linux-${HUBBLE_ARCH}.tar.gz"
rm "hubble-linux-${HUBBLE_ARCH}.tar.gz"{,.sha256sum}
hubble version
```

`hubble version` çıktısında `hubble v1.18.6` görünür.

Uygulamaları dağıtın: `kind-worker2` üzerinde nginx, `kind-worker` üzerinde bir istemci
podu ve nginx'in önünde `nginx-service` adlı bir Service:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx-deployment
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: nginx
  template:
    metadata:
      labels:
        app.kubernetes.io/name: nginx
    spec:
      nodeSelector:
        kubernetes.io/hostname: kind-worker2
      containers:
        - name: nginx
          image: nginx
---
apiVersion: v1
kind: Pod
metadata:
  name: netshoot-client
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Service
metadata:
  name: nginx-service
spec:
  selector:
    app.kubernetes.io/name: nginx
  ports:
    - port: 80
EOF

kubectl wait --for=condition=Ready pod --all --timeout=120s
kubectl get pods -o wide
```

İstemci `kind-worker` üzerinde, nginx ise `kind-worker2` üzerinde çalışır.
