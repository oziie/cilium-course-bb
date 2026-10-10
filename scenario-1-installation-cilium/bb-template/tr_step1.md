### Cilium Kurulumu

#### Adım 1 — kind Kümesini Oluşturun

Bu senaryoda **Cilium**'u bir Kubernetes kümesinin ağ eklentisi (CNI) olarak
kuracaksınız. Önce **kind** (Kubernetes in Docker) ile yerel bir küme oluşturun: 1
control-plane ve 2 worker düğümü. İki worker düğümü, sonraki senaryolarda farklı
düğümlerdeki podlar arasındaki trafiği göstermeyi sağlar.

kind yapılandırma dosyasını oluşturun:

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
```

`disableDefaultCNI: true`, kind'ın varsayılan olarak kurduğu ağ eklentisi **kindnetd**'yi
kapatır; böylece pod ağını Cilium yönetebilir.

Kümeyi oluşturun (bir iki dakika sürer):

```bash
kind create cluster --config light-lab.yaml
```

Düğümleri ve podları kontrol edin:

```bash
kubectl get nodes
kubectl get pods -A
```

Düğümler `NotReady` durumunda, `coredns` ve `local-path-provisioner` podları ise
`Pending` durumundadır. Bu beklenen bir durumdur: kümede **henüz bir CNI yok**, bu yüzden
podlar ağ alamıyor. Bir sonraki adımda Cilium'u kurarak bunu düzelteceksiniz.
