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
Clusters are not created here: each scenario creates its own kind cluster from the config
in its folder.

```bash
cd setup-ubuntu && ./setup-ubuntu.sh
```

Learners on the Bulut Bilisimciler hosted environment can skip this — the cluster and
CLIs are pre-provisioned.

## Course Content

### Module 0 — Environment

**Setup — Preparing an Ubuntu Host**
[setup-ubuntu/](setup-ubuntu/)

Install Docker, kubectl, kind, Helm and the Cilium/Hubble CLIs — the tools every scenario
below uses. Each scenario then creates the kind cluster it needs.

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
[scenario-4-cilium-network-policies/](scenario-4-cilium-network-policies/)

Write and apply `CiliumNetworkPolicy` resources to control traffic at the IP and port level. Verify that ingress and egress rules are enforced correctly.

**Scenario 5 — Network Policies (Layer 7)**
[scenario-5-cilium-network-policies-layer7/](scenario-5-cilium-network-policies-layer7/)

Extend network policies to Layer 7 (HTTP). Restrict access based on HTTP methods and paths using Cilium's Envoy-backed L7 policy enforcement.

---

### Module 4 — Observability

**Scenario 6 — Observability with Hubble**
[scenario-6-observability-with-hubble/](scenario-6-observability-with-hubble/)

Enable Hubble and use the Hubble CLI and UI to inspect live network flows, identify dropped packets, and understand traffic patterns across the cluster.

---

## Repository Structure

```
.
├── setup-ubuntu/
│   ├── instructions-setup-ubuntu.md
│   └── setup-ubuntu.sh
├── scenario-1-installation-cilium/
│   ├── instructions-scenario-1.md
│   └── light-lab.yaml
├── scenario-2-pod-connectivity/
│   ├── instructions-scenario-2.md
│   ├── app-nginx.yaml
│   └── app-netshoot.yaml
├── scenario-3-service-connectivity/
│   ├── instructions-scenario-3.md
│   ├── app-nginx.yaml
│   ├── app-netshoot.yaml
│   └── svc-nginx.yaml
├── scenario-4-cilium-network-policies/
├── scenario-5-cilium-network-policies-layer7/
└── scenario-6-observability-with-hubble/
```

## References

- [Cilium Documentation](https://docs.cilium.io)
- [kind — Quick Start](https://kind.sigs.k8s.io/docs/user/quick-start/)
- [eBPF.io](https://ebpf.io)
- [Cilium GitHub](https://github.com/cilium/cilium)
- [Hubble GitHub](https://github.com/cilium/hubble)
