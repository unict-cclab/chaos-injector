# Cross-Zone Network Chaos Injector

This tool generates Chaos Mesh `NetworkChaos` resources that model node
proximity. Nodes carrying the same topology label value are considered part of
the same zone. Traffic between different zones receives both additional
latency and a bandwidth limit; traffic inside a zone is unchanged.

By default, the injector uses Kubernetes' standard
`topology.kubernetes.io/zone` node label. It selects all workload pods in the
configured namespace, so applications do not need a special `group` label.

## Prerequisites

- A Kubernetes cluster with Chaos Mesh installed
- `kubectl` configured for that cluster
- At least two nodes, each with an InternalIP and the topology label

For example:

```bash
kubectl label node node-a topology.kubernetes.io/zone=near-1
kubectl label node node-b topology.kubernetes.io/zone=near-1
kubectl label node node-c topology.kubernetes.io/zone=near-2
```

Here, traffic between `node-a` and `node-b` is unchanged. Traffic between
either of them and `node-c` receives `CROSS_ZONE_LATENCY` and is limited to
`CROSS_ZONE_BANDWIDTH`.

Chaos Mesh represents delay and bandwidth shaping as separate actions, so the
generated manifest contains two `NetworkChaos` resources for each directed
cross-zone node pair.

## Usage

The `chaos-injector.sh` entry point manages the complete manifest lifecycle.
Without a path, all commands use `node-latency-chaos.yaml` in this directory.

Generate and apply the manifest in one command:

```bash
CROSS_ZONE_LATENCY=50ms CROSS_ZONE_BANDWIDTH=10mbps \
  ./chaos-injector.sh deploy
```

Generate the manifest:

```bash
CROSS_ZONE_LATENCY=50ms CROSS_ZONE_BANDWIDTH=10mbps \
  ./chaos-injector.sh generate
```

Apply it:

```bash
./chaos-injector.sh apply
```

Delete its resources:

```bash
./chaos-injector.sh delete
```

Each command also accepts an explicit path. `deploy` generates and applies one
manifest, while `apply` and `delete` can process multiple manifests:

```bash
./chaos-injector.sh deploy /tmp/cluster-a-chaos.yaml
./chaos-injector.sh generate /tmp/cluster-a-chaos.yaml
./chaos-injector.sh apply /tmp/cluster-a-chaos.yaml /tmp/cluster-b-chaos.yaml
./chaos-injector.sh delete /tmp/cluster-a-chaos.yaml /tmp/cluster-b-chaos.yaml
```

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `WORKLOAD_NAMESPACE` | `default` | Namespace whose pods receive cross-zone network chaos |
| `NODE_GROUP_LABEL` | `topology.kubernetes.io/zone` | Node label defining proximity groups |
| `CROSS_ZONE_LATENCY` | `50ms` | Added latency between nodes in different zones |
| `CROSS_ZONE_BANDWIDTH` | `10mbps` | Bandwidth rate between nodes in different zones |
| `BANDWIDTH_LIMIT` | `20971520` | Maximum bytes queued by the bandwidth shaper |
| `BANDWIDTH_BUFFER` | `10000` | Maximum bytes sent instantaneously by the bandwidth shaper |
| `JITTER` | `0ms` | Chaos Mesh delay jitter |
| `CORRELATION` | `0` | Chaos Mesh delay correlation |
| `KUBECTL` | `kubectl` | `kubectl` executable |
| `CHAOS_MANIFEST` | `node-latency-chaos.yaml` beside the script | Default manifest used by lifecycle commands |

The injector can also apply equivalent delay and bandwidth shaping to an
observer pod that probes node InternalIP addresses. This is enabled by default
for the existing Mentat setup and is configurable:

| Variable | Default | Meaning |
| --- | --- | --- |
| `OBSERVER_NAMESPACE` | `observability` | Observer namespace; set to an empty string to disable |
| `OBSERVER_LABEL_KEY` | `app` | Observer pod selector label key |
| `OBSERVER_LABEL_VALUE` | `mentat` | Observer pod selector label value |

The generated manifest is cluster-specific and ignored by Git.
