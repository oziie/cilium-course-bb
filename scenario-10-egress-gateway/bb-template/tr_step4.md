### Egress Gateway ile Sabit Çıkış IP'si

#### Adım 4 — Perde Arkası ve Gateway Ortadan Kalkınca Ne Olur?

Cilium agent'ları politikayı bir eBPF map'indeki kayıtlara dönüştürür. `payments`
pod'unun çalıştığı `kind-worker` üzerindeki map'e bakın:

```bash
CILIUM_POD=$(kubectl -n kube-system get pod -l k8s-app=cilium --field-selector spec.nodeName=kind-worker -o name)
kubectl -n kube-system exec $CILIUM_POD -c cilium-agent -- cilium-dbg bpf egress list
```

Tek bir kayıt vardır: `Source IP` `payments` pod'unun IP'si, `Destination CIDR`
`0.0.0.0/0` ve `Gateway IP` kind-worker2'nin IP'sidir. Bu pod'dan eşleşen bir hedefe
giden her paket gateway'e iletilir. `Egress IP` yalnızca paketin gerçekten maskelendiği
gateway düğümünün kendisinde dolu görünür. Seçilen her pod kendi kaydını alır; bir
uygulamayı daha fazla pod'a ölçeklerseniz map de onunla birlikte büyür.

Şimdi etiketi kaldırın, böylece politikayla **hiçbir düğüm** eşleşmesin:

```bash
kubectl label node kind-worker2 egress-gateway-
kubectl exec payments -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
kubectl exec catalog -- curl -s --max-time 5 http://$EXTERNAL_IP | grep RemoteAddr
```

`payments` cevap alamaz (istek zaman aşımına uğrar), `catalog` ise çalışmaya devam eder.
Cilium seçilen trafiğin yanlış IP ile çıkmasına izin vermek yerine onu **düşürür**
(drop). Harici güvenlik duvarı o IP'yi zaten reddederdi; kapalı kalarak hata vermek
(fail closed) sorunu kolayca görünür kılar.

Etiketi geri ekleyin; `payments` yeniden `kind-worker2` üzerinden çıkar:

```bash
kubectl label node kind-worker2 egress-gateway=true
kubectl exec payments -- curl -s http://$EXTERNAL_IP | grep RemoteAddr
```

Uygulamayı, pod'u veya düğümünü değiştirmeden bir uygulamaya sabit ve öngörülebilir bir
kaynak IP verdiniz. Trafiğin hangi düğümden çıkacağına yalnızca bir etiket ve bir
politika karar verdi.
