# Cilium & eBPF — Bulut Bilisimciler Course

> This repository contains the hands-on lab scenarios for the **Cilium & eBPF** course published on the [Bulut Bilisimciler](https://bulutbilisimciler.com) internal learning platform.

## About the Course

This course provides a practical introduction to **Cilium** and **eBPF** in the context of Kubernetes networking. Learners will start from installation and progressively explore Cilium's core features — pod and service connectivity, network policy enforcement at L3/L4 and L7, and deep observability through Hubble.

By the end of the course, learners will be able to:

- Understand how eBPF powers Cilium's data plane
- Install and configure Cilium on a Kubernetes cluster
- Verify and troubleshoot pod-to-pod and pod-to-service connectivity
- Enforce network policies at L3/L4 and L7 (HTTP)
- Use Hubble to observe and monitor network flows in real time

## Prerequisites

- Basic Kubernetes knowledge (Pods, Deployments, Services)
- `kubectl` installed and configured
- `helm` CLI
- `cilium` CLI
- `hubble` CLI
- A running Kubernetes cluster (e.g. [kind](https://kind.sigs.k8s.io/))

### Building the Lab Environment

**[setup-ubuntu/](setup-ubuntu/)** — step-by-step instructions to install every CLI above
on Ubuntu 22.04 / 24.04, plus an idempotent `setup-ubuntu.sh` that does it in one command.
Clusters are not created here: every scenario folder ships a `create-kind-cluster.sh`
script and the kind config file it uses.

```bash
cd setup-ubuntu && ./setup-ubuntu.sh
```

Learners on the Bulut Bilisimciler hosted environment can skip this — the CLIs are
pre-installed, and each scenario's first step creates the cluster (see
[Bulut Bilisimciler Platform](#bulut-bilisimciler-platform-bb-template)).

## Course Content

### Introduction — Cilium & eBPF

**[cilium-ebpf-introduction/introduction.md](cilium-ebpf-introduction/introduction.md)**

Read this first. Why Kubernetes needs a CNI plugin, how datapaths moved from iptables to
eBPF, what eBPF is, how Cilium is built, and when to pick it. The diagrams live in
[`img/`](img/) (PNG files, with their SVG sources in `img/src/`).

---

### Module 0 — Environment

**Setup — Preparing an Ubuntu Host**
[setup-ubuntu/](setup-ubuntu/)

Install Docker, kubectl, kind, Helm and the Cilium/Hubble CLIs — the tools every scenario
below uses.

**Lab cluster**

All scenarios use the same cluster: 1 control-plane + 2 workers, default CNI disabled so
Cilium owns the data plane. Each scenario folder contains a `create-kind-cluster.sh` that
creates the kind cluster (or reuses an existing one), sets the `kind-kind` kubectl context
in `$KUBECONFIG`, installs Cilium with Helm and waits until all nodes are `Ready`:

```bash
cd scenario-2-pod-connectivity      # any scenario folder
./create-kind-cluster.sh            # --recreate | --delete | --no-cilium | --image kindest/node:<tag>
```

Scenario 1 teaches the Cilium installation itself, so there you run it with `--no-cilium`
and install Cilium by hand. From any later scenario's folder, the script rebuilds a
ready-to-use cluster in one step.

---

### Module 1 — Foundations

**Scenario 1 — Installing Cilium**
[scenario-1-installation-cilium/](scenario-1-installation-cilium/)

Deploy Cilium onto a kind cluster using Helm. Understand the core components (agent DaemonSet, Operator, Envoy) and verify a healthy installation.

---

### Module 2 — Connectivity

**Scenario 2 — Pod Connectivity**
[scenario-2-pod-connectivity/](scenario-2-pod-connectivity/)

Verify internode pod-to-pod connectivity between workloads scheduled on different Kubernetes nodes using Cilium's VXLAN-based tunnel routing.

**Scenario 3 — Service Connectivity**
[scenario-3-service-connectivity/](scenario-3-service-connectivity/)

Test pod-to-Service connectivity through Cilium's kube-proxy replacement. Observe how ClusterIP Services are resolved and load-balanced at the eBPF layer.

---

### Module 3 — Network Policy

**Scenario 4 — Network Policies (L3/L4)**
[scenario-4-cilium-network-policies-layer3-layer4/](scenario-4-cilium-network-policies-layer3-layer4/)

Lock down a three-tier shop (`frontend` → `backend` → `database` namespaces) with `CiliumNetworkPolicy`: default-deny ingress, cross-namespace label selectors, per-port rules, and an egress policy that needs DNS allowed. Verify every path is allowed or blocked as intended.

**Scenario 5 — Network Policies (Layer 7)**
[scenario-5-cilium-network-policies-layer7/](scenario-5-cilium-network-policies-layer7/)

Extend network policies to Layer 7 (HTTP). Restrict access based on HTTP methods and paths using Cilium's Envoy-backed L7 policy enforcement.

---

### Module 4 — Observability

**Scenario 6 — Observability with Hubble**
[scenario-6-observability-with-hubble/](scenario-6-observability-with-hubble/)

Enable Hubble Relay and UI, then use the Hubble CLI and UI to observe live flows with no policy in place: pod-to-pod, pod-to-Service, DNS, traffic leaving the cluster, and a failed connection.

---

### Module 5 — IP Address Management

**Scenario 7 — Cluster Scope IPAM**
[scenario-7-cluster-scope-ipam/](scenario-7-cluster-scope-ipam/)

Reinstall Cilium in Cluster Scope IPAM mode (`cluster-pool`) with two small `/28` pools, check the `/29` subnet each node receives, and exhaust a node's addresses to see the limits of a static address space.

---

### Module 6 — Exposing Applications

**Scenario 8 — Ingress**
[scenario-8-ingress/](scenario-8-ingress/)

Expose the Bookinfo app with the Cilium Ingress controller on a kube-proxy-free cluster: assign the Ingress an external IP with LB-IPAM, announce it with a Layer 2 announcement policy, and reach it with `curl` from outside the cluster.

**Scenario 9 — Gateway API**
[scenario-9-gatewayapi/](scenario-9-gatewayapi/)

Install the Gateway API CRDs and expose Bookinfo through a Cilium `Gateway`: route by path with an `HTTPRoute`, then add a second team's `HTTPRoute` that runs a 90/10 canary of `reviews` with weights and a header match — things a plain `Ingress` cannot express.

---

### Module 7 — Egress Traffic

**Scenario 10 — Egress Gateway**
[scenario-10-egress-gateway/](scenario-10-egress-gateway/)

Give one application a fixed source IP for traffic leaving the cluster: see pods leave with their node's IP by default, then apply a `CiliumEgressGatewayPolicy` that sends the `payments` pod's traffic out through a labelled gateway node, inspect the BPF egress map, and see the traffic dropped when no gateway is available.

---

### Module 8 — eBPF Internals

**Scenario 11 — eBPF Under the Hood**
[scenario-11-ebpf-under-the-hood/](scenario-11-ebpf-under-the-hood/)

Look inside Cilium's data plane on a kube-proxy-free cluster: list the eBPF programs attached to each interface with `bpftool`, read the Service and policy maps with `cilium-dbg`, scale a Deployment to see only map entries change (and no `KUBE-SVC` iptables rules), and watch a policy drop arrive as an event from the kernel.

---

## Repository Structure

```
.
├── img/                          # diagrams used by the introduction (PNG + SVG sources)
│   └── src/
├── cilium-ebpf-introduction/
│   ├── introduction.md
│   └── bb-template/              # 1 step: en_step1.md / tr_step1.md
├── setup-ubuntu/
│   ├── instructions-setup-ubuntu.md
│   └── setup-ubuntu.sh
├── scenario-1-installation-cilium/
│   ├── instructions-scenario-1.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   └── light-lab.yaml
├── scenario-2-pod-connectivity/
│   ├── instructions-scenario-2.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── app-nginx.yaml
│   └── app-netshoot.yaml
├── scenario-3-service-connectivity/
│   ├── instructions-scenario-3.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── app-nginx.yaml
│   ├── app-netshoot.yaml
│   └── svc-nginx.yaml
├── scenario-4-cilium-network-policies-layer3-layer4/
│   ├── instructions-scenario-4.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── namespaces.yaml
│   ├── app-api.yaml
│   ├── app-redis.yaml
│   ├── app-clients.yaml
│   ├── cnp-01-default-deny.yaml
│   ├── cnp-02-allow-web-to-api.yaml
│   ├── cnp-03-allow-api-to-redis.yaml
│   ├── cnp-04-web-egress-no-dns.yaml
│   └── cnp-04-web-egress.yaml
├── scenario-5-cilium-network-policies-layer7/
│   ├── instructions-scenario-5.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   └── light-lab.yaml
├── scenario-6-observability-with-hubble/
│   ├── instructions-scenario-6.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── app-nginx.yaml
│   ├── app-netshoot.yaml
│   └── svc-nginx.yaml
├── scenario-7-cluster-scope-ipam/
│   ├── instructions-scenario-7.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── cilium-values.yaml
│   ├── netshoot-client-pod.yaml
│   └── nginx-deployment-10-replicas.yaml
├── scenario-8-ingress/
│   ├── instructions-scenario-8.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── cilium-values.yaml
│   ├── ingress-basic.yaml
│   ├── lb-ippool.yaml
│   └── l2-announcement-policy.yaml
├── scenario-9-gatewayapi/
│   ├── instructions-scenario-9.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── cilium-values.yaml
│   ├── lb-ippool.yaml
│   ├── l2-announcement-policy.yaml
│   ├── gateway.yaml
│   ├── httproute-bookinfo.yaml
│   ├── reviews-services.yaml
│   └── httproute-reviews-canary.yaml
├── scenario-10-egress-gateway/
│   ├── instructions-scenario-10.md
│   ├── bb-template/
│   ├── create-kind-cluster.sh
│   ├── light-lab.yaml
│   ├── cilium-values.yaml
│   ├── app-clients.yaml
│   └── egress-gateway-policy.yaml
└── scenario-11-ebpf-under-the-hood/
    ├── instructions-scenario-11.md
    ├── bb-template/
    ├── create-kind-cluster.sh
    ├── light-lab.yaml
    ├── cilium-values.yaml
    ├── app-nginx.yaml
    ├── app-client.yaml
    └── cnp-allow-frontend.yaml
```

## Bulut Bilisimciler Platform (`bb-template/`)

Every scenario folder has a `bb-template/` folder. It defines the scenario's steps and
structure for the [Bulut Bilisimciler](https://bulutbilisimciler.com) platform, where
learners run the lab in the browser. The platform shows the instructions step by step
next to a terminal.

| File | Purpose |
| --- | --- |
| `index.json` | the order of the steps, the intro and finish pages, the environment (terminal-only, Ubuntu image) and which step runs the verification |
| `en_intro.md` / `tr_intro.md` | start page, the same in every scenario except the scenario title |
| `en_stepN.md` / `tr_stepN.md` | the steps (at most 4), in English and Turkish |
| `en_finish.md` / `tr_finish.md` | end page, the same in every scenario except the scenario title |
| `verify.json` | the check that runs on the last step (currently a placeholder) |

`index.json` names the files without a language prefix (`step1.md`). The platform picks
the `en_` or `tr_` file for the learner's language.

The steps cover the same content as `instructions-scenario-N.md`, adapted to the
platform:

- The learner starts on a fresh Ubuntu machine with the CLIs installed but **no cluster
  and no repository files**. Step 1 of every scenario creates the kind cluster and
  installs Cilium with plain commands (no `create-kind-cluster.sh`).
- Manifests are written inline in the commands (`kubectl apply -f - <<EOF`), so each step
  is self-contained.
- Some parts are shortened or left out to fit 4 steps and the terminal-only layout (for
  example, the Hubble UI in scenario 6).

When you change a scenario's `instructions-scenario-N.md`, update its `bb-template/`
steps in both languages too.

## References

- [Cilium Documentation](https://docs.cilium.io)
- [Cilium: Up and Running Book](https://www.oreilly.com/library/view/cilium-up-and/9798341622982/)
- [kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [eBPF.io](https://ebpf.io)
- [Cilium GitHub](https://github.com/cilium/cilium)
- [Hubble GitHub](https://github.com/cilium/hubble)
