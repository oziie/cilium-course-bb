### eBPF ile Cilium'un Perde Arkası

#### Adım 2 — Hook'lara Bağlı Programlar

İnceleyeceğiniz bir şey oluşturun: `kind-worker2` üzerinde iki replikalı bir `nginx`
Deployment'ı, `nginx` adlı bir ClusterIP Service ve `kind-worker` üzerinde bir `client`
pod'u:

```bash
kubectl apply -f - <<EOF
apiVersion: apps/v1
kind: Deployment
metadata:
  name: nginx
spec:
  replicas: 2
  selector:
    matchLabels:
      app: nginx
  template:
    metadata:
      labels:
        app: nginx
    spec:
      nodeSelector:
        kubernetes.io/hostname: kind-worker2
      containers:
        - name: nginx
          image: nginx
---
apiVersion: v1
kind: Service
metadata:
  name: nginx
spec:
  selector:
    app: nginx
  ports:
    - protocol: TCP
      port: 80
      targetPort: 80
---
apiVersion: v1
kind: Pod
metadata:
  name: client
  labels:
    app: client
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
kubectl wait --for=condition=Ready pod -l app=nginx --timeout=120s
```
```bash
kubectl wait --for=condition=Ready pod/client --timeout=120s
```
```bash
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

Son komut `200` yazdırır.

Cilium agent imajında, eBPF için standart Linux aracı olan `bpftool` ve Cilium'un kendi
hata ayıklama CLI'ı olan `cilium-dbg` bulunur. Her worker'daki agent pod'unun adını
kaydedin:

```bash
AGENT1=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
```
```bash
AGENT2=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker2 -o name)
```

Agent, düğümün ağ namespace'inde çalışır; bu yüzden oradaki `bpftool` düğümün
arayüzlerini görür. `kind-worker2` üzerinde arayüzlere bağlı eBPF programlarını
listeleyin:

```bash
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- bpftool net show
```

Her satır, bir arayüzdeki bir hook'a bağlı bir programdır; örneğin
`lxc4b1e2c9a7d10(9) tcx/ingress cil_from_container`. Eski çekirdeklerde hook,
`tcx/ingress` yerine `clsact/ingress` olarak görünür.

| Arayüz | Program | Ne zaman çalışır |
| --- | --- | --- |
| `lxc...` | `cil_from_container` | bir paket pod'dan çıktığında (her pod için bir `lxc` arayüzü) |
| `eth0` | `cil_from_netdev` / `cil_to_netdev` | bir paket düğüme girdiğinde / düğümden çıktığında |
| `cilium_vxlan` | `cil_from_overlay` / `cil_to_overlay` | bir paket başka bir düğümden tünelle geldiğinde / tünele girdiğinde |
| `cilium_host` | `cil_to_host` / `cil_from_host` | bir paket düğümün kendisine gittiğinde / ondan geldiğinde |

Çekirdek bu programları kabul etmeden önce **verifier** (doğrulayıcı), her birinin
mutlaka sonlandığını ve yalnızca izin verilen belleğe eriştiğini kontrol etti; böylece
bir hata çekirdeği çökertemez. Ardından çekirdek onları **JIT** ile makine koduna
derledi, bu sayede neredeyse yerel hızda çalışırlar.

Her pod'un kendi programı olan kendi `lxc` arayüzü vardır. Cilium her pod'a
**endpoint** der. Endpoint'leri pod'larla eşleştirin:

```bash
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg endpoint list
```

İki `nginx` pod'u IP'leri ve etiketleriyle listelenir. `client` pod'u burada yoktur:
`kind-worker` üzerinde çalışır ve programı orada bağlıdır.
