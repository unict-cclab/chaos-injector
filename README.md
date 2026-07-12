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
| `DEFAULT_CROSS_ZONE_LATENCY` | `50ms` | Default one-way cross-group delay |
| `ZONE_LINKS` | empty | Directed per-zone overrides encoded as `from>to=latency;bandwidthBytesPerSecond;packetLoss` |
| `ENABLE_BANDWIDTH` | `false` | Enable bandwidth limiting |
| `DEFAULT_CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND` | empty | Default bandwidth limit in bytes per second (`tc`'s `bps` suffix means bytes/s) |
| `ENABLE_PACKET_LOSS` | `false` | Enable packet loss |
| `DEFAULT_CROSS_ZONE_PACKET_LOSS` | `0` | Default packet-loss percentage |
| `CHAOS_NAMESPACE` | `chaos-mesh` | DaemonSet namespace |
| `CHAOS_DAEMON_IMAGE` | built-in | Shaper container image |
| `CHAOS_MANIFEST` | beside script | Default generated manifest |
| `KUBECTL` | `kubectl` | kubectl executable |

Selected nodes need an InternalIP, PodCIDR, and `NODE_GROUP_LABEL`. Deleting the
manifest removes the installed traffic-control rules.

`ZONE_LINKS` rules are directional. For example,
`cloud>fog=20ms;12500000;0.1` customizes all supported impairments. Leave a
field empty to inherit its corresponding `DEFAULT_CROSS_ZONE_*` value.
Unlisted pairs inherit every global default. The injector creates a separate
netem class per destination zone.
The `ENABLE_LATENCY`, `ENABLE_BANDWIDTH`, and `ENABLE_PACKET_LOSS` switches
remain feature-level gates; an override for a disabled impairment is retained
in configuration but is not applied.

For pods using `hostNetwork: true`, set `HOST_NETWORK=true` and select the host
interface (for example, `NETWORK_INTERFACE=eth0`). This targets the InternalIPs
of nodes in other groups. Host-interface shaping can also affect unrelated
node-to-node traffic sent to those addresses.
