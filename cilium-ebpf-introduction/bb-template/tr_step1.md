### Cilium ve eBPF'e Giriş

Bu giriş, uygulamalı senaryolara başlamadan önce kursun arkasındaki fikirleri açıklar:
Kubernetes'in neden bir ağ eklentisine ihtiyaç duyduğunu, ağ eklentilerinin
iptables'tan eBPF'e nasıl geçtiğini, Cilium'un ne olduğunu ve ne zaman doğru seçim
olduğunu.

#### CNI Nedir? Neden İhtiyaç Duyarız?

Kubernetes ve container kullanımı yaygınlaştıkça bir gerçek açıkça ortaya çıktı:
altta yatan hesaplama platformu ne olursa olsun, iş yüklerinin temel ağ ve güvenlik
gereksinimleri aynıdır. İster bare metal, ister sanal makineler (VM), ister
container'lar üzerinde çalıştırın, uygulamalarınızdan şunları beklersiniz:

- Erişilebilir IP adreslerine sahip olmak
- Diğer uygulamalarla iletişim kurabilmek
- Dışarıya erişim gerektiğinde dış dünyaya ulaşabilmek
- İçeriden erişim gerektiğinde dış dünyadan ulaşılabilir olmak
- Güvenli olmak; verilerin aktarım sırasında ve depolanırken korunması
- Küresel ölçekte dayanıklı ve yüksek erişilebilir kalmak
- Yasal hedefleri ve uyumluluk gereksinimlerini karşılamak
- Bir şeyler ters gittiğinde işletmek ve sorun gidermek için gereken görünürlüğü
  sağlamak

Kubernetes ağın **nasıl görünmesi gerektiğini** tanımlar, ama ağı kendisi kurmaz. Ağ
modeli üç basit kuraldan oluşur:

1. Her pod'un **kendi IP adresi** vardır.
2. Her pod, hangi düğümde olursa olsun diğer tüm pod'lara **NAT olmadan** ulaşabilir.
3. Bir düğümdeki agent'lar (örneğin kubelet) o düğümdeki tüm pod'lara ulaşabilir.

Bu kuralları hayata geçirme işi bir eklentiye bırakılır. **CNI (Container Network
Interface)**, Kubernetes ile bu eklenti arasındaki standart sözleşmedir. Küçük bir
CNCF spesifikasyonudur: bir pod başladığında container runtime eklentiyi `ADD`
komutuyla, pod silindiğinde ise `DEL` komutuyla çağırır. Gerisi tamamen eklentiye
kalmıştır.

![Bir pod başladığında CNI eklentisinin yaptıkları](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/01-cni-overview-tr.png)

Çağrıldığında CNI eklentisi:

1. pod'un **ağ arayüzünü** oluşturur; bu genellikle pod'u düğüme bağlayan bir `veth`
   çiftidir,
2. pod'a bir **IP adresi** verir (IP Address Management, IPAM),
3. pod'un diğer pod'lara, Service'lere ve dış dünyaya (başka düğümlerdekiler dahil)
   ulaşabilmesi için **rotaları ve veri yolunu (datapath)** kurar.

CNI eklentisi olmadan pod'lar IP adresi alamaz. Bu yüzden yeni bir kümenin düğümleri,
Senaryo 1'de göreceğiniz gibi, bir CNI kurulana kadar `NotReady` durumunda kalır.
Flannel, Calico, Cilium ve bulut sağlayıcılarının eklentileri (AWS VPC CNI, Azure CNI)
birer CNI eklentisidir. Hepsi aynı sözleşmeye uyar, ancak veri yolunu çok farklı
şekillerde kurarlar.

#### CNI'ların Modern Veri Yollarına Evrimi

Kubernetes ağının ilk nesli, Linux'ta zaten var olan araçlarla kuruldu:

- pod'ları düğümler arasında bağlamak için **Linux bridge'leri ve rotalar** ya da bir
  **overlay** (VXLAN gibi),
