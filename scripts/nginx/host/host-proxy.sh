# shellcheck shell=sh
# host-proxy v2 — PROXY_MODE support, shared by several repositories and kept
# byte-identical between them (srh-employee-ai, minio, seaweedfs, mailpit). Change it in
# one, copy it to the others; `diff` should stay empty. Repository-specific
# parts — vhost templates, the container name, which APP_ENV may use host —
# live with the caller, never in here.
#
# Decides who sits in front of the stack's nginx container:
#
#   nginx-proxy (default) — the shared nginx-proxy container, routing by
#                           VIRTUAL_HOST over the nginx-proxy network.
#   host                  — the server's own nginx. The container is published
#                           on 127.0.0.1:HOST_PORT (the caller's prod overlay),
#                           and host_proxy_configure writes the vhost at
#                           HOST_CONF_PATH and obtains the certificate with certbot.
#
# A library: sourcing it only defines functions. POSIX sh, so it runs under the
# services' /bin/sh scripts and under srh's `bash -euo pipefail` alike — which is
# also why every variable it sets is prefixed: there is no `local`.
#
# The caller, from the directory holding .env:
#
#   HOST_PROXY_DIR=nginx/host          # this directory; templates are read from it
#   HOST_PROXY_CONTAINER=minio-nginx   # the container published on HOST_PORT
#   . "$HOST_PROXY_DIR/host-proxy.sh"
#   host_proxy_load                    # reads .env, validates PROXY_MODE
#   [ "$PROXY_MODE" = host ] && ...    # its own APP_ENV rule, if any
#   host_proxy_check                   # before any container is started
#   ...                                # bring the stack up
#   host_proxy_configure               # after it is up
#
# Templates in HOST_PROXY_DIR: http.conf (port 80 only, used alone until a
# certificate exists) and https.conf, with {{SERVER_NAMES}}, {{DOMAIN_HOST}}
# and {{HOST_PORT}} replaced.

host_proxy_fail() {
    echo >&2
    echo "===== ERROR: $1 =====" >&2
    echo >&2
    exit 1
}

