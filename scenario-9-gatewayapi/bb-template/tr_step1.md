### Gateway API ile Uygulama Yayınlama

#### Adım 1 — Kümeyi Oluşturun, Gateway API CRD'lerini ve Cilium'u Kurun

Senaryo 8'de Bookinfo'yu bir `Ingress` ile dışarıya açtınız. Ingress yalnızca host ve
yola göre yönlendirme yapar; fazlası controller'a özel annotation'lar gerektirir.
**Gateway API** onun halefidir ve işi farklı rollerin sahip olduğu kaynaklara böler:

| Kaynak | Sahibi | Neyi tanımlar |
| --- | --- | --- |
| `GatewayClass` | altyapı sağlayıcısı | Gateway'leri hangi controller'ın uyguladığı (burada: `cilium`) |
| `Gateway` | platform ekibi | bir giriş noktası: listener'lar, portlar, bir IP |
| `HTTPRoute` | uygulama ekibi | yönlendirme kuralları: eşleşmeler, backend'ler, ağırlıklar |

Bu senaryo **kube-proxy olmayan** bir küme gerektirir: onun yerini Cilium alır. `kubeProxyMode: none`, kind'a kube-proxy
kurmamasını söyler:

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

Gateway API kaynakları Kubernetes'e gömülü değildir, birer CRD'dir. **Bunları Cilium'dan
önce kurun:** Cilium, Gateway API controller'ını ve Helm chart'ı `cilium`
GatewayClass'ını ancak CRD'ler zaten varsa oluşturur. Cilium 1.18, Gateway API
**v1.3.0** sürümünü destekler:

```bash
for crd in gatewayclasses gateways httproutes referencegrants grpcroutes; do
  kubectl apply -f https://raw.githubusercontent.com/kubernetes-sigs/gateway-api/v1.3.0/config/crd/standard/gateway.networking.k8s.io_${crd}.yaml
done
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
gatewayAPI:
  enabled: true
EOF
```

- `kubeProxyReplacement: true`: Gateway API desteği ve L2 duyuruları bunu gerektirir.
- `l2announcements.enabled: true`: düğümlerin Service IP'leri için ARP isteklerine cevap
  vermesini sağlar.
- `gatewayAPI.enabled: true`: Cilium operator'deki Gateway API controller'ını açar.

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

Ayarları ve GatewayClass'ı kontrol edin:

```bash
cilium config view | grep -E 'kube-proxy-replacement|enable-l2-announcements|enable-gateway-api '
```
```bash
kubectl get gatewayclass
```

Üç ayar da `true` değerindedir ve `cilium` GatewayClass'ı `ACCEPTED` `True` gösterir:
Cilium operator bu sınıfın sahipliğini almıştır.
