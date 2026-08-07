#!/bin/sh
set -eu

repo_root=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

if command -v python3 >/dev/null 2>&1 \
  && python3 -c '' >/dev/null 2>&1; then
  python=python3
elif command -v python >/dev/null 2>&1 \
  && python -c '' >/dev/null 2>&1; then
  python=python
else
  python=''
fi

config=$(
  DEVICE_UUID=00000000-0000-0000-0000-000000000000 \
    docker compose \
      --project-directory "$repo_root" \
      --file "$repo_root/compose.yaml" \
      config --format json
)

if [ -n "$python" ]; then
  printf '%s\n' "$config" | "$python" -c '
import json
import sys

config = json.load(sys.stdin)
if config.get("networks", {}).get("default", {}).get("enable_ipv6") is not True:
    print("not ok - default Compose network must enable IPv6", file=sys.stderr)
    raise SystemExit(1)
'
elif command -v node >/dev/null 2>&1; then
  printf '%s\n' "$config" | node -e '
const fs = require("fs");
const config = JSON.parse(fs.readFileSync(0, "utf8"));
if (config.networks?.default?.enable_ipv6 !== true) {
  console.error("not ok - default Compose network must enable IPv6");
  process.exit(1);
}
'
else
  echo 'not ok - Python or Node.js is required to inspect Compose JSON' >&2
  exit 1
fi

echo 'ok - enables IPv6 on the default Compose network'