# A value from .env, unquoted; empty when the key is absent or empty. The last
# occurrence wins, as it does for Compose. Never fails, so it is safe under set -e.
host_proxy_env() {
    sed -n "s/^$1=//p" .env | tail -n 1 | tr -d '\r' | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

host_proxy_load() {
    [ -n "${HOST_PROXY_DIR:-}" ] || host_proxy_fail "HOST_PROXY_DIR is not set — the caller sets it before sourcing host-proxy.sh"
    [ -n "${HOST_PROXY_CONTAINER:-}" ] || host_proxy_fail "HOST_PROXY_CONTAINER is not set — the caller sets it before host_proxy_load"

    PROXY_MODE=$(host_proxy_env PROXY_MODE)
    PROXY_MODE=${PROXY_MODE:-nginx-proxy}
    HOST_PORT=$(host_proxy_env HOST_PORT)
    HOST_CONF_PATH=$(host_proxy_env HOST_CONF_PATH)
    HOST_WWW=$(host_proxy_env HOST_WWW)
    HOST_WWW=${HOST_WWW:-false}
    DOMAIN_HOST=$(host_proxy_env DOMAIN_HOST)
    DOMAIN_EMAIL=$(host_proxy_env DOMAIN_EMAIL)

    case "$PROXY_MODE" in
        nginx-proxy | host) ;;
        *) host_proxy_fail "unknown PROXY_MODE '${PROXY_MODE}' — use 'nginx-proxy' (default) or 'host'" ;;
    esac
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
        */) hp_path_ok=false ;;
        /*) hp_path_ok=true ;;
        *) hp_path_ok=false ;;
    esac
    if [ "$hp_path_ok" = false ] || [ -d "$HOST_CONF_PATH" ]; then
        host_proxy_fail "PROXY_MODE=host needs HOST_CONF_PATH in .env, the absolute path of the vhost *file* (e.g. /etc/nginx/sites-available/${DOMAIN_HOST:-example}.conf), got '${HOST_CONF_PATH}'"
    fi
    case "$HOST_WWW" in
        true | false) ;;
        *) host_proxy_fail "HOST_WWW must be 'true' or 'false' (got '${HOST_WWW}')" ;;
    esac
    if [ -z "$DOMAIN_HOST" ] || [ -z "$DOMAIN_EMAIL" ]; then
        host_proxy_fail "PROXY_MODE=host needs DOMAIN_HOST and DOMAIN_EMAIL in .env — certbot uses both"
    fi

    for hp_tool in ss curl; do
        command -v "$hp_tool" > /dev/null || host_proxy_fail "PROXY_MODE=host needs '${hp_tool}' on the host"
    done

    # Held already is fine only when this stack's container is the holder —
    # every run after the first finds it there.
    if [ -n "$(ss -Htln "sport = :${HOST_PORT}")" ] \
        && ! docker port "$HOST_PROXY_CONTAINER" 80 2> /dev/null | grep -q ":${HOST_PORT}\$"; then
        host_proxy_fail "HOST_PORT ${HOST_PORT} is already in use by another process — pick a free one"
    fi

    # Root is needed only for these three, and asked for only for these: the
    # vhost itself is written as this user (see host_proxy_writable).
    # `sudo -l <cmd>` asks the policy without running anything, so a missing
    # rule fails here rather than after the containers were started. Checked
    # with the exact arguments used below, since a rule may pin them.
    hp_missing=''
    for hp_cmd in 'nginx -t' 'systemctl reload nginx' 'certbot'; do
        # shellcheck disable=SC2086 # word splitting into command + arguments is the point
        if ! sudo -n -l $hp_cmd > /dev/null 2>&1; then
            hp_missing="${hp_missing}${hp_missing:+, }${hp_cmd}"
        fi
    done
    if [ -n "$hp_missing" ]; then
        {
            echo
            echo "===== ERROR: PROXY_MODE=host runs these as root through passwordless sudo, and $(whoami) may not: ${hp_missing} ====="
            echo
            echo "Add to /etc/sudoers.d/host-proxy (check each path with \`command -v\` — certbot is /snap/bin/certbot when installed as a snap):"
            echo
            echo "    $(whoami) ALL=(root) NOPASSWD: /usr/sbin/nginx -t, /usr/bin/systemctl reload nginx, /usr/bin/certbot"
            echo
        } >&2
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
    hp_enabled=$(host_proxy_enabled_path)
    hp_file_ok=true
    hp_link_ok=true

    if [ -e "$HOST_CONF_PATH" ]; then
        [ -w "$HOST_CONF_PATH" ] || hp_file_ok=false
    else
        hp_dir=$(dirname "$HOST_CONF_PATH")
        { [ -d "$hp_dir" ] && [ -w "$hp_dir" ]; } || hp_file_ok=false
    fi
    if [ -n "$hp_enabled" ] && [ ! -L "$hp_enabled" ]; then
        hp_dir=$(dirname "$hp_enabled")
        { [ -d "$hp_dir" ] && [ -w "$hp_dir" ]; } || hp_link_ok=false
    fi

    if [ "$hp_file_ok" = false ] || [ "$hp_link_ok" = false ]; then
        {
            echo
            echo "===== ERROR: PROXY_MODE=host writes the vhost as $(whoami), without sudo, and needs a hand from an admin once ====="
            echo
            echo "Ask them to run (an empty file is valid nginx config, so it is safe before the first run):"
            echo
            # Only for a file that cannot be written: run against an existing
            # vhost, /dev/null would empty it.
            if [ "$hp_file_ok" = false ]; then
                echo "    sudo install -m 644 -o $(whoami) /dev/null ${HOST_CONF_PATH}"
            fi
            if [ "$hp_link_ok" = false ]; then
                echo "    sudo ln -s ${HOST_CONF_PATH} ${hp_enabled}"
            fi
            echo
        } >&2
        exit 1
    fi
}

# Renders the given templates from HOST_PROXY_DIR into one file and prints its path.
host_proxy_render() {
    hp_names=$DOMAIN_HOST
    if [ "$HOST_WWW" = true ]; then
        hp_names="$DOMAIN_HOST www.$DOMAIN_HOST"
    fi
    hp_out=$(mktemp)
    for hp_tpl in "$@"; do
        sed -e "s|{{SERVER_NAMES}}|${hp_names}|g" \
            -e "s|{{DOMAIN_HOST}}|${DOMAIN_HOST}|g" \
            -e "s|{{HOST_PORT}}|${HOST_PORT}|g" \
            "${HOST_PROXY_DIR}/${hp_tpl}" >> "$hp_out"
    done
    echo "$hp_out"
}

# Puts a rendered vhost at HOST_CONF_PATH and reloads nginx — or, when
# `nginx -t` rejects it, puts back what was there and aborts, so a bad template
# never takes down the other sites served by the same nginx.
host_proxy_install() {
    hp_new=$1
    hp_backup=''
    hp_created_file=false
    hp_created_link=false
    hp_enabled=$(host_proxy_enabled_path)

    if [ -f "$HOST_CONF_PATH" ] && cmp -s "$hp_new" "$HOST_CONF_PATH" && { [ -z "$hp_enabled" ] || [ -L "$hp_enabled" ]; }; then
        echo "Host nginx vhost unchanged."
        return 0
    fi

    if [ -f "$HOST_CONF_PATH" ]; then
        hp_backup=$(mktemp)
        cp "$HOST_CONF_PATH" "$hp_backup"
    else
        hp_created_file=true
    fi

    # cp onto an existing file rewrites it in place, keeping the owner and
    # mode an admin gave it — it needs write access to the file, not the directory.
    cp "$hp_new" "$HOST_CONF_PATH" || host_proxy_fail "could not write ${HOST_CONF_PATH}"
    if [ "$hp_created_file" = true ]; then
        chmod 644 "$HOST_CONF_PATH"
    fi
    if [ -n "$hp_enabled" ] && [ ! -L "$hp_enabled" ]; then
        ln -s "$HOST_CONF_PATH" "$hp_enabled" || host_proxy_fail "could not link ${hp_enabled}"
        hp_created_link=true
    fi

    if ! sudo -n nginx -t; then
        if [ -n "$hp_backup" ]; then
            cp "$hp_backup" "$HOST_CONF_PATH"
        else
            rm -f "$HOST_CONF_PATH"
        fi
        if [ "$hp_created_link" = true ]; then
            rm -f "$hp_enabled"
        fi
        rm -f "$hp_backup"
        host_proxy_fail "nginx -t rejected the generated vhost — previous state restored, nginx not reloaded"
    fi
    rm -f "$hp_backup"

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
        hp_rendered=$(host_proxy_render http.conf)
        host_proxy_install "$hp_rendered"
        rm -f "$hp_rendered"
    fi

    # Every run, because it costs nothing when there is nothing to do:
    # --keep-until-expiring makes it a local no-op while the certificate is
    # valid, and a changed domain list (HOST_WWW toggled) is reissued under the
    # same --cert-name, so the path in the template stays right. The deploy
    # hook is stored in the renewal config, so `certbot renew` reloads nginx on
    # its own later.
    hp_www_domain=''
    if [ "$HOST_WWW" = true ]; then
        hp_www_domain="www.${DOMAIN_HOST}"
    fi
    # shellcheck disable=SC2086 # unquoted on purpose: an empty www part must vanish
    sudo -n certbot certonly --nginx --non-interactive --agree-tos --keep-until-expiring \
        -m "$DOMAIN_EMAIL" --cert-name "$DOMAIN_HOST" -d "$DOMAIN_HOST" ${hp_www_domain:+-d $hp_www_domain} \
        --deploy-hook "systemctl reload nginx" \
        || host_proxy_fail "certbot could not obtain a certificate for ${DOMAIN_HOST} — does its DNS record point at this server?"

    hp_rendered=$(host_proxy_render http.conf https.conf)
    host_proxy_install "$hp_rendered"
    rm -f "$hp_rendered"

    # The exact hop the host nginx takes. Any answer below 500 counts — the UI
    # may well sit behind authentication — while 502/504 means the container
    # behind HOST_PORT is not serving yet, which gets a few seconds' grace.
    hp_attempt=0
    while :; do
        hp_code=$(curl -s -o /dev/null -w '%{http_code}' -H "Host: ${DOMAIN_HOST}" "http://127.0.0.1:${HOST_PORT}/" || true)
        if [ "$hp_code" != 000 ] && [ "$hp_code" -lt 500 ]; then
            break
        fi
        hp_attempt=$((hp_attempt + 1))
        if [ "$hp_attempt" -ge 15 ]; then
            host_proxy_fail "nothing healthy answered on 127.0.0.1:${HOST_PORT} (last status: ${hp_code})"
        fi
        sleep 2
    done

    echo "Serving https://${DOMAIN_HOST} through the host nginx."
}
