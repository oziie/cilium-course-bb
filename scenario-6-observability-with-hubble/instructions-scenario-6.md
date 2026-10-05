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

The script fails fast on errors, sets the `kind-kind` context in `$KUBECONFIG` (default
`~/.kube/config`) and verifies the node layout. A freshly created cluster has **no CNI**:
install Cilium by following
[Scenario 1 — Cilium Installation](../scenario-1-installation-cilium/instructions-scenario-1.md#cilium-installation-via-helm)
before continuing. Check it with `cilium status --wait`.
