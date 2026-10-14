#!/bin/sh
# Nothing is built here — both images are published upstream. Kept under this
# name for parity with the other stacks: it refreshes the images and recreates
# the containers.
cd scripts || exit
. ./compose.sh
host_proxy_check

echo
printf "Do you want to update images before recreating? (y/n) [default: y]: "
read -r UPDATE_IMAGES
UPDATE_IMAGES=${UPDATE_IMAGES:-y}

if [ "$UPDATE_IMAGES" = "y" ] || [ "$UPDATE_IMAGES" = "Y" ]; then
    echo
    echo "===== Updating images... ====="
    echo

    if ! $COMPOSE pull; then
        echo
        echo "===== ERROR: pull failed — containers and host nginx left untouched ====="
        echo
        exit 1
    fi
fi

echo
echo "===== Recreating containers... ====="
echo

if ! $COMPOSE up -d --force-recreate; then
    echo
    echo "===== ERROR: 'up -d' failed, containers not started — host nginx left untouched ====="
    echo
    exit 1
fi
host_proxy_configure

echo
echo "===== Done! ====="
echo
