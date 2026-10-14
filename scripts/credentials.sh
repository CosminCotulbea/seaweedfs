#!/bin/sh
# Creates the bucket (when missing) and an S3 user restricted to it, and prints
# its keys. One user per application and bucket — unlike a root key, a leaked
# one exposes that bucket only.
cd scripts || exit
set -eu
. ./weed-shell.sh

echo
ask_bucket

DEFAULT_NAME=${BUCKET#bucket-}
printf "User name [default: %s]: " "$DEFAULT_NAME"
read -r NAME
NAME=${NAME:-$DEFAULT_NAME}
if ! printf '%s' "$NAME" | grep -qE '^[A-Za-z0-9._-]+$'; then
    echo "Invalid user name: letters, digits, dots, underscores and hyphens only"
    exit 1
fi

if weed_shell "s3.bucket.list" | grep -qE "^[[:space:]]*${BUCKET}([[:space:]]|$)"; then
    echo "Bucket ${BUCKET} already exists."
else
    weed_shell "s3.bucket.create -name ${BUCKET}"
fi

OUT=$(weed_shell "s3.user.provision -name ${NAME} -bucket ${BUCKET} -role readwrite")
ACCESS_KEY=$(printf '%s\n' "$OUT" | sed -n 's/^Access Key: *//p')
SECRET_KEY=$(printf '%s\n' "$OUT" | sed -n 's/^Secret Key: *//p')

if [ -z "$ACCESS_KEY" ] || [ -z "$SECRET_KEY" ]; then
    echo
    echo "Failed to create user ${NAME}:"
    printf '%s\n' "$OUT"
    exit 1
fi

DOMAIN_HOST=$(sed -n 's/^DOMAIN_HOST=//p' .env | tail -n 1 | tr -d '\r"')

echo
echo "Save these now — the secret key cannot be retrieved later. For a Laravel .env:"
echo
echo "AWS_ACCESS_KEY_ID=${ACCESS_KEY}"
echo "AWS_SECRET_ACCESS_KEY=${SECRET_KEY}"
echo "AWS_DEFAULT_REGION=us-east-1"
echo "AWS_BUCKET=${BUCKET}"
echo "AWS_ENDPOINT=https://${DOMAIN_HOST}"
echo "AWS_URL=https://${DOMAIN_HOST}/${BUCKET}"
echo "AWS_USE_PATH_STYLE_ENDPOINT=true"
echo
