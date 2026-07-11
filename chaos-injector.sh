#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
default_manifest="${CHAOS_MANIFEST:-$script_dir/node-latency-chaos.yaml}"
kubectl_bin="${KUBECTL:-kubectl}"
chaos_namespace="${CHAOS_NAMESPACE:-chaos-mesh}"
chaos_daemon_image="${CHAOS_DAEMON_IMAGE:-ghcr.io/chaos-mesh/chaos-daemon:v2.7.1}"
node_group_label="${NODE_GROUP_LABEL:-topology.kubernetes.io/zone}"
node_selector="${NODE_SELECTOR:-}"
network_interface="${NETWORK_INTERFACE:-flannel.1}"
host_network="${HOST_NETWORK:-false}"
enable_latency="${ENABLE_LATENCY:-true}"
enable_bandwidth="${ENABLE_BANDWIDTH:-false}"
enable_packet_loss="${ENABLE_PACKET_LOSS:-false}"
cross_zone_latency="${CROSS_ZONE_LATENCY:-50ms}"
cross_zone_bandwidth_bytes_per_second="${CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND:-}"
packet_loss="${PACKET_LOSS:-0}"
jitter="${JITTER:-0ms}"
correlation="${CORRELATION:-0}"

usage() {
  cat <<EOF
Usage:
  $(basename "$0") generate [MANIFEST]
  $(basename "$0") deploy [MANIFEST]
  $(basename "$0") apply [MANIFEST ...]
  $(basename "$0") delete [MANIFEST ...]

Commands:
  generate  Generate cluster-specific node-shaping DaemonSets.
  deploy    Generate a manifest and immediately apply it.
  apply     Apply one or more generated manifests.
  delete    Delete resources defined by one or more generated manifests.

The default manifest is:
  $default_manifest

Generation is configured through the environment variables documented in
$script_dir/README.md. KUBECTL and standard kubectl variables such as
KUBECONFIG are honored by all commands.
EOF
}

require_manifest() {
  local manifest="$1"
  if [[ ! -f "$manifest" ]]; then
    echo "manifest not found: $manifest" >&2
    echo "generate it first with: $(basename "$0") generate \"$manifest\"" >&2
    exit 1
  fi
}

sanitize_name() {
  printf '%s' "$1" |
    tr '[:upper:]_' '[:lower:]-' |
    sed -E 's/[^a-z0-9-]+/-/g; s/^-+//; s/-+$//'
}

is_true() {
  case "${1,,}" in
    true | yes | y | 1 | on | enabled) return 0 ;;
    false | no | n | 0 | off | disabled) return 1 ;;
    *)
      echo "invalid boolean value: $1" >&2
      exit 2
      ;;
  esac
}

bool_value() {
  if is_true "$1"; then
    printf 'true'
  else
    printf 'false'
  fi
}

resource_name() {
  local name hash
  name="$(sanitize_name "$1")"
  if [[ "${#name}" -le 63 ]]; then
    printf '%s' "$name"
    return
  fi
  hash="$(printf '%s' "$name" | sha256sum | cut -c1-8)"
  printf '%s-%s' "${name:0:54}" "$hash"
}

