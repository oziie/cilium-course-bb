### eBPF ile Cilium'un Perde Arkası

#### Adım 1 — eBPF Nedir? Kümeyi Oluşturun

**eBPF**, çekirdeği değiştirmeden veya bir çekirdek modülü yüklemeden, Linux
çekirdeğinin içinde küçük ve güvenli programlar çalıştırmanızı sağlar; bu programlar
bir ağ arayüzüne paket gelmesi gibi olaylarla tetiklenir. Cilium, trafiği uzun iptables
zincirleri yerine paketlerin çekirdekten geçtiği noktada yönlendirmek, yük dengelemek ve
güvenli hale getirmek için eBPF kullanır.

Önceki tüm senaryolar eBPF'i göstermeden kullandı. Bu senaryoda Cilium'u oluşturan üç
yapı taşına bakacaksınız:

1. **Hook'lara bağlı programlar**: her paket için çalışan kod (Adım 2).
2. **Map'ler**: programların ihtiyaç duyduğu, Service'ler ve politikalar gibi verileri
   tutan, çekirdekteki anahtar/değer depoları (Adım 3).
3. **Olaylar (events)**: programların kullanıcı alanına gönderdiği mesajlar; örneğin
   bir paketi düşürdüklerinde (Adım 4).

```
 kullanıcı    cilium-agent                 cilium-dbg monitor / Hubble
 alanı             │ yazar                             ▲
 ──────────────────┼───────────────────────────────────┼─────────────
 çekirdek          ▼                                   │ olaylar
              ┌──────────┐  okuma     ┌─────────┐      │
              │ map'ler  │◀───────────│ program │──────┘
              └──────────┘            └────▲────┘
                                           │ çalışır
             paket ──▶ hook (lxc / eth0 / cilium_vxlan)
```

Bu senaryo **kube-proxy olmayan** bir küme kullanır, böylece Service'ler yalnızca eBPF
ile yönetilir. Önceki kümeyi silin, ardından yenisini oluşturun:

```bash
kind delete cluster --name kind
```
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
  kubeProxyMode: none
EOF
```
```bash
kind create cluster --config light-lab.yaml
```

Cilium ayarlarını bir values dosyasına yazın. Bunlar Senaryo 1 ayarlarına ek olarak
`kubeProxyReplacement: true` içerir:

```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
EOF
```

Cilium'u kurun ve hazır olana kadar bekleyin:

```bash
helm repo add cilium https://helm.cilium.io/
```
```bash
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
```
```bash
cilium status --wait
```
```bash
cilium config view | grep 'kube-proxy-replacement '
```

`kube-proxy-replacement` değeri `true`: artık kube-proxy'nin yaptığı işi eBPF yapıyor.
