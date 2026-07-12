#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fake_kubectl="$tmp_dir/kubectl"
manifest="$tmp_dir/node-shaping.yaml"
host_manifest="$tmp_dir/host-network-shaping.yaml"

cat >"$fake_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "get" && "$2" == "nodes" ]]; then
  printf '%s\n' \
    $'app-01\t192.168.1.11\t10.42.1.0/24\tzone-a' \
    $'app-02\t192.168.1.12\t10.42.2.0/24\tzone-a' \
    $'app-03\t192.168.1.13\t10.42.3.0/24\tzone-b' \
    $'app-04\t192.168.1.14\t10.42.4.0/24\tzone-c'
  exit 0
fi
echo "unexpected kubectl invocation: $*" >&2
exit 1
EOF
chmod +x "$fake_kubectl"

KUBECTL="$fake_kubectl" \
NODE_SELECTOR=nodepool=app \
DEFAULT_CROSS_ZONE_LATENCY=100ms \
ZONE_LINKS='zone-a>zone-b=15ms;2500000;0.5,zone-a>zone-c=80ms;;' \
ENABLE_BANDWIDTH=true \
DEFAULT_CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND=1250000 \
ENABLE_PACKET_LOSS=true \
DEFAULT_CROSS_ZONE_PACKET_LOSS=1 \
  "$repo_dir/chaos-injector.sh" generate "$manifest" >/dev/null

[[ "$(grep -c '^kind: DaemonSet$' "$manifest")" -eq 4 ]]

app_01="$(sed -n '/name: node-delay-app-01$/,/^---$/p' "$manifest")"
grep -q '10.42.3.0/24' <<<"$app_01"
grep -q '10.42.4.0/24' <<<"$app_01"
grep -q 'delay 15ms' <<<"$app_01"
grep -q 'delay 80ms' <<<"$app_01"
grep -q 'rate 2500000bps' <<<"$app_01"
grep -q 'loss 0.5%' <<<"$app_01"
grep -q 'rate 1250000bps' <<<"$app_01"
if grep -qE '10\.42\.[12]\.0/24' <<<"$app_01"; then
  echo "app-01 shaper unexpectedly targets a same-zone PodCIDR" >&2
  exit 1
fi

if grep -qE '10\.42\.(0|5)\.0/24' "$manifest"; then
  echo "manifest unexpectedly targets an unselected node PodCIDR" >&2
  exit 1
fi

KUBECTL="$fake_kubectl" \
NODE_SELECTOR=nodepool=app \
NETWORK_INTERFACE=eth0 \
HOST_NETWORK=true \
  "$repo_dir/chaos-injector.sh" generate "$host_manifest" >/dev/null

host_app_01="$(sed -n '/name: node-delay-app-01$/,/^---$/p' "$host_manifest")"
grep -q 'value: "eth0"' <<<"$host_app_01"
grep -q 'value: "true"' <<<"$host_app_01"
grep -q '192.168.1.13/32' <<<"$host_app_01"
grep -q '192.168.1.14/32' <<<"$host_app_01"
if grep -q '10.42.' <<<"$host_app_01"; then
  echo "host-network shaper unexpectedly targets a PodCIDR" >&2
  exit 1
fi

echo "generate_test: PASS"
