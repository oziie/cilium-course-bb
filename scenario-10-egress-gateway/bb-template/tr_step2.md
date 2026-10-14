### Egress Gateway ile Sabit Çıkış IP'si

#### Adım 2 — Harici Bir Sunucu Başlatın ve Varsayılan Kaynak IP'yi Görün

Küme **dışında**, bir isteğin hangi IP'den geldiğini gösteren bir şeye ihtiyacınız var.
`traefik/whoami`, her isteğe o istekle ilgili bilgilerle cevap veren küçük bir web
sunucusudur. Bu bilgiler arasında çağıranın IP'si ve portu olan `RemoteAddr` de bulunur.

Sunucuyu `kind` ağında sıradan bir Docker container'ı olarak çalıştırın. kind
düğümlerinin yanında durur ama kümenin parçası değildir, tıpkı ağınızdaki bir
partnerin sunucusu gibi:

```bash
docker run -d --name external-server --network kind traefik/whoami
```
```bash
EXTERNAL_IP=$(docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' external-server)
echo $EXTERNAL_IP
```

Sunucunun cevaplarında tanıyabilmek için her düğümün `INTERNAL-IP` değerini not edin:

```bash
kubectl get nodes -o wide
```

Genellikle `kind-control-plane` `172.18.0.2`, `kind-worker` `172.18.0.3` ve
`kind-worker2` `172.18.0.4` olur, ancak sıra farklı olabilir. Aşağıda kendi
değerlerinizi kullanın.

İkisi de `kind-worker` üzerinde çalışan `payments` ve `catalog` adlı iki istemci pod'u
oluşturun:

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: payments
  labels:
    app: payments
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
---
apiVersion: v1
kind: Pod
metadata:
  name: catalog
  labels:
    app: catalog
spec:
  nodeSelector:
    kubernetes.io/hostname: kind-worker
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "infinity"]
EOF
```
```bash
kubectl wait --for=condition=Ready pod/payments pod/catalog --timeout=120s
```
```bash
kubectl get pods -o wide
```

Harici sunucuyu iki pod'dan da çağırın:

```bash
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```
```bash
kubectl exec catalog -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

İki istek de pod IP'lerinden (`kubectl get pods -o wide` çıktısındaki `10.244.x.x`)
değil, **kind-worker**'ın IP'sinden gelir. Cilium trafiği pod'ların çalıştığı düğümde
maskeledi. `payments` pod'u `kind-worker2`'ye taşınsaydı, sunucu birden farklı bir IP
görürdü.
