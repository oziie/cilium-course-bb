### Egress Gateway ile Sabit Çıkış IP'si

#### Adım 1 — Kümeyi Oluşturun ve Cilium'u Egress Gateway ile Kurun

Bir pod küme dışındaki bir hedefle konuştuğunda Cilium trafiği **maskeler**
(masquerade): pod IP'sini, pod'un çalıştığı düğümün IP'si ile değiştirir. Pod'lar
düğümler arasında yer değiştirebildiği için dış dünya, pod'un o an nerede çalıştığına
göre farklı bir IP görür. Bu durum, yalnızca **izin listesindeki IP'leri** kabul eden
partner API'lerini, veritabanlarını ve güvenlik duvarlarını bozar.

**Egress Gateway** bu sorunu çözer. Bir `CiliumEgressGatewayPolicy` şunları belirtir:

| Alan | Cevapladığı soru |
| --- | --- |
| `selectors` | hangi **pod'lara** uygulanır? |
| `destinationCIDRs` | küme dışındaki hangi **hedeflere**? |
| `egressGateway` | trafiği **hangi düğüm**, **hangi IP** ile dışarı çıkarır? |

Eşleşen trafik tünel üzerinden gateway düğümüne gönderilir ve bu düğüm onu kendi IP'si
ile dışarı çıkarır. Pod nerede çalışırsa çalışsın dış dünya tek bir IP görür.

```
                   kind Docker ağı (172.18.0.0/16)

 kind-worker                             kind-worker2 (egress-gateway=true)
┌──────────────────┐   VXLAN tüneli    ┌──────────────────┐
│ payments pod ────┼──────────────────▶│ kendi IP'si ile  │──┐
│                  │                   │ SNAT 172.18.0.4  │  │
│ catalog pod ─────┼── kind-worker'ın  └──────────────────┘  ▼
└──────────────────┘   IP'si ile SNAT ──────────▶  external-server
                       172.18.0.3            (çağıranın IP'sini yazar)
```

Yukarıdaki IP'ler örnektir; kendi değerlerinizi 2. adımda göreceksiniz.

Senaryo 8 ve 9'daki gibi Egress Gateway de **kube-proxy olmayan** bir küme gerektirir.
Eğer varsa, önceki kümeyi silin, ardından yenisini oluşturun:

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

Cilium ayarlarını bir values dosyasına yazın:

```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
bpf:
  masquerade: true
egressGateway:
  enabled: true
EOF
```

- `kubeProxyReplacement: true` ve `bpf.masquerade: true`: Egress Gateway, iptables
  tabanlı maskelemenin yerini alan Cilium'un eBPF maskelemesi üzerine kuruludur. İkisi
  de gereklidir.
- `egressGateway.enabled: true`: agent'larda Egress Gateway özelliğini açar.

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

Ayarları kontrol edin:

```bash
cilium config view | grep -E 'kube-proxy-replacement |enable-bpf-masquerade|enable-egress-gateway'
```

Üç ayar da `true` değerindedir.
