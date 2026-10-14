# SeaweedFS Docker Stack

A single-node [SeaweedFS](https://github.com/seaweedfs/seaweedfs) (Apache-2.0) S3 server behind nginx and
[nginx-proxy](https://github.com/ionghitun/nginx-proxy), laid out like the MinIO stack it replaces: same scripts,
same `bucket-<name>` routing, same `PROXY_MODE`. Applications move over by changing the endpoint and keys.

MinIO's community edition is archived and no longer published (images and binaries removed in 2026-09).

## Prerequisites

- Docker Engine & Docker Compose v2
- Linux or Windows WSL2
- A working nginx-proxy network (see [nginx-proxy setup](https://github.com/ionghitun/nginx-proxy)),
  or the host's own nginx (see below)

## Installation

1. **Copy and configure environment variables**
   ```bash
   cp scripts/.env.example scripts/.env
   # set DOMAIN_HOST, ADMIN_PASSWORD and the rest as needed
   ```
2. **Start the project**
   ```bash
   sh scripts/start.sh
   ```
3. **Create a bucket and its keys**
   ```bash
   sh scripts/credentials.sh
   ```
4. **Admin UI**: `https://<DOMAIN_HOST>`, login with `ADMIN_USER` / `ADMIN_PASSWORD`.

## Containers

| Container | Role |
|---|---|
| `seaweedfs` | `weed server`: master, volume server, filer and S3 gateway in one process; data in `data/seaweedfs` |
| `seaweedfs-admin` | `weed admin`: the web admin UI; its settings in `data/admin` |
| `seaweedfs-nginx` | routes `/bucket-*` to S3 and everything else to the admin UI |

Users, access keys, policies and buckets are stored by the filer inside `data/seaweedfs` — there is
no static config file. Back up the whole `data/` directory.

## Environments

`APP_ENV` in `scripts/.env` selects the compose files the scripts use:

- any value other than `production` — `docker-compose.yml` alone
- `production` — plus `docker-compose.prod.yml`, which stops publishing ports on
  the host (beyond the loopback `HOST_PORT` below) and drops `SELF_SIGNED_HOST`, so
  acme-companion's real certificate is not overwritten by a self-signed one

## Running behind the host's own nginx

By default the stack sits behind the shared nginx-proxy. On a server where nginx runs directly on
the host and owns ports 80/443, set in `scripts/.env`:

```dotenv
APP_ENV=production
PROXY_MODE=host
HOST_PORT=19100                # any free port; each stack on the host needs its own
HOST_CONF_PATH=/etc/nginx/sites-available/seaweedfs.conf
DOMAIN_HOST=...                # its DNS record must already point at this server
DOMAIN_EMAIL=...
```

`start.sh` and `build.sh` then publish `seaweedfs-nginx` on `127.0.0.1:HOST_PORT` only, write the
vhost from `scripts/nginx/host/*.conf` to `HOST_CONF_PATH`, obtain the certificate with
`certbot certonly --nginx` and reload nginx. It is the same `host-proxy.sh` as the MinIO and Mailpit
stacks — see the MinIO README for the requirements (sudo rules, handing over the vhost file).

## Available scripts

```bash
./scripts/start.sh        # Start the containers
./scripts/down.sh         # Stop the containers
./scripts/build.sh        # Update the images and recreate the containers
./scripts/restart.sh      # Restart the containers
./scripts/credentials.sh  # Create a bucket (if missing) and a user with read/write keys for it only
./scripts/policy.sh       # Allow anonymous GetObject (no listing, no writes) on a bucket
./scripts/shell.sh        # Interactive `weed shell` for everything else
```

`credentials.sh` creates **one user per application and bucket**, not a root key: a leaked key
exposes only its own bucket. Useful `weed shell` commands: `s3.user.list`, `s3.bucket.list`,
`s3.accesskey.rotate`, `s3.bucket.quota`, `s3.anonymous.list`; `help` lists them all.

## Bucket Configuration

- Buckets must follow the pattern `bucket-<name>` — nginx routes only those to S3.
- The region is not enforced: any value in `AWS_DEFAULT_REGION` works (signatures are verified
  with whatever region the client signed for).

## Laravel Integration

`credentials.sh` prints these, filled in:

```dotenv
AWS_ACCESS_KEY_ID=<generated-key-id>
AWS_SECRET_ACCESS_KEY=<generated-secret>
AWS_DEFAULT_REGION=us-east-1
AWS_BUCKET=bucket-<name>
AWS_ENDPOINT=https://<DOMAIN_HOST>
AWS_URL=https://<DOMAIN_HOST>/bucket-<name>
AWS_USE_PATH_STYLE_ENDPOINT=true
```

Presigned URLs (`Storage::temporaryUrl()`) work as with MinIO. If you're using a private DNS, your
application may need:

```yaml
extra_hosts:
  - "<DOMAIN_HOST>:host-gateway"
```

## Verified

Tested locally with SeaweedFS 4.48, through `seaweedfs-nginx`: upload, listing, presigned GET
(and a tampered signature rejected), per-bucket key isolation (`AccessDenied` on other buckets),
anonymous GET allowed while anonymous LIST/PUT are rejected, and keys, data and policies surviving
`down` + `start`.
