#!/bin/sh
set -eu

fail() {
  echo "错误：$*" >&2
  exit 1
}

[ -n "${DEVICE_UUID:-}" ] || fail '缺少 DEVICE_UUID 环境变量'
[ "$#" -gt 0 ] || fail '缺少启动命令'

state_dir=${ITDOG_AGENT_STATE_DIR:-/opt/itdog-agent}
sha_file=${ITDOG_AGENT_SHA256_FILE:-/usr/local/share/itdog-agent.sha256}
marker="$state_dir/.agent-identity"

mkdir -p "$state_dir"
[ -r "$sha_file" ] || fail "无法读取 agent SHA-256：$sha_file"

agent_sha256=$(sed -n '1p' "$sha_file")
[ -n "$agent_sha256" ] || fail "agent SHA-256 为空：$sha_file"
identity="$agent_sha256:$DEVICE_UUID"

if [ ! -f "$marker" ] || [ "$(cat "$marker")" != "$identity" ]; then
  rm -f "$state_dir/node_id"
  marker_tmp="$marker.tmp.$$"
  printf '%s\n' "$identity" > "$marker_tmp"
  mv "$marker_tmp" "$marker"
fi

exec "$@"
