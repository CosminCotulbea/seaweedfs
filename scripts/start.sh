#!/bin/sh
echo
echo "===== Starting... ====="
echo

cd scripts || exit
. ./compose.sh
host_proxy_check

if ! $COMPOSE up -d; then
    echo
    echo "===== ERROR: 'up -d' failed, containers not started — host nginx left untouched ====="
    echo
    exit 1
fi
host_proxy_configure

echo
echo "===== Done! ====="
echo
