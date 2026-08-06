#!/bin/sh
set -eu

fail() {
  echo "错误：$*" >&2
  exit 1
}

[ "$#" -eq 1 ] || fail '用法: download-agent.sh OUTPUT_DIR'

output_dir=$1
base_url=${ITDOG_AGENT_BASE_URL:-https://dl.itdog.cn/agent}
tmp_dir=$(mktemp -d)

cleanup() {
  rm -rf "$tmp_dir"
}
trap cleanup EXIT HUP INT TERM

validate_architecture() {
  agent=$1
  arch=$2
  description=$(file "$agent")

  case "$arch:$description" in
    amd64:*'ELF 64-bit'*'x86-64'*) ;;
    arm64:*'ELF 64-bit'*'ARM aarch64'*) ;;
    *) fail "$arch agent 架构不匹配：$description" ;;
  esac
}

normalized_dir="$tmp_dir/normalized"
mkdir -p "$normalized_dir"

for arch in amd64 arm64; do
  archive="$tmp_dir/agent_${arch}.tar.gz"
  extract_dir="$tmp_dir/extract-$arch"
  mkdir -p "$extract_dir"

  curl \
    --fail \
    --location \
    --retry 3 \
    --proto '=https' \
    --tlsv1.2 \
    "$base_url/agent_${arch}.tar.gz" \
    --output "$archive"

  members=$(tar -tzf "$archive") || fail "$arch 压缩包目录列表读取失败"
  if printf '%s\n' "$members" | grep -Eq '(^/|(^|/)\.\.(/|$))'; then
    fail "$arch 压缩包包含归档路径不安全的成员"
  fi
  tar -xzf "$archive" -C "$extract_dir"
  agent=$(find "$extract_dir" -type f -name agent -print -quit)
  [ -n "$agent" ] || fail "$arch 压缩包中未找到 agent 可执行文件"

  validate_architecture "$agent" "$arch"
  install -m 0755 "$agent" "$normalized_dir/agent_$arch"
done

mkdir -p "$output_dir"
install -m 0755 "$normalized_dir/agent_amd64" "$output_dir/agent_amd64"
install -m 0755 "$normalized_dir/agent_arm64" "$output_dir/agent_arm64"
