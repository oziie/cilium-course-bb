- What is CNI? Why do we need it?

*** Add below lines to under this title definetly:

As use of Kubernetes and containerization spread, one reality became obvious: regardless of the underlying computing platform, workloads have the same basic network and security requirements. Whether you run them on bare metal, virtual machines (VMs), or containers, you expect your applications to:

• Have accessible IP addresses • Be able to communicate with other applications • Be able to reach the outside world when they need outbound access • Be reachable from the outside world when inbound access is required • Be secured, with data protected in transit and at rest 1 • Remain resilient and highly available on a global scale • Meet regulatory goals and compliance requirements • Provide the visibility you need to operate and troubleshoot when things go wrong

- Evolution of CNIs to Modern Datapaths

*** Explain eBPF

*** Add below lines to under this title definetly
To better understand the origins of eBPF, we highly recommend watching the fascinating documentary eBPF: Unlocking the Kernel. Released in 2024 to celebrate eBPF’s 10th anniversary, it is an insightful look at how a small group of kernel engineers created a technology that is now at the heart of modern networking, security, and observability.
https://isovalent.com/blog/post/ebpf-documentary-creation-story/


- What's Cilium? Why Cilium?

*** Advantegous of Cilium, how it works?


- Cilium Use Cases

*** In such cases we should pick it?

