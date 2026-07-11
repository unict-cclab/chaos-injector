# Chaos Injector

Generates node-pinned DaemonSets that apply cross-group network latency,
bandwidth limits, and packet loss to Kubernetes node traffic.

## Commands

```bash
./chaos-injector.sh generate [manifest]
./chaos-injector.sh deploy [manifest]
./chaos-injector.sh apply [manifest ...]
./chaos-injector.sh delete [manifest ...]
```

## Parameters

| Environment variable | Default | Description |
| --- | --- | --- |
| `NODE_GROUP_LABEL` | `topology.kubernetes.io/zone` | Label defining node groups |
| `NODE_SELECTOR` | empty | Selector limiting affected nodes |
| `NETWORK_INTERFACE` | `flannel.1` | Interface carrying remote PodCIDR traffic |
| `HOST_NETWORK` | `false` | Target cross-group node InternalIPs (`/32`) instead of PodCIDRs |
| `ENABLE_LATENCY` | `true` | Enable latency |
| `CROSS_ZONE_LATENCY` | `50ms` | One-way cross-group delay |
| `JITTER` | `0ms` | Delay variation |
| `CORRELATION` | `0` | Delay correlation percentage |
| `ENABLE_BANDWIDTH` | `false` | Enable bandwidth limiting |
| `CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND` | empty | Bandwidth limit in bytes per second (`tc`'s `bps` suffix means bytes/s) |
| `ENABLE_PACKET_LOSS` | `false` | Enable packet loss |
| `PACKET_LOSS` | `0` | Packet-loss percentage |
| `CHAOS_NAMESPACE` | `chaos-mesh` | DaemonSet namespace |
| `CHAOS_DAEMON_IMAGE` | built-in | Shaper container image |
| `CHAOS_MANIFEST` | beside script | Default generated manifest |
| `KUBECTL` | `kubectl` | kubectl executable |

Selected nodes need an InternalIP, PodCIDR, and `NODE_GROUP_LABEL`. Deleting the
manifest removes the installed traffic-control rules.

For pods using `hostNetwork: true`, set `HOST_NETWORK=true` and select the host
interface (for example, `NETWORK_INTERFACE=eth0`). This targets the InternalIPs
of nodes in other groups. Host-interface shaping can also affect unrelated
node-to-node traffic sent to those addresses.