- Service'ler için **iptables** kuralları: `kube-proxy`, bir Service IP'sini bir pod
  IP'sine çevirmek için her düğüme bir kural zinciri yazar,
- ağ politikaları için yine **iptables** kuralları.

iptables, Kubernetes'ten çok önce, oldukça sabit bir kural listesi düşünülerek host
güvenlik duvarları için tasarlandı. Kubernetes ise tam tersidir: pod'lar her saniye
gelip gider ve IP'leri sürekli değişir. Ölçek büyüdükçe bu kendini gösterir:

- Kurallar **tek tek** kontrol edilir. Ne kadar çok Service ve politika varsa, her paket
  için yol o kadar uzar.
- Bir değişiklik çoğu zaman **büyük kural tablolarını yeniden yazmak** demektir ve küme
  büyüdükçe bu işlem yavaşlar.
- Kurallar **IP adreslerine** göre eşleşir; IP ise sürekli değiştirilen pod'ları
  tanımlamak için zayıf bir yoldur.
- **Görünürlük** azdır: bir paketi hangi kuralın, neden düşürdüğünü anlamak zordur.

![iptables zincirlerinden eBPF veri yoluna](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/02-datapath-evolution-tr.png)

Modern veri yolları bu zincirleri **eBPF** programları ve hash tablosu aramalarıyla
değiştirir; bu aramaların maliyeti kümede 10 Service de olsa 10.000 Service de olsa
aynıdır.

##### eBPF Nedir?

**eBPF**, çekirdeğin kaynak kodunu değiştirmeden veya bir çekirdek modülü yüklemeden,
**Linux çekirdeğinin içinde** küçük ve izole (sandbox) programlar çalıştırmanızı sağlar.
Programlar bir olay gerçekleştiğinde çalışır; örneğin bir ağ arayüzüne paket
geldiğinde, bir süreç sistem çağrısı yaptığında veya bir çekirdek fonksiyonu
çağrıldığında. Sık kullanılan bir benzetmeyle: eBPF, Linux çekirdeği için JavaScript'in
bir web sayfası için yaptığını yapar. Çekirdeği güvenli bir şekilde ve çalışma anında
programlanabilir hale getirir.

Adı, 1992'de ortaya çıkan ve `tcpdump`'ın arkasındaki paket filtresi olan **Berkeley
Packet Filter**'dan (BPF) gelir. **Genişletilmiş** BPF (extended BPF, eBPF) 2014'te
Linux'a eklendi ve bu küçük filtreyi çekirdeğin içinde genel amaçlı bir motora
dönüştürdü.

![Bir eBPF programı çekirdeğe nasıl girer ve nasıl çalışır](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/03-ebpf-how-it-works-tr.png)

Temel yapı taşları:

| Yapı taşı | Ne yapar |
| --- | --- |
| **Program** | kısıtlı C ile yazılan ve eBPF bytecode'una derlenen küçük bir fonksiyon |
| **Verifier (doğrulayıcı)** | programı yüklemeden önce kontrol eder: program mutlaka sonlanmalı ve yalnızca izin verilen belleğe erişmelidir. Çekirdeği çökertebilecek bir program reddedilir. |
| **JIT derleyici** | bytecode'u yerel makine koduna çevirir, böylece program neredeyse yerel hızda çalışır |
| **Hook** | programı çalıştıran olay: bir ağ arayüzü (XDP, tc), bir soket, bir sistem çağrısı, bir kprobe veya tracepoint |
| **Map** | çekirdekte, programlar ve kullanıcı alanı uygulamaları arasında paylaşılan anahtar/değer deposu. Programlar durumlarını ve ayarlarını burada tutar. |
| **Olaylar (events)** | programlar bir ring buffer üzerinden kullanıcı alanına mesaj gönderir; gözlemlenebilirlik için kullanılır |

Programlar ve map'ler ayrı olduğu için Cilium gibi bir uygulama, programları yeniden
yüklemeden veya hiçbir şeyi yeniden başlatmadan, yalnızca **map kayıtlarını
güncelleyerek** veri yolunun davranışını değiştirebilir. Senaryo 11 bunu canlı olarak
gösterir.

