### Gateway API ile Uygulama Yayınlama

#### Adım 2 — Bookinfo'yu Dağıtın ve Gateway'i Oluşturun

Senaryo 8'deki örnek uygulamanın aynısı olan
[Bookinfo](https://istio.io/latest/docs/examples/bookinfo/)'yu dağıtın:

```bash
kubectl apply -f https://raw.githubusercontent.com/istio/istio/release-1.24/samples/bookinfo/platform/kube/bookinfo.yaml
kubectl wait --for=condition=Ready pod --all --timeout=300s
```

Bir `Gateway` bir `LoadBalancer` Service'i alır; bu yüzden tıpkı Senaryo 8'deki Ingress
gibi harici bir IP'ye ihtiyaç duyar: `kind` Docker ağının içinde bir LB-IPAM havuzu ve
bir worker'ın bu IP için ARP isteklerine cevap vermesini sağlayan bir L2 duyuru
politikası. Alt ağı kontrol edin:

```bash
docker network inspect kind | grep Subnet
```

Genellikle `172.18.0.0/16`'dır. Havuzu ve politikayı oluşturun:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 172.18.255.200/29
---
apiVersion: cilium.io/v2alpha1
kind: CiliumL2AnnouncementPolicy
metadata:
  name: policy1
spec:
  loadBalancerIPs: true
  interfaces:
    - eth0
  nodeSelector:
    matchExpressions:
      - key: node-role.kubernetes.io/control-plane
        operator: DoesNotExist
EOF
```

> **Not:** IPv4 alt ağınız farklıysa, örneğin `172.19.0.0/16`, yukarıdaki komutta kendi
> alt ağınızdaki aynı aralığı (`172.19.255.200/29`) kullanın.

Şimdi **Gateway**'i oluşturun: `cilium` GatewayClass'ı tarafından uygulanan, 80
numaralı portta tek bir HTTP listener. Bu, platform ekibinin parçasıdır:

```bash
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: my-gateway
  namespace: default
spec:
  gatewayClassName: cilium
  listeners:
    - name: http
      protocol: HTTP
      port: 80
EOF
```

Cilium, `cilium-gateway-my-gateway` adında bir `LoadBalancer` Service'i oluşturur ve
LB-IPAM ona bir IP verir:

```bash
kubectl get gateway my-gateway
kubectl get svc cilium-gateway-my-gateway
```

Gateway, `ADDRESS` alanında aynı IP'yi ve `PROGRAMMED` `True` değerini gösterir. IP'yi
kaydedin:

```bash
GATEWAY_IP=$(kubectl get gateway my-gateway -o jsonpath='{.status.addresses[0].value}')
echo $GATEWAY_IP
```

Gateway'in henüz hiçbir route'u yok; bu yüzden her istek `404` döndürür:

```bash
curl -s -o /dev/null -w "%{http_code}\n" "http://$GATEWAY_IP/"
```
