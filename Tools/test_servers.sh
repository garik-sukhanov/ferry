#!/bin/bash
# Spins up throwaway FTP/SFTP servers in docker for `swift test`.
# Usage: Tools/test_servers.sh up | down
set -euo pipefail
cd "$(dirname "$0")/.."

DATA=".testdata"
KEY="$DATA/ferry_key"

case "${1:-up}" in
up)
    mkdir -p "$DATA/sftp_share" "$DATA/ftp_share"
    echo "hello from ferry test" > "$DATA/sftp_share/readme.txt"
    echo "ftp test file"         > "$DATA/ftp_share/hello.txt"

    if [ ! -f "$KEY" ]; then
        ssh-keygen -t ed25519 -f "$KEY" -N "" -C "ferry-test" >/dev/null
    fi

    docker rm -f ferry-sftp ferry-ftp >/dev/null 2>&1 || true

    docker run -d --name ferry-sftp -p 2222:22 \
        -v "$PWD/$DATA/sftp_share:/home/tester/share" \
        -v "$PWD/$KEY.pub:/home/tester/.ssh/keys/id_ed25519.pub:ro" \
        atmoz/sftp:alpine tester:secret123:501 >/dev/null

    docker run -d --name ferry-ftp -p 2121:21 -p 21000-21010:21000-21010 \
        -e USERS="tester|secret123|/ftp/tester|501" -e ADDRESS=localhost \
        -v "$PWD/$DATA/ftp_share:/ftp/tester" \
        delfer/alpine-ftp-server >/dev/null

    # A recreated container gets a new host key; drop the stale entry.
    ssh-keygen -R "[127.0.0.1]:2222" >/dev/null 2>&1 || true
    sleep 5
    echo "✓ SFTP :2222 и FTP :2121 подняты (tester / secret123, ключ: $KEY)"
    ;;
down)
    docker rm -f ferry-sftp ferry-ftp >/dev/null 2>&1 || true
    echo "✓ контейнеры остановлены"
    ;;
*)
    echo "usage: $0 up|down" >&2; exit 1 ;;
esac
