### eBPF Under the Hood

#### Step 1 — What is eBPF? Create the Cluster

**eBPF** lets you run small, safe programs inside the Linux kernel, triggered by events
such as a packet arriving on a network interface, without changing the kernel or
loading a kernel module. Cilium uses it to forward, load-balance and secure traffic
right where packets pass through the kernel, instead of in long iptables chains.

Every earlier scenario used eBPF without showing it. In this scenario you look at the
three building blocks Cilium is made of:

1. **Programs attached to hooks**: the code that runs for every packet (Step 2).
2. **Maps**: key/value stores in the kernel that hold the data the programs need, such
   as Services and policies (Step 3).
3. **Events**: messages the programs send to user space, for example when they drop a
   packet (Step 4).

```
 user space   cilium-agent                 cilium-dbg monitor / Hubble
                   │ writes                            ▲
 ──────────────────┼───────────────────────────────────┼─────────────
 kernel            ▼                                   │ events
              ┌─────────┐   lookup    ┌─────────┐      │
              │  maps   │◀────────────│ program │──────┘
              └─────────┘             └────▲────┘
                                           │ runs on
             packet ──▶ hook (lxc / eth0 / cilium_vxlan)
```

This scenario uses a cluster **without kube-proxy**, so Services are handled by eBPF
only. Delete any previous cluster, then create the new one:

```bash
kind delete cluster --name kind
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
kind create cluster --config light-lab.yaml
```

Write the Cilium settings to a values file. They are the Scenario 1 settings plus
`kubeProxyReplacement: true`:

```bash
cat > cilium-values.yaml <<EOF
operator:
  replicas: 1
routingMode: tunnel
tunnelProtocol: vxlan
ipam:
  mode: kubernetes
kubeProxyReplacement: true
EOF
```

Install Cilium and wait until it is ready:

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --set cluster.name=kind-kind \
  --set k8sServiceHost=kind-control-plane \
  --set k8sServicePort=6443 \
  -f cilium-values.yaml
cilium status --wait
cilium config view | grep 'kube-proxy-replacement '
```

`kube-proxy-replacement` is `true`: from now on, eBPF does the work kube-proxy used to do.
