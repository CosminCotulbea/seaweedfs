#!/bin/sh
# Resolves the compose command to use, including the production overlay, and
# refuses to continue without a .env. Sourced by start.sh, down.sh, build.sh
# and restart.sh — all of them cd into scripts/ first, so .env and both compose
# files are in the current directory.
#
# Sourced rather than executed, because the caller needs $COMPOSE in its own
# shell. That also means the `exit` below terminates the calling script, which
# is the intent — do not source this from an interactive shell.

if [ ! -f .env ]; then
    echo
    echo "===== ERROR: scripts/.env not found ====="
    echo
    echo "Create it from the template and fill it in:"
    echo
    echo "    cp scripts/.env.example scripts/.env"
    echo
    echo "Then set at least DOMAIN_HOST, SELF_SIGNED_HOST (only on local environment)"
    echo "and the ADMIN_USER / ADMIN_PASSWORD credentials of the admin UI."
    echo
    exit 1
fi

# Created here rather than by Docker on the first bind mount, which would make
# them root-owned on the host.
mkdir -p ../data/seaweedfs ../data/admin

# docker compose first: !reset / !override in the production overlay need
# Compose v2.24+, and the legacy docker-compose binary may still be v1.
if docker compose version >/dev/null 2>&1; then
    COMPOSE="docker compose"
elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE="docker-compose"
else
    echo
    echo "===== ERROR: docker compose not found ====="
    echo
    echo "Install Docker Compose v2 (the 'docker compose' subcommand)."
    echo
    exit 1
fi

COMPOSE="$COMPOSE -f docker-compose.yml"

# Anchored on the whole line, so a commented or suffixed value is ignored.
if grep -q '^APP_ENV=production[[:space:]]*$' .env; then
    if [ ! -f docker-compose.prod.yml ]; then
        echo
        echo "===== ERROR: APP_ENV=production but scripts/docker-compose.prod.yml is missing ====="
        echo
        exit 1
    fi

    COMPOSE="$COMPOSE -f docker-compose.prod.yml"

    echo "===== Production overlay active ====="
    echo
fi

# The container the host nginx proxies to under PROXY_MODE=host.
HOST_PROXY_CONTAINER=seaweedfs-nginx
. ./host-proxy.sh
