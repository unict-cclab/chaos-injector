#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_dir="$(mktemp -d)"
trap 'rm -rf -- "$tmp_dir"' EXIT

fake_kubectl="$tmp_dir/kubectl"
manifest="$tmp_dir/node-shaping.yaml"

cat >"$fake_kubectl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == "get" && "$2" == "nodes" ]]; then
  printf '%s\n' \
    $'app-01\t192.168.1.11\t10.42.1.0/24\tzone-a' \
    $'app-02\t192.168.1.12\t10.42.2.0/24\tzone-a' \
    $'app-03\t192.168.1.13\t10.42.3.0/24\tzone-b' \
    $'app-04\t192.168.1.14\t10.42.4.0/24\tzone-b'
  exit 0
fi
echo "unexpected kubectl invocation: $*" >&2
exit 1
EOF
chmod +x "$fake_kubectl"

KUBECTL="$fake_kubectl" \
NODE_SELECTOR=nodepool=app \
CROSS_ZONE_LATENCY=100ms \
  "$repo_dir/chaos-injector.sh" generate "$manifest" >/dev/null

[[ "$(grep -c '^kind: DaemonSet$' "$manifest")" -eq 4 ]]

app_01="$(sed -n '/name: node-delay-app-01$/,/^---$/p' "$manifest")"
grep -q '10.42.3.0/24' <<<"$app_01"
grep -q '10.42.4.0/24' <<<"$app_01"
if grep -qE '10\.42\.[12]\.0/24' <<<"$app_01"; then
  echo "app-01 shaper unexpectedly targets a same-zone PodCIDR" >&2
  exit 1
fi

if grep -qE '10\.42\.(0|5)\.0/24' "$manifest"; then
  echo "manifest unexpectedly targets an unselected node PodCIDR" >&2
  exit 1
fi

echo "generate_test: PASS"
