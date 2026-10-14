#!/bin/sh
echo
echo "===== Restarting... ====="
echo

cd scripts || exit
. ./compose.sh

if ! $COMPOSE restart; then
    echo
    echo "===== ERROR: restart failed ====="
    echo
    exit 1
fi

echo
echo "===== Done! ====="
echo
