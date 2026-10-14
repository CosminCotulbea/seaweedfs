#!/bin/sh
echo
echo "===== Stopping... ====="
echo

cd scripts || exit
. ./compose.sh

$COMPOSE down

echo
echo "===== Done! ====="
echo
