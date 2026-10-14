#!/bin/sh
# PROXY_MODE support, sourced by compose.sh. Decides who sits in front of the
# nginx container:
#
#   nginx-proxy (default) — the shared nginx-proxy container, routing by
#                           VIRTUAL_HOST over the nginx-proxy network.
#   host                  — the server's own nginx. The nginx container is
#                           published on 127.0.0.1:HOST_PORT (docker-compose.prod.yml)
#                           and host_proxy_configure writes the vhost at
#                           HOST_CONF_PATH and obtains the certificate with certbot.
#
# Callers that bring the stack up run host_proxy_check before `up` and
# host_proxy_configure after it; down.sh and restart.sh need neither.
#
# Kept identical between the mailpit and minio repositories; only
# HOST_PROXY_CONTAINER differs, and the templates in nginx/host/.

# A value from .env, unquoted; empty when the key is absent. The last
# occurrence wins, as it does for Compose.
env_value() {
    sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

PROXY_MODE=$(env_value PROXY_MODE)
PROXY_MODE=${PROXY_MODE:-nginx-proxy}
HOST_PORT=$(env_value HOST_PORT)
HOST_CONF_PATH=$(env_value HOST_CONF_PATH)
DOMAIN_HOST=$(env_value DOMAIN_HOST)
DOMAIN_EMAIL=$(env_value DOMAIN_EMAIL)

case "$PROXY_MODE" in
    nginx-proxy) ;;
    host)
        # HOST_PORT is published by docker-compose.prod.yml only.
        if ! grep -q '^APP_ENV=production[[:space:]]*$' .env; then
            echo
            echo "===== ERROR: PROXY_MODE=host needs APP_ENV=production — HOST_PORT is published by docker-compose.prod.yml ====="
            echo
            exit 1
        fi
        ;;
    *)
        echo
        echo "===== ERROR: unknown PROXY_MODE '${PROXY_MODE}' — use 'nginx-proxy' (default) or 'host' ====="
        echo
        exit 1
        ;;
esac

host_proxy_fail() {
    echo
    echo "===== ERROR: $1 ====="
    echo
    exit 1
}

