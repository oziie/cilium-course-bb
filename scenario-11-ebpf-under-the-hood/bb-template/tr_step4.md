### eBPF ile Cilium'un Perde Arkası

#### Adım 4 — Map'lerdeki Politikalar ve Çekirdekten Gelen Olaylar

Bir ağ politikası da sonunda map kayıtlarına dönüşür. `nginx`'e 80 portundan yalnızca
`app=frontend` etiketli pod'ların erişmesine izin verin:

```bash
kubectl apply -f - <<EOF
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: allow-frontend-to-nginx
spec:
  endpointSelector:
    matchLabels:
      app: nginx
  ingress:
    - fromEndpoints:
        - matchLabels:
            app: frontend
      toPorts:
        - ports:
            - port: "80"
              protocol: TCP
EOF
```

`client` pod'unun etiketi `app=client` olduğu için artık engellenir. Ingress politikası
**hedef** pod'un düğümünde uygulanır; bu yüzden client tekrar denerken `kind-worker2`
üzerindeki drop **olaylarını** izleyin. `timeout 15` izlemeyi 15 saniye sonra durdurur,
`&` ise onu arka planda çalıştırır; böylece aynı terminalde `curl` kullanabilirsiniz:

```bash
timeout 15 kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg monitor --type drop &
sleep 3; kubectl exec client -- curl -s --max-time 3 http://nginx; wait
```

Şuna benzer satırlar görürsünüz:

```
xx drop (Policy denied) flow 0x0 to endpoint 1342, ifindex 9, file bpf_lxc.c:2112, , identity 21915->8429: 10.244.1.52:41030 -> 10.244.2.15:80 tcp SYN
```

- `Policy denied`: paketin neden düşürüldüğü.
- `file bpf_lxc.c`: paketi düşüren eBPF programı, yani nginx pod'unun önündeki program.
- `identity 21915->8429`: Cilium IP'leri karşılaştırmaz. Pod etiketlerinden türetilen
  sayılar olan **güvenlik kimliklerini** (security identity) karşılaştırır.

Program bu olayı bir ring buffer üzerinden kullanıcı alanına gönderdi. Hubble
(Senaryo 6) da aynı olayları okur.

Şimdi nginx pod'unun **politika map'ine** bakın. Her endpoint'in kendine ait bir map'i
vardır:

```bash
NGINX_POD=$(kubectl get pod -l app=nginx -o jsonpath='{.items[0].metadata.name}')
EP_ID=$(kubectl get ciliumendpoint $NGINX_POD -o jsonpath='{.status.id}')
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
```

Hiçbir pod için `Ingress` kaydı yoktur: henüz hiçbir pod `app=frontend` etiketine sahip
değil, dolayısıyla politikayla eşleşen bir kimlik yok. Client'a bu etiketi verin ve
tekrar kontrol edin:

```bash
kubectl label pod client app=frontend --overwrite
sleep 5
kubectl -n kube-system exec $AGENT2 -c cilium-agent -- cilium-dbg bpf policy get $EP_ID
kubectl exec client -- curl -s -o /dev/null -w "%{http_code}\n" http://nginx
```

- Client, yeni etiketleri için **yeni bir kimlik** aldı.
- Politika map'inde artık bu kimlik için `80/TCP` üzerinde bir `Allow` `Ingress` kaydı
  var (etiketler: `k8s:app=frontend ...`).
- `curl` yeniden `200` yazdırır.

Hiçbir program değişmedi ve hiçbir pod yeniden başlamadı. Agent map'e tek bir kayıt
yazdı ve sonraki paketin geçmesine izin verildi. Hook'lardaki programlar, map'lerdeki
veriler ve kullanıcı alanına giden olaylar: Cilium bu kursta yaptığınız her şey için
eBPF'i böyle kullanır.
