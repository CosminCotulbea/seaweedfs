#!/bin/sh
# Interactive `weed shell` for everything the other scripts do not cover
# (s3.user.list, s3.bucket.quota, s3.accesskey.rotate, volume.list, ...).
# `help` lists the commands, `<command> -h` their flags.
docker exec -it seaweedfs weed shell -master=seaweedfs:9333
