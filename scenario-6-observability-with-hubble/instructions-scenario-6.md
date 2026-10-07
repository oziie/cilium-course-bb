# Scenario 6 — Observability with Hubble

## Prepare the kind cluster (no need for BB)

This scenario runs on the same cluster as the previous ones: 1 control-plane + 2 workers
with Cilium installed. If you are continuing from the previous scenario, skip this section.

Otherwise, create (or reuse) the cluster with the script in this folder:

```bash
cd scenario-6-observability-with-hubble
./create-kind-cluster.sh
kubectl config current-context   # should print kind-kind
```

The script creates the cluster, installs Cilium with the same settings as
[Scenario 1](../scenario-1-installation-cilium/instructions-scenario-1.md) and waits until
all nodes are `Ready`. If Cilium is already installed, it is left as is. Check it with:

```bash
cilium status
```
