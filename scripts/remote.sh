#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

MAC_HOST="${LUMESHOT_MAC_HOST:-seitz@macmini1.fiber.house}"
MAC_DIR="${LUMESHOT_MAC_DIR:-git/lumeshot}"   # relative to remote $HOME

cmd="${1:-build}"
shift || true

ssh "$MAC_HOST" "mkdir -p $MAC_DIR"
rsync -az --delete --exclude '.git' --exclude '.build' --exclude 'dist' ./ "$MAC_HOST:$MAC_DIR/"

case "$cmd" in
  build)  ssh "$MAC_HOST" "cd $MAC_DIR && swift build 2>&1" ;;
  test)   ssh "$MAC_HOST" "cd $MAC_DIR && swift test 2>&1" ;;
  bundle) ssh "$MAC_HOST" "cd $MAC_DIR && swift build -c release 2>&1 && scripts/bundle.sh" ;;
  run)    ssh "$MAC_HOST" "cd $MAC_DIR && swift build -c release 2>&1 && scripts/bundle.sh && { pkill -f 'Lumeshot.app/Contents/MacOS/LumeshotApp' 2>/dev/null; sleep 1; pkill -9 -f 'Lumeshot.app/Contents/MacOS/LumeshotApp' 2>/dev/null; sleep 1; open \"dist/Lumeshot.app\" --args $*; }" ;;
  ssh)    ssh "$MAC_HOST" "cd $MAC_DIR && $*" ;;
  *) echo "usage: remote.sh {build|test|bundle|run|ssh <cmd>}" >&2; exit 2 ;;
esac
