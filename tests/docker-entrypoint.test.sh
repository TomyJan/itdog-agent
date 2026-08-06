#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT HUP INT TERM

state_dir="$test_root/state"
sha_file="$test_root/agent.sha256"
mkdir -p "$state_dir"
printf 'hash-a\n' > "$sha_file"

run_entrypoint() {
  DEVICE_UUID=$1 \
    ITDOG_AGENT_STATE_DIR="$state_dir" \
    ITDOG_AGENT_SHA256_FILE="$sha_file" \
    sh "$repo_root/docker-entrypoint.sh" true
}

assert_missing_uuid_fails() {
  error_log="$test_root/missing-uuid.log"
  if env -u DEVICE_UUID \
    ITDOG_AGENT_STATE_DIR="$state_dir" \
    ITDOG_AGENT_SHA256_FILE="$sha_file" \
    sh "$repo_root/docker-entrypoint.sh" true >"$error_log" 2>&1; then
    echo 'not ok - missing DEVICE_UUID should fail' >&2
    exit 1
  fi
  grep -q 'DEVICE_UUID' "$error_log"
  echo 'ok - rejects a missing DEVICE_UUID'
}

assert_first_start_resets_node_id() {
  printf 'stale-node\n' > "$state_dir/node_id"
  run_entrypoint uuid-a
  test ! -e "$state_dir/node_id"
  test "$(cat "$state_dir/.agent-identity")" = 'hash-a:uuid-a'
  echo 'ok - first start resets stale node identity'
}

assert_same_identity_keeps_node_id() {
  printf 'current-node\n' > "$state_dir/node_id"
  run_entrypoint uuid-a
  test "$(cat "$state_dir/node_id")" = 'current-node'
  echo 'ok - restart with the same identity keeps node_id'
}

assert_uuid_change_resets_node_id() {
  run_entrypoint uuid-b
  test ! -e "$state_dir/node_id"
  test "$(cat "$state_dir/.agent-identity")" = 'hash-a:uuid-b'
  echo 'ok - UUID change resets node_id'
}

assert_agent_change_resets_node_id() {
  printf 'current-node\n' > "$state_dir/node_id"
  printf 'hash-b\n' > "$sha_file"
  run_entrypoint uuid-b
  test ! -e "$state_dir/node_id"
  test "$(cat "$state_dir/.agent-identity")" = 'hash-b:uuid-b'
  echo 'ok - agent change resets node_id'
}

assert_missing_uuid_fails
assert_first_start_resets_node_id
assert_same_identity_keeps_node_id
assert_uuid_change_resets_node_id
assert_agent_change_resets_node_id
