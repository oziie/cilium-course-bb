### Observability with Hubble

#### Step 2 — Enable Hubble Relay and Connect the CLI

Cilium's eBPF programs already see every packet entering or leaving a pod. Hubble turns
them into readable **flows**:

| Component | Where it runs | Role |
| --- | --- | --- |
| Hubble server | inside every `cilium` agent | records the flows of its own node (on by default) |
| Hubble Relay | `hubble-relay` Deployment | collects the flows of **all** nodes into one API |
| `hubble` CLI | your terminal | reads the flows from Relay |

Enable Hubble Relay with a Helm upgrade. `--reuse-values` keeps the settings from the
installation and only adds Relay:

```bash
helm upgrade cilium cilium/cilium -n kube-system \
  --version 1.18.4 \
  --reuse-values \
  --set hubble.relay.enabled=true
kubectl -n kube-system rollout status deployment/hubble-relay
cilium status
```

`cilium status` now shows `Hubble Relay: OK`.

The `hubble` CLI connects to Relay on `localhost:4245`. Open a port-forward to Relay. The
`&` at the end keeps it running in the background, so you can keep using this terminal:

```bash
cilium hubble port-forward > /dev/null 2>&1 &
sleep 3
hubble status
```

`hubble status` shows `Healthcheck (via localhost:4245): Ok` and `Connected Nodes: 3/3`:
Relay reaches the Hubble server on every node.

```bash
hubble list nodes
```

Each node keeps its most recent flows in memory (4095 per node), so Hubble shows recent
traffic, not a full history.

> **Note:** If `hubble status` fails with `connect: connection refused`, the port-forward
> is not running. Start it again with the `cilium hubble port-forward` command above.
