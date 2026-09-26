> **Note:** E-Book Chapter-3 and this repo is the reference for the installation part.

## Prerequisites Tools

- `helm`
- `cilium-cli`
- `hubble`

## Create kind cluster (no need for BB)

If you are building the lab on your own Ubuntu machine, follow
[setup-ubuntu/instructions-setup-ubuntu.md](../setup-ubuntu/instructions-setup-ubuntu.md)
first to install the prerequisite tools. Then create this scenario's cluster from
[`light-lab.yaml`](light-lab.yaml):

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
- role: worker
- role: worker
networking:
  disableDefaultCNI: true   # Disables kindnetd prior to Cilium install
```

One control-plane node plus two workers gives two schedulable nodes, so later scenarios
can show *internode* pod-to-pod traffic. `disableDefaultCNI: true` removes kindnetd so
Cilium can own the data plane.

```bash
cd scenario-1-installation-cilium
kind create cluster --name kind --config light-lab.yaml
kubectl config current-context   # should print kind-kind, matching cluster.name below
```

> **Note:** coredns and localpath pods will be stuck in "Pending" state as default CNI is disabled. As a result, nodes will not be ready as well.

## Cilium Installation (via Helm)

```bash
helm repo add cilium https://helm.cilium.io/

helm upgrade --install cilium cilium/cilium -n kube-system \
--version 1.18.4 \
--set cluster.name=kind-kind \
--set ipam.mode=kubernetes \
--set operator.replicas=1 \
--set routingMode=tunnel \
--set tunnelProtocol=vxlan
```

> **Note:** The cilium install command also accepts these Helm-style --set flags for
> customization. By default, both cilium install and Helm will install the latest stable version of
> Cilium. However, you can explicitly specify a version to ensure consistency across
> environments or to avoid unexpected changes. This is especially useful in production,
> where you may want to pin versions and manage upgrades intentionally.
> You can watch the progress of the installation by typing `cilium status --wait`

## Verify the Installation

Once the installation is done, verify the installation with `cilium status`:

```
$ cilium status
    /¯¯\
 /¯¯\__/¯¯\ Cilium:      OK
 \__/¯¯\__/ Operator:    OK
 /¯¯\__/¯¯\ Envoy DaemonSet: OK
 \__/¯¯\__/ Hubble Relay:    disabled
     \__/   ClusterMesh:     disabled
DaemonSet        cilium             Desired: 3, Ready: 3/3
DaemonSet        cilium-envoy       Desired: 3, Ready: 3/3
Deployment       cilium-operator    Desired: 1, Ready: 1/1
Containers:      cilium             Running: 3
                 cilium-envoy       Running: 3
                 cilium-operator    Running: 1
                 clustermesh-apiserver
                 hubble-relay
Cluster Pods:    3/3 managed by Cilium
                 [...]
```

> **Note:** Since the Cilium agent and Envoy components are both deployed through
> a DaemonSet, there is an instance of each deployed on every cluster node. As you
> might have seen in the earlier cilium install --dry-run-helm-values output, a
> single Cilium operator was deployed as part of the deployment. You can verify this
> with the following kubectl commands:

```bash
$ kubectl get -n kube-system daemonset cilium cilium-envoy
NAME           DESIRED   READY   NODE SELECTOR
cilium         3         3       kubernetes.io/os=linux
cilium-envoy   3         3       kubernetes.io/os=linux
```

```bash
$ kubectl get -n kube-system deployment cilium-operator
NAME              READY   AVAILABLE
cilium-operator   1/1     1
```