write_daemonset() {
  local source_node="$1"
  local source_group="$2"
  shift 2
  local target_cidrs=("$@")
  local name
  name="$(resource_name "node-delay-$source_node")"

  cat <<EOF
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: $name
  namespace: $chaos_namespace
  labels:
    app.kubernetes.io/name: node-latency-chaos
    app.kubernetes.io/managed-by: node-latency-chaos-injector
    chaos-injector/source-node: $source_node
    chaos-injector/source-group: $source_group
spec:
  selector:
    matchLabels:
      app.kubernetes.io/name: $name
  template:
    metadata:
      labels:
        app.kubernetes.io/name: $name
        app.kubernetes.io/managed-by: node-latency-chaos-injector
    spec:
      hostPID: true
      nodeSelector:
        kubernetes.io/hostname: $source_node
      tolerations:
        - operator: Exists
      terminationGracePeriodSeconds: 15
      containers:
        - name: node-shaper
          image: $chaos_daemon_image
          imagePullPolicy: IfNotPresent
          securityContext:
            privileged: true
          env:
            - name: NETWORK_INTERFACE
              value: "$network_interface"
            - name: HOST_NETWORK
              value: "$host_network"
            - name: ENABLE_LATENCY
              value: "$enable_latency"
            - name: ENABLE_BANDWIDTH
              value: "$enable_bandwidth"
            - name: ENABLE_PACKET_LOSS
              value: "$enable_packet_loss"
            - name: LATENCY
              value: "$cross_zone_latency"
            - name: BANDWIDTH_BYTES_PER_SECOND
              value: "$cross_zone_bandwidth_bytes_per_second"
            - name: PACKET_LOSS
              value: "$packet_loss"
            - name: JITTER
              value: "$jitter"
            - name: CORRELATION
              value: "$correlation"
          command:
            - /bin/sh
            - -ec
          args:
            - |
              host() { nsenter -t 1 -n -- "\$@"; }
              cleanup() {
                if host tc qdisc show dev "\$NETWORK_INTERFACE" | grep -q '^qdisc prio 1:'; then
                  host tc qdisc del dev "\$NETWORK_INTERFACE" root 2>/dev/null || true
                fi
              }
              cleanup_and_exit() {
                cleanup
                exit 0
              }
              trap cleanup_and_exit INT TERM
              existing_qdisc="\$(host tc qdisc show dev "\$NETWORK_INTERFACE")"
              case "\$existing_qdisc" in
                *"qdisc noqueue 0:"*|*"qdisc prio 1:"*) ;;
                *)
                  echo "refusing to replace existing qdisc on \$NETWORK_INTERFACE: \$existing_qdisc" >&2
                  exit 1
                  ;;
              esac
              cleanup
              netem_args=""
              if [ "\$ENABLE_LATENCY" = "true" ]; then
                netem_args="\$netem_args delay \$LATENCY \$JITTER \${CORRELATION%%%}%"
              fi
              if [ "\$ENABLE_PACKET_LOSS" = "true" ]; then
                netem_args="\$netem_args loss \${PACKET_LOSS%%%}%"
              fi
              if [ "\$ENABLE_BANDWIDTH" = "true" ]; then
                # tc/iproute2 uses "bps" for bytes per second ("bit" is bits per second).
                netem_args="\$netem_args rate \${BANDWIDTH_BYTES_PER_SECOND}bps"
              fi
              if [ -z "\$netem_args" ]; then
                echo "no network impairment enabled" >&2
                exit 1
              fi
              host tc qdisc add dev "\$NETWORK_INTERFACE" root handle 1: prio bands 3
              # shellcheck disable=SC2086
              host tc qdisc add dev "\$NETWORK_INTERFACE" parent 1:3 handle 30: netem \$netem_args
EOF
  local cidr
  for cidr in "${target_cidrs[@]}"; do
    cat <<EOF
              host tc filter add dev "\$NETWORK_INTERFACE" protocol ip parent 1:0 \
                prio 3 u32 match ip dst "$cidr" flowid 1:3
EOF
  done
  cat <<'EOF'
              while :; do
                sleep 3600 &
                wait $!
              done
          readinessProbe:
            exec:
              command:
                - /bin/sh
                - -ec
                - nsenter -t 1 -n -- tc qdisc show dev "$NETWORK_INTERFACE" | grep -q 'qdisc netem 30:'
            initialDelaySeconds: 1
            periodSeconds: 2
EOF
}

write_manifest() {
  local node_template
  local node_entry node_name node_ip pod_cidr node_group
  local source_entry source_node source_group
  local target_entry target_node target_ip target_cidr target_group target_network
  local -a nodes target_cidrs

  node_template='{{range .items}}{{.metadata.name}}{{"\t"}}{{range .status.addresses}}{{if eq .type "InternalIP"}}{{.address}}{{end}}{{end}}{{"\t"}}{{.spec.podCIDR}}{{"\t"}}{{index .metadata.labels "'"$node_group_label"'"}}{{"\n"}}{{end}}'
  local selector_args=()
  if [[ -n "$node_selector" ]]; then
    selector_args=(-l "$node_selector")
  fi
  mapfile -t nodes < <(
    "$kubectl_bin" get nodes "${selector_args[@]}" -o "go-template=$node_template" |
      sort
  )

  if [[ "${#nodes[@]}" -lt 2 ]]; then
    echo "expected at least two selected Kubernetes nodes" >&2
    return 1
  fi

  for node_entry in "${nodes[@]}"; do
    IFS=$'\t' read -r node_name node_ip pod_cidr node_group <<<"$node_entry"
    if [[ -z "$node_ip" ]]; then
      echo "node $node_name has no InternalIP" >&2
      return 1
    fi
    if [[ -z "$pod_cidr" || "$pod_cidr" == "<no value>" ]]; then
      echo "node $node_name has no PodCIDR" >&2
      return 1
    fi
    if [[ -z "$node_group" || "$node_group" == "<no value>" ]]; then
      echo "node $node_name is missing label $node_group_label" >&2
      return 1
    fi
  done

  echo "# Generated by chaos-injector/chaos-injector.sh"
  echo "# Node groups: $node_group_label"
  enable_latency="$(bool_value "$enable_latency")"
  enable_bandwidth="$(bool_value "$enable_bandwidth")"
  enable_packet_loss="$(bool_value "$enable_packet_loss")"
  host_network="$(bool_value "$host_network")"
  echo "# Enabled impairments: latency=$enable_latency bandwidth=$enable_bandwidth packet_loss=$enable_packet_loss"
  echo "# Cross-group latency: $cross_zone_latency jitter=$jitter correlation=$correlation"
  echo "# Cross-group bandwidth: ${cross_zone_bandwidth_bytes_per_second:-disabled} bytes/s"
  echo "# Cross-group packet loss: $packet_loss"
  echo "# Shaped interface: $network_interface"
  echo "# Target network: $([[ "$host_network" == "true" ]] && printf 'node InternalIPs' || printf 'PodCIDRs')"

  if [[ "$enable_latency" != "true" && "$enable_bandwidth" != "true" && "$enable_packet_loss" != "true" ]]; then
    echo "at least one of ENABLE_LATENCY, ENABLE_BANDWIDTH, or ENABLE_PACKET_LOSS must be true" >&2
    return 1
  fi
  if [[ "$enable_bandwidth" == "true" ]]; then
    if [[ -z "$cross_zone_bandwidth_bytes_per_second" ]]; then
      echo "CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND is required when ENABLE_BANDWIDTH=true" >&2
      return 1
    fi
    if ! [[ "$cross_zone_bandwidth_bytes_per_second" =~ ^([1-9][0-9]*([.][0-9]+)?|0[.][0-9]*[1-9][0-9]*)$ ]]; then
      echo "CROSS_ZONE_BANDWIDTH_BYTES_PER_SECOND must be a positive numeric bytes-per-second value" >&2
      return 1
    fi
  fi

  for source_entry in "${nodes[@]}"; do
    IFS=$'\t' read -r source_node _ _ source_group <<<"$source_entry"
    target_cidrs=()
    for target_entry in "${nodes[@]}"; do
      IFS=$'\t' read -r target_node target_ip target_cidr target_group <<<"$target_entry"
      if [[ "$source_node" == "$target_node" || "$source_group" == "$target_group" ]]; then
        continue
      fi
      if [[ "$host_network" == "true" ]]; then
        target_network="$target_ip/32"
      else
        target_network="$target_cidr"
      fi
      target_cidrs+=("$target_network")
    done
    if [[ "${#target_cidrs[@]}" -gt 0 ]]; then
      write_daemonset "$source_node" "$source_group" "${target_cidrs[@]}"
    fi
  done
}

