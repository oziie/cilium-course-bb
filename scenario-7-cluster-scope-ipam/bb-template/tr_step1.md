### Cluster Scope IPAM (Küme Kapsamlı IP Yönetimi)

#### Adım 1 — Kümeyi Cluster Scope IPAM ile Oluşturun

**IPAM** (IP Address Management), her podun hangi IP adresini alacağına karar verir.
**Cluster Scope** modunda (`ipam.mode=cluster-pool`) her düğüme pod adres aralığını
(PodCIDR) **Kubernetes değil, Cilium** verir. Cilium operator, küme genelindeki bir veya
daha fazla havuzu düğüm başına alt ağlara böler. Kubernetes'te özel bir yapılandırma
gerektirmediği için Cilium'un **varsayılan** IPAM modudur. Avantajı, kümenin tek bir
havuz yerine **birden fazla** havuza sahip olabilmesidir. Ancak havuzlar çok küçükse
podların adresleri yine tükenir. Bu senaryo tam olarak bunu canlandırır.

**Önce önceki kümeyi silin (zorunlu).** IPAM modu Cilium kurulurken belirlenir ve
**çalışan bir kümede değiştirilemez**. Önceki bir senaryodan kalan bir küme varsa
`ipam.mode=kubernetes` kullanır; bu yüzden onu silin:

```bash
kind delete cluster --name kind
```

Kümeyi oluşturun:

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

Cilium ayarlarını bir values dosyasına yazın. `ipam` dışında, bilinen lab ayarlarıdır:

```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: cluster-pool
  operator:
    clusterPoolIPv4MaskSize: 29
    clusterPoolIPv4PodCIDRList:
      - 10.0.42.0/28
      - 10.0.84.0/28
EOF
```

- `clusterPoolIPv4PodCIDRList`: tüm küme için iki küçük `/28` havuz (her biri 16 adres).
- `clusterPoolIPv4MaskSize: 29`: her düğüm, havuzlardan birinden bir `/29` (8 adres)
  alır.

Cilium'u bu değerlerle kurun ve hazır olana kadar bekleyin:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  -f cilium-values.yaml
cilium status --wait
```

Cilium'un Cluster Scope modunda çalıştığını kontrol edin:

```bash
cilium config view | grep cluster-pool
```

`ipam cluster-pool` satırını, `cluster-pool-ipv4-cidr` içindeki iki havuzu ve `29` maske
boyutunu görürsünüz.
