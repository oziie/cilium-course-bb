### Cilium & eBPF Introduction

This introduction explains the ideas behind the course before you start the hands-on
scenarios: why Kubernetes needs a network plugin, how network plugins moved from
iptables to eBPF, what Cilium is, and when it is the right choice.

#### What is CNI? Why do we need it?

As use of Kubernetes and containerization spread, one reality became obvious:
regardless of the underlying computing platform, workloads have the same basic network
and security requirements. Whether you run them on bare metal, virtual machines (VMs),
or containers, you expect your applications to:

- Have accessible IP addresses
- Be able to communicate with other applications
- Be able to reach the outside world when they need outbound access
- Be reachable from the outside world when inbound access is required
- Be secured, with data protected in transit and at rest
- Remain resilient and highly available on a global scale
- Meet regulatory goals and compliance requirements
- Provide the visibility you need to operate and troubleshoot when things go wrong

Kubernetes defines **what** the network must look like, but it does not build the
network itself. Its network model has three simple rules:

1. Every pod gets its **own IP address**.
2. Every pod can reach every other pod, on any node, **without NAT**.
3. Agents on a node (such as the kubelet) can reach every pod on that node.

The job of making these rules true is handed to a plugin. **CNI (Container Network
Interface)** is the standard contract between Kubernetes and that plugin. It is a small
CNCF specification: when a pod starts, the container runtime calls the plugin with an
`ADD` command, and when the pod is deleted, with `DEL`. Everything else is up to the
plugin.

![What a CNI plugin does when a pod starts](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/01-cni-overview.png)

When it is called, the CNI plugin:

1. creates the pod's **network interface**, usually a `veth` pair that connects the pod
   to the node,
2. gives the pod an **IP address** (IP Address Management, IPAM),
3. sets up the **routes and datapath** so the pod can reach other pods, Services and
   the outside world, also on other nodes.

Without a CNI plugin, pods cannot get an IP address. That is why the nodes of a new
cluster stay `NotReady` until a CNI is installed, as you will see in Scenario 1.
Flannel, Calico, Cilium and the plugins of cloud providers (AWS VPC CNI, Azure CNI) are
all CNI plugins. They follow the same contract, but they build the datapath in very
different ways.

#### Evolution of CNIs to Modern Datapaths

The first generation of Kubernetes networking was built from tools that already existed
in Linux:

- **Linux bridges and routes**, or an **overlay** (such as VXLAN) to connect pods across
  nodes,
- **iptables** rules for Services: `kube-proxy` writes a chain of rules on every node to
  translate a Service IP to a pod IP,
- **iptables** rules for network policies.

iptables was designed for host firewalls, long before Kubernetes, with a fairly static
list of rules in mind. Kubernetes is the opposite: pods come and go every second, and
their IPs change all the time. At scale this shows:

- Rules are checked **one by one**. The more Services and policies you have, the longer
  the path for every packet.
- A change often means **rewriting large rule tables**, which gets slower as the cluster
  grows.
- Rules match **IP addresses**, which are a poor way to identify pods that are
  constantly replaced.
- There is little **visibility**: it is hard to tell which rule dropped a packet and why.

![From iptables chains to an eBPF datapath](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/02-datapath-evolution.png)

Modern datapaths replace these chains with **eBPF** programs and hash-table lookups,
which cost the same whether a cluster has 10 Services or 10,000.

##### What is eBPF?

**eBPF** lets you run small, sandboxed programs **inside the Linux kernel**, without
changing the kernel's source code or loading a kernel module. The programs run when an
event happens, for example when a packet arrives on a network interface, when a process
makes a system call, or when a kernel function is called. A common way to put it: eBPF
does for the Linux kernel what JavaScript does for a web page. It makes the kernel
programmable, safely and at run time.

The name comes from the **Berkeley Packet Filter** (BPF) from 1992, the packet filter
behind `tcpdump`. The **extended** BPF (eBPF) was merged into Linux in 2014 and turned
that small filter into a general-purpose engine inside the kernel.

![How an eBPF program gets into the kernel and runs](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/03-ebpf-how-it-works.png)

The main building blocks:

| Building block | What it does |
| --- | --- |
| **Program** | a small function, written in restricted C and compiled to eBPF bytecode |
| **Verifier** | checks the program before it is loaded: it must always finish and may only access memory it is allowed to. A program that could crash the kernel is rejected. |
| **JIT compiler** | turns the bytecode into native machine code, so it runs at close to native speed |
| **Hook** | the event that runs the program: a network interface (XDP, tc), a socket, a system call, a kprobe or tracepoint |
| **Map** | a key/value store in the kernel, shared between programs and user-space applications. Programs keep their state and configuration here. |
| **Events** | programs send messages to user space through a ring buffer, used for observability |

Because programs and maps are separate, an application such as Cilium can change the
behaviour of the datapath by **updating map entries**, without reloading programs or
restarting anything. Scenario 11 shows this live.

eBPF is used far beyond Kubernetes networking: Meta's Katran load balancer, Netflix's
performance tracing tools, security tools such as Falco and Tetragon, and Google's GKE
Dataplane V2 (built on Cilium) all rely on it.