generate() {
  local manifest="${1:-$default_manifest}"
  local temporary_manifest="${manifest}.tmp"

  if [[ $# -gt 1 ]]; then
    echo "generate accepts at most one manifest path" >&2
    usage >&2
    exit 2
  fi

  trap 'rm -f -- "$temporary_manifest"' RETURN
  write_manifest >"$temporary_manifest"
  mv -- "$temporary_manifest" "$manifest"
  trap - RETURN
  echo "generated $manifest"
}

deploy() {
  local manifest="${1:-$default_manifest}"

  if [[ $# -gt 1 ]]; then
    echo "deploy accepts at most one manifest path" >&2
    usage >&2
    exit 2
  fi

  generate "$manifest"
  "$kubectl_bin" delete daemonset \
    -n "$chaos_namespace" \
    -l app.kubernetes.io/managed-by=node-latency-chaos-injector \
    --ignore-not-found=true --wait=true
  "$kubectl_bin" delete networkchaos \
    --all-namespaces \
    -l app.kubernetes.io/managed-by=node-latency-chaos-injector \
    --ignore-not-found=true --wait=true
  apply_manifests "$manifest"
  "$kubectl_bin" rollout status daemonset \
    -n "$chaos_namespace" \
    -l app.kubernetes.io/managed-by=node-latency-chaos-injector \
    --timeout=2m
}

apply_manifests() {
  local manifests=("$@")
  if [[ ${#manifests[@]} -eq 0 ]]; then
    manifests=("$default_manifest")
  fi

  for manifest in "${manifests[@]}"; do
    require_manifest "$manifest"
    "$kubectl_bin" apply -f "$manifest"
  done
}

delete_manifests() {
  local manifests=("$@")
  if [[ ${#manifests[@]} -eq 0 ]]; then
    manifests=("$default_manifest")
  fi

  for manifest in "${manifests[@]}"; do
    require_manifest "$manifest"
    "$kubectl_bin" delete --ignore-not-found=true --wait=true -f "$manifest"
  done
  "$kubectl_bin" delete networkchaos \
    --all-namespaces \
    -l app.kubernetes.io/managed-by=node-latency-chaos-injector \
    --ignore-not-found=true --wait=true
}

command="${1:-}"
if [[ $# -gt 0 ]]; then
  shift
fi

case "$command" in
  generate)
    generate "$@"
    ;;
  deploy)
    deploy "$@"
    ;;
  apply)
    apply_manifests "$@"
    ;;
  delete)
    delete_manifests "$@"
    ;;
  help | --help | -h)
    usage
    ;;
  '')
    usage >&2
    exit 2
    ;;
  *)
    echo "unknown command: $command" >&2
    usage >&2
    exit 2
    ;;
esac
