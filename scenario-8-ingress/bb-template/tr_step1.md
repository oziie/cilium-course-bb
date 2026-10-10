### Ingress ile Uygulama Yayınlama

#### Adım 1 — Kümeyi Oluşturun ve Cilium'u Ingress ile Kurun

Bu senaryoda **Bookinfo** örnek uygulamasını Cilium'un yerleşik **Ingress controller**'ı
ile dışarıya açacak, ona harici bir IP verecek ve kümenin dışından `curl` ile
çağıracaksınız. Üç Cilium özelliği birlikte çalışır:

| Özellik | Ne yapar |
| --- | --- |
| Ingress controller | bir `Ingress`'i Envoy yönlendirme kurallarına ve bir `LoadBalancer` Service'ine dönüştürür |
| LB-IPAM (`CiliumLoadBalancerIPPool`) | `LoadBalancer` Service'lerine, sizin tanımladığınız bir havuzdan harici IP verir |
| L2 duyuruları (`CiliumL2AnnouncementPolicy`) | bir düğümün bu IP için gelen ARP isteklerine cevap vermesini sağlar; böylece kind'ı çalıştıran makine IP'ye ulaşabilir |

Bu senaryo **kube-proxy olmayan** bir küme gerektirir: onun yerini Cilium alır. Önceki
kümeyi silin, ardından yenisini oluşturun. `kubeProxyMode: none`, kind'a kube-proxy
kurmamasını söyler:

```bash
kind delete cluster --name kind
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
l2announcements:
  enabled: true
ingressController:
  enabled: true
EOF
```

- `kubeProxyReplacement: true`: Service'leri kube-proxy yerine Cilium eBPF ile yönetir.
  Ingress controller ve L2 duyuruları bunu gerektirir.
- `l2announcements.enabled: true`: düğümlerin Service IP'leri için ARP isteklerine cevap
  vermesini sağlar.
- `ingressController.enabled: true`: Cilium Ingress controller'ı ve `cilium`
  IngressClass'ını açar.

Cilium'u kurun ve hazır olana kadar bekleyin:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
cilium status --wait
```

kube-proxy olmadığında, Cilium çalışmaya başlamadan önce `kubernetes` Service IP'sini
yönlendirecek hiçbir şey yoktur. `k8sServiceHost` ve `k8sServicePort`, Cilium'a API
sunucusuna doğrudan `kind-control-plane:6443` üzerinden ulaşmasını söyler.

Ayarları ve IngressClass'ı kontrol edin:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-ingress-controller'
kubectl get ingressclass
```

Üç ayar da `true` değerindedir ve `cilium` adında bir IngressClass vardır.
