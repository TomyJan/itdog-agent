#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

fixtures="$test_root/fixtures"
fake_bin="$test_root/bin"
output_dir="$test_root/output"
mkdir -p "$fixtures/amd64" "$fixtures/arm64" "$fake_bin"

printf 'amd64 agent fixture\n' > "$fixtures/amd64/agent"
printf 'arm64 agent fixture\n' > "$fixtures/arm64/agent"
tar -czf "$fixtures/agent_amd64.tar.gz" -C "$fixtures/amd64" agent
tar -czf "$fixtures/agent_arm64.tar.gz" -C "$fixtures/arm64" agent

cat > "$fake_bin/curl" <<'EOF'
#!/bin/sh
set -eu

output=''
url=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --output)
      shift
      output=$1
      ;;
    https://*)
      url=$1
      ;;
  esac
  shift
done

case "$url" in
  */agent_amd64.tar.gz) archive="$FIXTURE_DIR/agent_amd64.tar.gz" ;;
  */agent_arm64.tar.gz) archive="$FIXTURE_DIR/agent_arm64.tar.gz" ;;
  *) echo "unexpected URL: $url" >&2; exit 1 ;;
esac

cp "$archive" "$output"
EOF

cat > "$fake_bin/file" <<'EOF'
#!/bin/sh
set -eu

for target do :; done
if [ "${FILE_FORCE_WRONG_ARCH:-0}" = 1 ]; then
  printf '%s: ELF 64-bit LSB executable, x86-64\n' "$target"
  exit 0
fi

case "$target" in
  *amd64*) description='ELF 64-bit LSB executable, x86-64' ;;
  *arm64*) description='ELF 64-bit LSB executable, ARM aarch64' ;;
  *) echo "unexpected file target: $target" >&2; exit 1 ;;
esac
printf '%s: %s\n' "$target" "$description"
EOF

chmod +x "$fake_bin/curl" "$fake_bin/file"

run_download() {
  rm -rf "$output_dir"
  PATH="$fake_bin:$PATH" \
    FIXTURE_DIR="$fixtures" \
    ITDOG_AGENT_BASE_URL='https://fixtures.invalid' \
    sh "$repo_root/scripts/download-agent.sh" "$output_dir"
}

assert_successful_download() {
  run_download
  cmp "$fixtures/amd64/agent" "$output_dir/agent_amd64"
  cmp "$fixtures/arm64/agent" "$output_dir/agent_arm64"
  test -x "$output_dir/agent_amd64"
  test -x "$output_dir/agent_arm64"
  echo 'ok - downloads and installs both architectures'
}

assert_wrong_architecture_fails() {
  error_log="$test_root/wrong-architecture.log"
  if FILE_FORCE_WRONG_ARCH=1 run_download >"$error_log" 2>&1; then
    echo 'not ok - architecture mismatch should fail' >&2
    exit 1
  fi
  grep -q 'arm64.*架构' "$error_log"
  echo 'ok - rejects an architecture mismatch'
}

assert_successful_download
assert_wrong_architecture_fails