To better understand the origins of eBPF, we highly recommend watching the fascinating
documentary *eBPF: Unlocking the Kernel*. Released in 2024 to celebrate eBPF's 10th
anniversary, it is an insightful look at how a small group of kernel engineers created a
technology that is now at the heart of modern networking, security, and observability.
<https://isovalent.com/blog/post/ebpf-documentary-creation-story/>

#### What's Cilium? Why Cilium?

**Cilium** is an open-source networking, security and observability platform for
Kubernetes, built on eBPF. It started as a CNI plugin, and it still is one, but today it
covers much more: Service load balancing, Ingress and Gateway API, network policies up
to Layer 7, encryption, multi-cluster networking and deep observability with **Hubble**.
Cilium was created by Isovalent (now part of Cisco) and is a **graduated** project of the
Cloud Native Computing Foundation (CNCF), the same maturity level as Kubernetes itself.

##### How it works

![Cilium architecture](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/04-cilium-architecture.png)

| Component | Runs as | Role |
| --- | --- | --- |
| `cilium-agent` | DaemonSet, one per node | watches the Kubernetes API, compiles and loads the eBPF programs, keeps the maps up to date. Includes the Hubble server. |
| `cilium-operator` | Deployment | cluster-wide tasks: IP address pools, CRDs, cleaning up stale state |
| `cilium-cni` | binary on each node | called by the kubelet when a pod starts or stops; hands the work to the agent |
| `cilium-envoy` | DaemonSet | Envoy proxy for Layer 7 work: HTTP policies, Ingress, Gateway API |
| Hubble Relay / UI | Deployments | collect flow events from every node and show them in the CLI or a web UI |

The path of a packet from one pod to another shows how the pieces work together:

1. The pod sends a packet. The eBPF program on the pod's `lxc` interface runs.
2. If the destination is a Service IP, the program looks up the **Service map** and
   picks a backend pod. No iptables, no kube-proxy.
3. It looks up the **security identity** of the destination and checks the **policy
   map**. Cilium identifies pods by their labels, not by their IPs.
4. The packet is forwarded: directly to a local pod, or through the tunnel (or native
   routing) to another node, where the same checks run on the receiving side.
5. At every step the programs can send an **event** that Hubble turns into a flow you
   can inspect.

The `cilium-agent` itself is never in the packet path. It only programs the kernel; the
kernel does the work.

##### Why Cilium

- **Performance at scale:** hash-table lookups instead of long rule chains, and a full
  **kube-proxy replacement**.
- **Identity-based security:** policies follow labels, so they keep working while pods
  are replaced and IPs change.
- **Layer 7 awareness:** allow `GET /public` but not `DELETE /admin`, or only specific
  DNS names, not just IPs and ports.
- **Visibility built in:** Hubble shows every flow, with identities and the exact reason
  for every drop.
- **One platform instead of many tools:** CNI, load balancer, Ingress and Gateway API,
  egress gateway, encryption and multi-cluster networking from a single project.
- **No changes to applications** and no sidecars: everything happens in the kernel and
  the node-level proxy.
- **Widely adopted:** Cilium powers GKE Dataplane V2 and Azure CNI Powered by Cilium on
  AKS, and is the default CNI in EKS Anywhere.

#### Cilium Use Cases

![What Cilium is used for](https://raw.githubusercontent.com/oziie/cilium-course-bb/main/img/05-cilium-use-cases.png)

##### When should you pick Cilium?

Cilium is a good choice when one or more of these is true:

- **Your cluster is large or busy:** many Services, many pods, frequent changes. eBPF
  lookups keep the datapath fast where iptables slows down.
- **You need zero-trust or compliance controls:** default-deny policies, identity-based
  rules, Layer 7 and DNS-aware policies, encryption between nodes.
- **You need to troubleshoot the network:** Hubble answers "who talked to whom, and was
  it allowed?" without extra agents or packet captures.
- **You want fewer moving parts:** replace kube-proxy, a separate load balancer (such as
  MetalLB) and an ingress controller with one project.
- **You talk to systems outside the cluster that filter by IP:** an egress gateway gives
  selected pods a fixed source IP.
- **You run more than one cluster:** Cluster Mesh connects pods and Services across
  clusters.

It may be more than you need for a small, short-lived test cluster where the default
CNI is enough. Cilium also needs a reasonably recent Linux kernel (5.10 or newer for
current releases), which is rarely a problem on today's distributions.

##### Where this course goes next

| Module | Scenarios | You will learn |
| --- | --- | --- |
| Foundations | 1 | install Cilium and check its components |
| Connectivity | 2, 3 | pod-to-pod and pod-to-Service traffic |
| Network Policy | 4, 5 | L3/L4 and L7 (HTTP) policies |
| Observability | 6 | Hubble CLI and UI |
| IP Address Management | 7 | Cilium's cluster-scope IPAM |
| Exposing Applications | 8, 9 | Ingress and Gateway API |
| Egress Traffic | 10 | Egress Gateway |
| eBPF Internals | 11 | programs, maps and events inside Cilium |
