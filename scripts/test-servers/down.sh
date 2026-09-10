#!/usr/bin/env bash
# Stop the live upload test servers. Pass --clean to also delete ./state (the
# generated keys, certificates and uploaded files).
set -euo pipefail
cd "$(dirname "$0")"
docker compose down -v --remove-orphans
if [ "${1:-}" = "--clean" ]; then
    chmod -R u+w state 2>/dev/null || true
    rm -rf state
    echo "Removed ./state"
fi
