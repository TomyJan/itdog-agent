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

if [ "${CURL_SEND_TERM:-0}" = 1 ]; then
  kill -TERM "$PPID"
  exit 0
fi

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

cat > "$fake_bin/tar" <<'EOF'
#!/bin/sh
set -eu

for option do
  case "$option" in
    -t*)
      if [ "${TAR_FORCE_TRAVERSAL:-0}" = 1 ]; then
        printf '../../outside\n'
        exit 0
      fi
      ;;
  esac
done

exec /usr/bin/tar "$@"
EOF

chmod +x "$fake_bin/curl" "$fake_bin/file" "$fake_bin/tar"

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

assert_unsafe_archive_path_fails() {
  error_log="$test_root/unsafe-archive.log"
  if TAR_FORCE_TRAVERSAL=1 run_download >"$error_log" 2>&1; then
    echo 'not ok - unsafe archive path should fail' >&2
    exit 1
  fi
  grep -q '归档路径不安全' "$error_log"
  echo 'ok - rejects unsafe archive paths'
}

assert_term_signal_exits_immediately() {
  error_log="$test_root/term-signal.log"
  set +e
  CURL_SEND_TERM=1 run_download >"$error_log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 143 ]; then
    echo "not ok - TERM should exit with 143, got $status" >&2
    exit 1
  fi
  echo 'ok - TERM exits immediately with signal status'
}

assert_successful_download
assert_wrong_architecture_fails
assert_unsafe_archive_path_fails
assert_term_signal_exits_immediately