eBPF, Kubernetes ağının çok ötesinde kullanılır: Meta'nın Katran yük dengeleyicisi,
Netflix'in performans izleme araçları, Falco ve Tetragon gibi güvenlik araçları ve
Google'ın GKE Dataplane V2'si (Cilium üzerine kuruludur) eBPF'e dayanır.

eBPF'in kökenlerini daha iyi anlamak için *eBPF: Unlocking the Kernel* adlı etkileyici
belgeseli izlemenizi şiddetle tavsiye ederiz. eBPF'in 10. yıl dönümünü kutlamak için
2024'te yayınlanan bu belgesel, küçük bir çekirdek mühendisi grubunun bugün modern ağ,
güvenlik ve gözlemlenebilirliğin kalbinde yer alan bir teknolojiyi nasıl yarattığına
dair öğretici bir bakış sunuyor.
<https://isovalent.com/blog/post/ebpf-documentary-creation-story/>

#### Cilium Nedir? Neden Cilium?

**Cilium**, Kubernetes için eBPF üzerine kurulu, açık kaynaklı bir ağ, güvenlik ve
gözlemlenebilirlik platformudur. Bir CNI eklentisi olarak başladı ve hâlâ öyledir, ama
bugün çok daha fazlasını kapsar: Service yük dengeleme, Ingress ve Gateway API,
Katman 7'ye kadar ağ politikaları, şifreleme, çoklu küme ağı ve **Hubble** ile derin
gözlemlenebilirlik. Cilium, Isovalent (artık Cisco'nun bir parçası) tarafından
geliştirildi ve Cloud Native Computing Foundation'ın (CNCF) **graduated** (mezun)
seviyesindeki bir projesidir; bu, Kubernetes'in kendisiyle aynı olgunluk seviyesidir.

##### Nasıl Çalışır?

![Cilium mimarisi](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/04-cilium-architecture-tr.png)

| Bileşen | Nasıl çalışır | Görevi |
| --- | --- | --- |
| `cilium-agent` | DaemonSet, düğüm başına bir tane | Kubernetes API'sini izler, eBPF programlarını derleyip yükler, map'leri güncel tutar. Hubble sunucusunu da içerir. |
| `cilium-operator` | Deployment | küme genelindeki işler: IP adres havuzları, CRD'ler, eskimiş durumun temizlenmesi |
| `cilium-cni` | her düğümdeki bir binary | bir pod başladığında veya durduğunda kubelet tarafından çağrılır; işi agent'a devreder |
| `cilium-envoy` | DaemonSet | Katman 7 işleri için Envoy proxy: HTTP politikaları, Ingress, Gateway API |
| Hubble Relay / UI | Deployment'lar | her düğümden akış olaylarını toplar ve CLI'da veya bir web arayüzünde gösterir |

Bir paketin bir pod'dan diğerine yolculuğu, parçaların birlikte nasıl çalıştığını
gösterir:

1. Pod bir paket gönderir. Pod'un `lxc` arayüzündeki eBPF programı çalışır.
2. Hedef bir Service IP'si ise program **Service map'ine** bakar ve bir backend pod
   seçer. iptables yok, kube-proxy yok.
3. Hedefin **güvenlik kimliğine** (security identity) bakar ve **politika map'ini**
   kontrol eder. Cilium pod'ları IP'lerine göre değil, etiketlerine göre tanır.
4. Paket iletilir: doğrudan yerel bir pod'a ya da tünel (veya native routing) üzerinden
   başka bir düğüme; orada alıcı tarafta aynı kontroller tekrar çalışır.
5. Her adımda programlar bir **olay** gönderebilir; Hubble bunu inceleyebileceğiniz bir
   akışa (flow) dönüştürür.

`cilium-agent`'ın kendisi hiçbir zaman paket yolunda değildir. Yalnızca çekirdeği
programlar; işi çekirdek yapar.

##### Neden Cilium?

- **Ölçekte performans:** uzun kural zincirleri yerine hash tablosu aramaları ve
  eksiksiz bir **kube-proxy replacement**.
- **Kimlik tabanlı güvenlik:** politikalar etiketleri takip eder; böylece pod'lar
  değiştirilip IP'ler değişirken de çalışmaya devam eder.
- **Katman 7 farkındalığı:** yalnızca IP ve port değil; `GET /public`'e izin verip
  `DELETE /admin`'i engellemek ya da yalnızca belirli DNS adlarına izin vermek.
- **Yerleşik görünürlük:** Hubble her akışı, kimlikleriyle ve her düşürmenin (drop) tam
  nedeniyle gösterir.
- **Birçok araç yerine tek platform:** CNI, yük dengeleyici, Ingress ve Gateway API,
  egress gateway, şifreleme ve çoklu küme ağı tek bir projeden.
- **Uygulamalarda değişiklik yok** ve sidecar yok: her şey çekirdekte ve düğüm
  seviyesindeki proxy'de gerçekleşir.
- **Yaygın kullanım:** Cilium, GKE Dataplane V2'ye ve AKS'teki Azure CNI Powered by
  Cilium'a güç verir ve EKS Anywhere'in varsayılan CNI'ıdır.

#### Cilium Kullanım Alanları

![Cilium ne için kullanılır](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/05-cilium-use-cases-tr.png)

##### Cilium'u Ne Zaman Seçmelisiniz?

Aşağıdakilerden biri veya birkaçı geçerliyse Cilium iyi bir seçimdir:

- **Kümeniz büyük veya yoğun:** çok sayıda Service, çok sayıda pod, sık değişiklik. eBPF
  aramaları, iptables'ın yavaşladığı yerde veri yolunu hızlı tutar.
- **Zero-trust veya uyumluluk kontrollerine ihtiyacınız var:** varsayılan olarak
  reddeden (default-deny) politikalar, kimlik tabanlı kurallar, Katman 7 ve DNS
  farkındalıklı politikalar, düğümler arası şifreleme.
- **Ağ sorunlarını gidermeniz gerekiyor:** Hubble, ek agent'lara veya paket
  yakalamalarına gerek kalmadan "kim kiminle konuştu ve buna izin verildi mi?" sorusunu
  cevaplar.
- **Daha az hareketli parça istiyorsunuz:** kube-proxy'yi, ayrı bir yük dengeleyiciyi
  (MetalLB gibi) ve bir ingress controller'ı tek bir projeyle değiştirin.
- **Küme dışında IP'ye göre filtreleme yapan sistemlerle konuşuyorsunuz:** bir egress
  gateway, seçilen pod'lara sabit bir kaynak IP verir.
- **Birden fazla küme çalıştırıyorsunuz:** Cluster Mesh, pod'ları ve Service'leri
  kümeler arasında birbirine bağlar.

Varsayılan CNI'ın yeterli olduğu küçük ve kısa ömürlü bir test kümesi için Cilium
ihtiyacınızdan fazlası olabilir. Cilium ayrıca oldukça güncel bir Linux çekirdeği
gerektirir (güncel sürümler için 5.10 veya üstü); bu, bugünkü dağıtımlarda nadiren
sorun olur.

##### Kursun Devamında

| Modül | Senaryolar | Öğrenecekleriniz |
| --- | --- | --- |
| Temeller | 1 | Cilium'u kurmak ve bileşenlerini kontrol etmek |
| Bağlantı | 2, 3 | pod'dan pod'a ve pod'dan Service'e trafik |
| Ağ Politikaları | 4, 5 | L3/L4 ve L7 (HTTP) politikaları |
| Gözlemlenebilirlik | 6 | Hubble CLI ve UI |
| IP Adres Yönetimi | 7 | Cilium'un cluster-scope IPAM'i |
| Uygulamaları Dışarıya Açma | 8, 9 | Ingress ve Gateway API |
| Egress Trafiği | 10 | Egress Gateway |
| eBPF İç Yapısı | 11 | Cilium'un içindeki programlar, map'ler ve olaylar |
