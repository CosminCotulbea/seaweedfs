#!/bin/sh
# Shared by credentials.sh and policy.sh, sourced after `cd scripts`.

NODE="seaweedfs"

# Runs one `weed shell` command inside the container and prints its output,
# without the shell's own banner and prompt lines.
weed_shell() {
    printf '%s\n' "$1" | docker exec -i "$NODE" weed shell -master=seaweedfs:9333 2>&1 \
        | grep -v -e '^master: ' -e '^> *$' -e '^$' || true
}

# Asks for a bucket name and checks it. The name ends up inside a `weed shell`
# command line, so only the characters S3 allows are accepted; the bucket-
# prefix is what nginx/custom.conf routes to the S3 gateway.
ask_bucket() {
    printf "Bucket name (bucket-<name>): "
    read -r BUCKET
    case "$BUCKET" in
        bucket-*) ;;
        *) echo "Bucket names must start with 'bucket-' — nginx routes only those to S3"; exit 1 ;;
    esac
    if ! printf '%s' "$BUCKET" | grep -qE '^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$'; then
        echo "Invalid bucket name: 3-63 characters, lowercase letters, digits, dots and hyphens"
        exit 1
    fi
}
