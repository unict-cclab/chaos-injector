# Cross-Zone Node Network Injector

This tool models network proximity between Kubernetes nodes. Nodes carrying the
same topology label value are treated as one group. Traffic to PodCIDRs owned by
nodes in another group can receive additional latency, packet loss, and/or a
bandwidth limit; traffic within a group is unchanged.

The generated manifest contains one privileged, node-pinned DaemonSet for each
selected source node. Each shaper installs `tc/netem` filters in the host network
namespace and remains effective when application pods scale, restart, or move.

The shaper image defaults to the Chaos Mesh daemon image, reusing its audited
`tc` and `nsenter` tooling. This implementation does not create `NetworkChaos`
resources because those inject into selected pod network namespaces and do not
cover replacement pods automatically.

## Prerequisites

- A Kubernetes cluster using Flannel VXLAN, or another CNI with a routable
  interface for remote PodCIDRs
- `kubectl` configured for the cluster
- Chaos Mesh's daemon image available to cluster nodes
- At least two selected nodes with an InternalIP, PodCIDR, and topology label

For example:

```bash
kubectl label node node-a topology.kubernetes.io/zone=zone-a
kubectl label node node-b topology.kubernetes.io/zone=zone-a
kubectl label node node-c topology.kubernetes.io/zone=zone-b
```

Traffic between `node-a` and `node-b` is unchanged. Traffic between either node
and `node-c` receives the enabled impairments in each configured direction.

`NODE_SELECTOR` defines the complete shaping boundary. When it is set to
`nodepool=app`, shapers run only on application nodes and filters contain only
PodCIDRs belonging to other `nodepool=app` nodes. Traffic between application
nodes and control-plane, management, or other unselected nodes is not shaped.

The selector can narrow the experiment to an exact pair. Provided the nodes
belong to different groups, this shapes only `node-a` and `node-c`:

```bash
NODE_SELECTOR='kubernetes.io/hostname in (node-a,node-c)' \
  ./chaos-injector.sh deploy
```

## Usage

Generate and apply the manifest, then wait for all node shapers to become ready:

```bash
ENABLE_LATENCY=true CROSS_ZONE_LATENCY=100ms ./chaos-injector.sh deploy
```

Enable bandwidth restriction and packet loss independently:

```bash
ENABLE_LATENCY=false \
ENABLE_BANDWIDTH=true CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND=1250000 \
ENABLE_PACKET_LOSS=true PACKET_LOSS=1 \
  ./chaos-injector.sh deploy
```

Generate, apply, or delete separately:

```bash
./chaos-injector.sh generate
./chaos-injector.sh apply
./chaos-injector.sh delete
```

Each command accepts an explicit manifest path. `apply` and `delete` can process
multiple manifests.

## Configuration

| Variable | Default | Meaning |
| --- | --- | --- |
| `NODE_GROUP_LABEL` | `topology.kubernetes.io/zone` | Node label defining proximity groups |
| `NODE_SELECTOR` | empty | Optional selector limiting shaped nodes, such as `nodepool=app` |
| `ENABLE_LATENCY` | `true` | Enables cross-group `tc netem delay` |
| `ENABLE_BANDWIDTH` | `false` | Enables cross-group `tc netem rate` |
| `ENABLE_PACKET_LOSS` | `false` | Enables cross-group `tc netem loss` |
| `CROSS_ZONE_LATENCY` | `50ms` | One-way delay applied toward nodes in other groups |
| `CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND` | empty | Bandwidth rate applied toward nodes in other groups when enabled, expressed in bytes per second |
| `PACKET_LOSS` | `0` | Packet-loss percentage passed to `tc netem`, with or without `%` |
| `JITTER` | `0ms` | Delay variation passed to `tc netem` |
| `CORRELATION` | `0` | Delay correlation percentage, with or without `%` |
| `NETWORK_INTERFACE` | `flannel.1` | Host interface carrying traffic toward remote PodCIDRs |
| `CHAOS_NAMESPACE` | `chaos-mesh` | Namespace for the generated shaper DaemonSets |
| `CHAOS_DAEMON_IMAGE` | `ghcr.io/chaos-mesh/chaos-daemon:v2.7.1` | Image providing `tc` and `nsenter` |
| `KUBECTL` | `kubectl` | `kubectl` executable |
| `CHAOS_MANIFEST` | `node-latency-chaos.yaml` beside the script | Default manifest path |

The injector creates directed filters on every selected node. Consequently,
`CROSS_ZONE_LATENCY=100ms` produces approximately 200 ms of additional
cross-group round-trip time when latency injection is enabled.

The impairments are applied by the same filtered `netem` qdisc. They only affect
traffic matching the generated cross-group PodCIDR filters, but the measured
effects are not independent: packet loss usually reduces TCP bandwidth, and
bandwidth limits can increase latency under queueing.

Deleting the manifest terminates the shaper pods. Their termination handler
removes the root qdisc installed by the injector.

The generated cluster-specific manifest is ignored by Git.