# Run before `up`. Under nginx-proxy only the shared network is checked; under
# host, everything host_proxy_configure will need, before any container is
# touched.
host_proxy_check() {
    if [ "$PROXY_MODE" = nginx-proxy ]; then
        # Declared `external: true`, so compose refuses to start without it.
        # Not created here: that would hide that the shared nginx-proxy stack
        # is not running, and the site would be unreachable while `up` passed.
        if ! docker network inspect nginx-proxy > /dev/null 2>&1; then
            host_proxy_fail "docker network 'nginx-proxy' not found — start the nginx-proxy stack first"
        fi
        return 0
    fi

    # Still declared external and joined by the containers, and still how
    # other stacks on this host reach this one — only the HTTP routing moves
    # to the host nginx.
    if ! docker network inspect nginx-proxy > /dev/null 2>&1; then
        docker network create nginx-proxy > /dev/null
    fi

    case "$HOST_PORT" in
        '' | *[!0-9]*) host_proxy_fail "PROXY_MODE=host needs HOST_PORT in .env, a port between 1024 and 65535 (got '${HOST_PORT}')" ;;
    esac
    if [ "$HOST_PORT" -lt 1024 ] || [ "$HOST_PORT" -gt 65535 ]; then
        host_proxy_fail "PROXY_MODE=host needs HOST_PORT in .env, a port between 1024 and 65535 (got '${HOST_PORT}')"
    fi
    case "$HOST_CONF_PATH" in
        */) ok=false ;;
        /*) ok=true ;;
        *) ok=false ;;
    esac
    if [ "$ok" = false ] || [ -d "$HOST_CONF_PATH" ]; then
        host_proxy_fail "PROXY_MODE=host needs HOST_CONF_PATH in .env, the absolute path of the vhost *file* (e.g. /etc/nginx/sites-available/${DOMAIN_HOST:-example}.conf), got '${HOST_CONF_PATH}'"
    fi
    if [ -z "$DOMAIN_HOST" ] || [ -z "$DOMAIN_EMAIL" ]; then
        host_proxy_fail "PROXY_MODE=host needs DOMAIN_HOST and DOMAIN_EMAIL in .env — certbot uses both"
    fi

    for tool in ss curl; do
        command -v "$tool" > /dev/null || host_proxy_fail "PROXY_MODE=host needs '${tool}' on the host"
    done

    # Held already is fine only when this stack's nginx is the holder — every
    # start after the first finds it there.
    if [ -n "$(ss -Htln "sport = :${HOST_PORT}")" ] \
        && ! docker port "$HOST_PROXY_CONTAINER" 80 2> /dev/null | grep -q ":${HOST_PORT}\$"; then
        host_proxy_fail "HOST_PORT ${HOST_PORT} is already in use by another process — pick a free one"
    fi

    # Root is needed only for these three, and asked for only for these: the
    # vhost itself is written as this user (see host_proxy_writable).
    # `sudo -l <cmd>` asks the policy without running anything, so a missing
    # rule fails here rather than after the containers were started.
    missing=''
    for cmd in 'nginx -t' 'systemctl reload nginx' 'certbot'; do
        # shellcheck disable=SC2086 # word splitting into command + arguments is the point
        if ! sudo -n -l $cmd > /dev/null 2>&1; then
            missing="${missing}${missing:+, }${cmd}"
        fi
    done
    if [ -n "$missing" ]; then
        echo
        echo "===== ERROR: PROXY_MODE=host runs these as root through passwordless sudo, and $(whoami) may not: ${missing} ====="
        echo
        echo "Add to /etc/sudoers.d/host-proxy (check each path with \`command -v\` — certbot is /snap/bin/certbot when installed as a snap):"
        echo
        echo "    $(whoami) ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /usr/bin/systemctl reload nginx, /usr/bin/certbot"
        echo
        exit 1
    fi

    host_proxy_writable
}

# The sites-enabled link for HOST_CONF_PATH, or empty when it is not under
# sites-available (a conf.d path is loaded directly).
host_proxy_enabled_path() {
    case "$HOST_CONF_PATH" in
        */sites-available/*) printf '%s\n' "$HOST_CONF_PATH" | sed 's|/sites-available/|/sites-enabled/|' ;;
    esac
}

# The vhost is written as this user, never through sudo: a sudo rule for
# `install`, `cp` or `rm` with free arguments is root for anyone holding it
# (overwrite /etc/sudoers and done). So an admin hands over this one file and
# its link once, and the script needs nothing else from them.
host_proxy_writable() {
    enabled=$(host_proxy_enabled_path)
    file_ok=true
    link_ok=true

    if [ -e "$HOST_CONF_PATH" ]; then
        [ -w "$HOST_CONF_PATH" ] || file_ok=false
    else
        dir=$(dirname "$HOST_CONF_PATH")
        { [ -d "$dir" ] && [ -w "$dir" ]; } || file_ok=false
    fi
    if [ -n "$enabled" ] && [ ! -L "$enabled" ]; then
        dir=$(dirname "$enabled")
        { [ -d "$dir" ] && [ -w "$dir" ]; } || link_ok=false
    fi

    if [ "$file_ok" = false ] || [ "$link_ok" = false ]; then
        echo
        echo "===== ERROR: PROXY_MODE=host writes the vhost as $(whoami), without sudo, and needs a hand from an admin once ====="
        echo
        echo "Ask them to run (an empty file is valid nginx config, so it is safe before the first start):"
        echo
        # Only for a file that cannot be written: run against an existing
        # vhost, /dev/null would empty it.
        if [ "$file_ok" = false ]; then
            echo "    sudo install -m 644 -o $(whoami) /dev/null ${HOST_CONF_PATH}"
        fi
        if [ "$link_ok" = false ]; then
            echo "    sudo ln -s ${HOST_CONF_PATH} ${enabled}"
        fi
        echo
        exit 1
    fi
}

# Renders the given templates from nginx/host/ into one file and prints its path.
host_proxy_render() {
    out=$(mktemp)
    for tpl in "$@"; do
        sed -e "s|{{DOMAIN_HOST}}|${DOMAIN_HOST}|g" \
            -e "s|{{HOST_PORT}}|${HOST_PORT}|g" \
            "nginx/host/${tpl}" >> "$out"
    done
    echo "$out"
}

# Puts a rendered vhost at HOST_CONF_PATH and reloads nginx — or, when
# `nginx -t` rejects it, puts back what was there and aborts, so a bad template
# never takes down the other sites served by the same nginx.
host_proxy_install() {
    new=$1
    backup=''
    created_file=false
    created_link=false
    enabled=$(host_proxy_enabled_path)

    if [ -f "$HOST_CONF_PATH" ] && cmp -s "$new" "$HOST_CONF_PATH" && { [ -z "$enabled" ] || [ -L "$enabled" ]; }; then
        echo "Host nginx vhost unchanged."
        return 0
    fi

    if [ -f "$HOST_CONF_PATH" ]; then
        backup=$(mktemp)
        cp "$HOST_CONF_PATH" "$backup"
    else
        created_file=true
    fi

    # cp onto an existing file rewrites it in place, keeping the owner and
    # mode an admin gave it — it needs write access to the file, not the directory.
    cp "$new" "$HOST_CONF_PATH" || host_proxy_fail "could not write ${HOST_CONF_PATH}"
    if [ "$created_file" = true ]; then
        chmod 644 "$HOST_CONF_PATH"
    fi
    if [ -n "$enabled" ] && [ ! -L "$enabled" ]; then
        ln -s "$HOST_CONF_PATH" "$enabled" || host_proxy_fail "could not link ${enabled}"
        created_link=true
    fi

    if ! sudo -n nginx -t; then
        if [ -n "$backup" ]; then
            cp "$backup" "$HOST_CONF_PATH"
        else
            rm -f "$HOST_CONF_PATH"
        fi
        if [ "$created_link" = true ]; then
            rm -f "$enabled"
        fi
        rm -f "$backup"
        host_proxy_fail "nginx -t rejected the generated vhost — previous state restored, nginx not reloaded"
    fi
    rm -f "$backup"

    sudo -n systemctl reload nginx || host_proxy_fail "systemctl reload nginx failed"
    echo "Host nginx vhost written to ${HOST_CONF_PATH} and nginx reloaded."
}

# The vhost is owned entirely by this script, and certbot only *obtains* the
# certificate (`certonly`) — `certbot --nginx` would also edit the vhost to add
# the TLS lines, and the next run rewriting the file would drop them again.
host_proxy_configure() {
    [ "$PROXY_MODE" = host ] || return 0

    echo
    echo "===== Configuring host nginx... ====="
    echo

    # First run: certbot needs a server block answering on :80 for this domain
    # before a certificate exists, and the full vhost cannot pass `nginx -t`
    # while ssl_certificate points at a missing file. Keyed on the file's
    # content rather than its existence, since an admin may have handed it over
    # empty — and /etc/letsencrypt/live is root-only, so the certificate itself
    # cannot be looked at from here.
    if ! grep -qs 'ssl_certificate' "$HOST_CONF_PATH"; then
        rendered=$(host_proxy_render http.conf)
        host_proxy_install "$rendered"
        rm -f "$rendered"
    fi

    # Every run, because it costs nothing when there is nothing to do:
    # --keep-until-expiring makes it a local no-op while the certificate is
    # valid. The deploy hook is stored in the renewal config, so `certbot renew`
    # reloads nginx on its own later.
    sudo -n certbot certonly --nginx --non-interactive --agree-tos --keep-until-expiring \
        -m "$DOMAIN_EMAIL" --cert-name "$DOMAIN_HOST" -d "$DOMAIN_HOST" \
        --deploy-hook "systemctl reload nginx" \
        || host_proxy_fail "certbot could not obtain a certificate for ${DOMAIN_HOST} — does its DNS record point at this server?"

    rendered=$(host_proxy_render http.conf https.conf)
    host_proxy_install "$rendered"
    rm -f "$rendered"

    # The exact hop the host nginx takes. Any answer below 500 counts — the UI
    # may well sit behind authentication — while 502/504 means the container
    # behind HOST_PORT is not serving yet, which gets a few seconds' grace.
    attempt=0
    while :; do
        code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN_HOST}" "http://127.0.0.1:${HOST_PORT}/" || true)
        if [ "$code" != 000 ] && [ "$code" -lt 500 ]; then
            break
        fi
        attempt=$((attempt + 1))
        if [ "$attempt" -ge 15 ]; then
            host_proxy_fail "nothing healthy answered on 127.0.0.1:${HOST_PORT} (last status: ${code})"
        fi
        sleep 2
    done

    echo "Serving https://${DOMAIN_HOST} through the host nginx."
}
