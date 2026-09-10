#!/usr/bin/env bash
# Stop the live upload test servers. Pass --clean to also delete ./state (the
# generated keys, certificates, password and uploaded files).
set -euo pipefail
cd "$(dirname "$0")"
# compose interpolates the file even to tear it down, and these are required
# there so a stale hard-coded credential cannot creep back in.
export LUMESHOT_TEST_HOST="${LUMESHOT_TEST_HOST:-127.0.0.1}"
export LUMESHOT_TEST_PASSWORD="$(cat state/password 2>/dev/null || echo unused-for-teardown)"
docker compose down -v --remove-orphans
if [ "${1:-}" = "--clean" ]; then
    chmod -R u+w state 2>/dev/null || true
    rm -rf state
    echo "Removed ./state"
fi
