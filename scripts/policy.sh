#!/bin/sh
# Makes the objects of a bucket publicly readable by key: anonymous GET is
# allowed, while listing, uploading and deleting still need a key.
cd scripts || exit
set -eu
. ./weed-shell.sh

echo
ask_bucket

weed_shell "s3.anonymous.set -bucket ${BUCKET} -access Read"

echo
echo "OK: anonymous read (GetObject only, no listing) applied to bucket '${BUCKET}'."
