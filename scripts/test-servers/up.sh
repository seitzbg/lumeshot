#!/usr/bin/env bash
# Start the live SFTP/FTP servers the LumeshotUpload integration tests need, and
# print the environment that enables them. Everything it generates lands in
# ./state, which is gitignored — no key, certificate or password is ever
# committed.
#
#   ./up.sh                            # bind to loopback only
#   LUMESHOT_TEST_HOST=192.0.2.1 ./up.sh   # reachable from another machine
#
# The servers hold a writable account, so LAN exposure is opt-in: pass the
# address explicitly when the Swift toolchain and Docker are on different hosts.
set -euo pipefail
cd "$(dirname "$0")"

HOST="${LUMESHOT_TEST_HOST:-127.0.0.1}"
SFTP_PORT="${LUMESHOT_TEST_SFTP_PORT:-2222}"
FTP_PORT="${LUMESHOT_TEST_FTP_PORT:-2121}"
HTTP_PORT="${LUMESHOT_TEST_HTTP_PORT:-8080}"
S=state

mkdir -p "$S/keys/pub" "$S/sftp-upload" "$S/ftp-home" "$S/tls"
# The container users are uid 1001; these are throwaway lab directories on a
# bind mount, so widen them rather than requiring root to chown. After a run the
# server owns them and chmod fails with nothing left to widen — a first-run
# failure would surface as a failing upload test, not silence.
chmod 777 "$S/sftp-upload" "$S/ftp-home" 2>/dev/null || true

# One password per ./state, not a constant in the compose file — the servers are
# throwaway, but a fixed credential on a published port is not something to ship
# in a repo.
if [ ! -f "$S/password" ]; then
    # `tr -dc … </dev/urandom | head -c 32` reads naturally but aborts the whole
    # script under `set -o pipefail`: head closes the pipe once it has 32 bytes,
    # tr is then killed by SIGPIPE (141), and pipefail makes that the pipeline's
    # exit status — so a fresh setup died here before generating keys or starting
    # Docker. openssl reads a finite amount and has no such failure mode; 16 bytes
    # is 32 hex characters (128 bits), ample for a throwaway lab account.
    (umask 077; openssl rand -hex 16 > "$S/password")
fi
PASSWORD="$(cat "$S/password")"

gen_key() {   # gen_key <name> <type> <passphrase-or-empty>
    local name=$1 type=$2 pass=$3
    [ -f "$S/keys/$name" ] && return
    ssh-keygen -q -t "$type" -N "$pass" -C "lumeshot-test-$name" -f "$S/keys/$name"
    cp "$S/keys/$name.pub" "$S/keys/pub/$name.pub"
}
# Three keys, because CitadelSFTPTransport has three distinct branches: an
# ed25519 key, an ed25519 key that needs a passphrase, and an RSA key (which it
# only reaches after the ed25519 parse fails).
gen_key ed25519 ed25519 ''
gen_key ed25519-pass ed25519 'lumepassphrase'
gen_key rsa rsa ''

if [ ! -f "$S/tls/pure-ftpd.pem" ]; then
    # pure-ftpd wants the key and certificate concatenated in one file. The CA is
    # kept so a test can point a TLS client at it instead of disabling
    # verification.
    openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
        -keyout "$S/tls/server.key" -out "$S/tls/server.crt" \
        -subj "/CN=lumeshot-test-ftp" \
        -addext "subjectAltName=IP:$HOST,IP:127.0.0.1,DNS:localhost" >/dev/null 2>&1
    cat "$S/tls/server.key" "$S/tls/server.crt" > "$S/tls/pure-ftpd.pem"
    cp "$S/tls/server.crt" "$S/tls/ca.pem"
    chmod 644 "$S/tls/pure-ftpd.pem"
fi

export LUMESHOT_TEST_HOST="$HOST" LUMESHOT_TEST_PASSWORD="$PASSWORD" \
       LUMESHOT_TEST_SFTP_PORT="$SFTP_PORT" LUMESHOT_TEST_FTP_PORT="$FTP_PORT" \
       LUMESHOT_TEST_HTTP_PORT="$HTTP_PORT"
docker compose up -d

echo
echo "Waiting for the servers to accept connections…"
ready() {   # every port a test touches, including the one that serves result URLs
    for port in "$SFTP_PORT" "$FTP_PORT" "$HTTP_PORT"; do
        nc -z "$HOST" "$port" 2>/dev/null || return 1
    done
}
deadline=$((SECONDS + 60))
until ready; do
    if [ "$SECONDS" -ge "$deadline" ]; then
        echo "Timed out waiting for $HOST ports $SFTP_PORT/$FTP_PORT/$HTTP_PORT." >&2
        docker compose ps >&2
        exit 1
    fi
    sleep 1
done

cat <<ENV

Export these where \`swift test\` runs (the integration tests skip themselves
when LUMESHOT_LIVE_UPLOAD_HOST is unset):

export LUMESHOT_LIVE_UPLOAD_HOST=$HOST
export LUMESHOT_LIVE_SFTP_PORT=$SFTP_PORT
export LUMESHOT_LIVE_FTP_PORT=$FTP_PORT
export LUMESHOT_LIVE_USER=lume
export LUMESHOT_LIVE_PASSWORD=$PASSWORD
export LUMESHOT_LIVE_KEY_DIR=$(pwd)/$S/keys
export LUMESHOT_LIVE_HTTP_BASE=http://$HOST:$HTTP_PORT
ENV
