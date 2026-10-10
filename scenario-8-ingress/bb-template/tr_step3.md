### Ingress ile Uygulama Yayınlama

#### Adım 3 — LB-IPAM ile Harici Bir IP Atayın

LB-IPAM, `LoadBalancer` Service'lerine bir `CiliumLoadBalancerIPPool` içinden IP verir.
Bu IP'ye bu makineden erişilebilmelidir; bu yüzden havuz, kind düğümlerinin bağlı olduğu
**`kind` Docker ağının alt ağı içinde** olmalıdır. Kontrol edin:

```bash
docker network inspect kind | grep Subnet
```

IPv4 alt ağı genellikle `172.18.0.0/16`'dır. Bu alt ağın sonundan, Docker'ın düğümlere
verdiği IP'lerden (`172.18.0.2`, `172.18.0.3`, ...) uzak 8 adreslik bir havuz oluşturun:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumLoadBalancerIPPool
metadata:
  name: pool
spec:
  blocks:
    - cidr: 172.18.255.200/29
EOF
```

> **Not:** IPv4 alt ağınız farklıysa, örneğin `172.19.0.0/16`, yukarıdaki komutta kendi
> alt ağınızdaki aynı aralığı (`172.19.255.200/29`) kullanın.

Service, havuzdan hemen bir IP alır:

```bash
kubectl get svc cilium-ingress-basic-ingress
kubectl get ingress basic-ingress
```

Service'in `EXTERNAL-IP` değeri ile Ingress'in `ADDRESS` değeri aynı IP'yi gösterir;
örneğin `172.18.255.200`. Bu IP'yi bir değişkene kaydedin:

```bash
INGRESS_IP=$(kubectl get ingress basic-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo $INGRESS_IP
```

Service'in artık bir IP'si var, ancak **ağda henüz hiçbir makine bu IP'yi
sahiplenmiyor**. Bu makine bir ARP isteği ("bu IP kimde?") gönderdiğinde kimse cevap
vermez; bu yüzden `curl` IP'ye ulaşamaz. Bir sonraki adım bunu düzeltir.
