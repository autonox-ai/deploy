# Metabase via Docker Compose

Optional self-hosted Metabase deployment for AutoNox. Use only when the
customer does not already have a BI platform such as BusinessObjects or
Power BI.

## Scope

This document covers running the Metabase container and the Traefik proxy that
terminates TLS in front of it. The Metabase application database is provisioned
separately via [`../bootstrap/setup.sql.tmpl`](../bootstrap/setup.sql.tmpl).

This is **not** the AutoNox PostgreSQL bootstrap — see
[`../../postgres/README.md`](../../postgres/README.md) for that.

## What you get

- Metabase behind a Traefik reverse proxy, **HTTPS only**
- published ports: `443` (Metabase) and `80` (redirects to `443`)
- a self-signed certificate issued automatically on first start, replaceable
  with the customer's own — see [TLS](#tls)
- containers: `nox-traefik`, `nox-metabase` (and `nox-metabase-certs`, which
  runs once per `up` and exits)
- shared network: `autonox-local`
- PostgreSQL-backed Metabase metadata store (provisioned via `../bootstrap/`)

Metabase's own port `3000` is published on `127.0.0.1` only. It is there for
host-side tooling — the Terraform in [`../tf/`](../tf/), `curl`, the
[`../tf-runner/`](../tf-runner/) image with `--network=host` — which then does
not have to trust the certificate. Nothing outside the host can reach it.

## Run Metabase

Run every command below from the **repository root**. Nothing in this guide
writes into the repository — see step 2.

### Step 1: provision the Metabase application database

Metabase needs its own database and role, separate from the AutoNox schemas.

```bash
export METABASE_DB=metabase
export METABASE_USER=metabase_user
export METABASE_PASSWORD='<metabase-password>'
```

These values must match the Metabase environment file written in step 2:

- `METABASE_DB` → `MB_DB_DBNAME`
- `METABASE_USER` → `MB_DB_USER`
- `METABASE_PASSWORD` → `MB_DB_PASS`

Bundled PostgreSQL example:

```bash
envsubst < metabase/bootstrap/setup.sql.tmpl | docker exec -i nox-pg18 psql -U postgres -d postgres
```

Customer-managed PostgreSQL example:

```bash
envsubst < metabase/bootstrap/setup.sql.tmpl | psql "$PG_ADMIN_URL" -d postgres
```

This creates:

- role `metabase_user`
- database `metabase` owned by `metabase_user`
- `CREATE` access on schema `public`

### Step 2: configure the Metabase environment

Configuration lives **outside this repository**, in a directory you own, so
that upgrading AutoNox is "replace the repo, keep your config". This guide
calls that directory `$AUTONOX_HOME` and defaults it to `/etc/autonox` — the
same directory [`../../postgres/compose/README.md`](../../postgres/compose/README.md)
and the workloads use.

```bash
export AUTONOX_HOME="${AUTONOX_HOME:-/etc/autonox}"
mkdir -p "$AUTONOX_HOME"
cp metabase/compose/metabase.env.example "$AUTONOX_HOME/metabase.env"
chmod 600 "$AUTONOX_HOME/metabase.env"
```

Keep these values in `$AUTONOX_HOME/metabase.env` aligned with the database and
role created in step 1:

```bash
MB_DB_DBNAME=metabase
MB_DB_USER=metabase_user
MB_DB_PASS=<metabase-password>
```

**Required:** `MB_DB_PASS` ships empty on purpose — no baked-in secrets — and
`docker compose up` refuses to start until it's set.

Recommended defaults when using the bundled PostgreSQL container:

- `MB_DB_HOST=postgres`
- `MB_DB_PORT=5432`

If the customer uses a managed PostgreSQL service instead, set `MB_DB_HOST`,
`MB_DB_PORT`, `MB_DB_DBNAME`, `MB_DB_USER`, and `MB_DB_PASS` accordingly.

This is better than using `host.docker.internal` on Linux because Metabase can
connect directly over the shared container network.

Update `METABASE_IMAGE` and `TRAEFIK_IMAGE` to the exact approved image tags for
the customer environment if needed.

Set `METABASE_HOSTNAME` to the name users will actually type in the browser (an
IP address is fine). It is what the generated certificate is issued for, and
what Metabase puts in the links it emails. Everything else under
"TLS / proxy" in the example file has a working default.

If something on the host already owns port 80 or 443, set `METABASE_HTTP_PORT`
/ `METABASE_HTTPS_PORT` — and then also set `METABASE_HTTPS_REDIRECT_TO` and
`MB_SITE_URL`, which cannot be derived from them (both are commented examples
in the env file).

Never edit files inside this repository. `git status --porcelain` (or a
checksum of the tree) should stay empty after every step in this guide.

### Step 3: start Metabase

```bash
docker compose -f metabase/compose/compose.yaml \
  --env-file "$AUTONOX_HOME/metabase.env" up -d
```

Nothing else is needed to get HTTPS: on this first run the `nox-metabase-certs`
job finds the certificate directory (`$AUTONOX_HOME/certs`) empty and issues a
self-signed certificate into it, then Traefik starts and serves it. To use the
customer's certificate instead, put it there **before** this command — see
[TLS](#tls).

To drop the flags from every later command, export the path once — Compose
reads it automatically (requires Compose v2.24+):

```bash
export COMPOSE_FILE="$PWD/metabase/compose/compose.yaml"
export COMPOSE_ENV_FILES="$AUTONOX_HOME/metabase.env"
docker compose up -d
```

The rest of this guide assumes those two exports are set; without them, add
`-f` and `--env-file` to each `docker compose` invocation. If PostgreSQL was
started the same way, its exports name a different spec and env file — set
these in a separate shell, or keep passing the flags explicitly.

If the host still uses the legacy Compose v1 binary, replace `docker compose`
with `docker-compose`.

This Compose file expects the `autonox-local` network to already exist. If
PostgreSQL was started from
[`../../postgres/compose/compose.yaml`](../../postgres/compose/compose.yaml),
that network is already created.

If PostgreSQL is customer-managed and that network does not exist yet, either:

- create it once with `docker network create autonox-local`
- or set `METABASE_DOCKER_NETWORK` in `$AUTONOX_HOME/metabase.env` to an
  existing network name

### Step 4: verify

```bash
docker compose ps
docker logs nox-metabase-certs   # which certificate is being served
docker logs nox-traefik
docker logs nox-metabase
```

Check the whole path — TLS termination, proxy, and Metabase — in one request.
`--cacert` validates against the certificate being served, so this fails if
Traefik is serving something other than the file in `METABASE_TLS_DIR`:

```bash
curl --cacert "$AUTONOX_HOME/certs/tls.crt" https://localhost/api/health
# {"status":"ok"}
```

Then open `https://<METABASE_HOSTNAME>/` and create the admin account. With the
default self-signed certificate the browser warns that the issuer is unknown —
expected, and the reason for [TLS](#tls) below. `http://` is not served: it
answers with a 301 to `https://`.

### Step 5 (optional): apply Terraform configuration

After Metabase is reachable, configure data sources, cards, and dashboards
declaratively from [`../tf/`](../tf/). See [`../tf/README.md`](../tf/README.md).
Point `metabase_host` at `http://localhost:3000` — the loopback publish exists
so Terraform never has to deal with the certificate.

## TLS

TLS is always on. There is no plaintext mode and no overlay to enable: Traefik
terminates HTTPS on `:443`, `:80` only redirects to it, and Metabase itself is
reachable from the outside through nothing else.

Both certificate modes use the same two files in `$AUTONOX_HOME/certs`,
outside this repository (set `METABASE_TLS_DIR` to put them somewhere else):

| File | What it is |
|---|---|
| `tls.crt` | full chain — leaf first, then intermediates |
| `tls.key` | private key, `chmod 600` |

### Default: self-signed, zero work

If those files are missing on `up`, `nox-metabase-certs` issues a self-signed
pair for `METABASE_HOSTNAME` (plus `localhost` and `127.0.0.1`, valid 825 days)
and Traefik serves it. Connections are encrypted, but browsers show an
"unknown issuer" warning until someone trusts the certificate — so this is the
right default for getting started and for internal test hosts, not the end
state for production.

Add more names with `METABASE_TLS_SANS` when the host answers to several
(`METABASE_TLS_SANS=DNS:bi.corp.example,IP:10.0.0.7`).

To silence the warning without a customer CA, distribute `tls.crt` and have it
trusted on the machines that use Metabase — on Linux, copy it to
`/usr/local/share/ca-certificates/autonox-metabase.crt` and run
`update-ca-certificates`.

### Production: the customer's own certificate

Ask the customer's PKI team for a server certificate for `METABASE_HOSTNAME`,
issued by the CA their fleet already trusts. Then:

```bash
# leaf first, then every intermediate the CA issued — a leaf-only file
# validates in a browser that cached the intermediate and fails everywhere else
cat bi.example.crt intermediate.crt > "$AUTONOX_HOME/certs/tls.crt"
cp bi.example.key "$AUTONOX_HOME/certs/tls.key"
chmod 600 "$AUTONOX_HOME/certs/tls.key"

docker compose restart traefik
```

Nothing switches modes: `nox-metabase-certs` recognises the pair as
customer-supplied (it fingerprints what it generates, and this is not it) and
from then on never touches it — not to renew, not to replace. `docker logs
nox-metabase-certs` says which of the two it decided on.

This needs no public DNS, no reachable `:443` from the internet, and no ACME
account. An internal-only hostname and a private CA are exactly the expected
case.

### Renewing

Replacing the files is not enough on its own. Traefik's file provider watches
the `traefik/dynamic` directory, **not** the certificates it points at, so a
running Traefik keeps serving the old certificate until it is restarted:

```bash
docker compose restart traefik
```

Self-signed certificates are handled for you: any `up` (or
`docker compose up -d --force-recreate metabase-certs`) reissues one that is
within 30 days of expiry. Customer certificates are the customer's renewal
process; put the new pair in place and restart Traefik.

To go back to a self-signed certificate, delete `tls.crt`, `tls.key`, and
`.self-signed` from the directory and run `up` again.

### Rootless engines (Podman, or Docker as a non-root user)

Two things a rootless engine does differently, both of which show up as a
failure to start:

- **The certificate directory has to be somewhere the engine's user can
  create.** It defaults to `$AUTONOX_HOME/certs`, so this is already handled
  when `AUTONOX_HOME` points inside that user's home (e.g.
  `/home/nox/.autonox`). If neither `AUTONOX_HOME` nor `METABASE_TLS_DIR`
  reaches Compose, the fallback is `/etc/autonox/certs` and you get
  `making volume mountpoint … permission denied`. `AUTONOX_HOME` is read from
  the shell running `docker compose` **or** from `metabase.env` — set it in the
  env file if the command runs somewhere that does not export it (`sudo`,
  systemd, cron).

- **Ports below 1024 are not bindable.** Publishing `:80`/`:443` fails with
  `cannot expose privileged port`. Either publish high ports:

  ```bash
  METABASE_HTTP_PORT=8080
  METABASE_HTTPS_PORT=8443
  METABASE_HTTPS_REDIRECT_TO=:8443
  MB_SITE_URL=https://bi.customer.example:8443
  ```

  or let the host allow them for everyone —
  `sysctl -w net.ipv4.ip_unprivileged_port_start=80`, persisted in
  `/etc/sysctl.d/`, which needs root once and a customer sign-off.

On SELinux hosts, a bind mount the container cannot read shows up as a
permission error on `/certs` even when the path and ownership look right. Fix
it by relabelling the directory once —
`chcon -Rt container_file_t "$AUTONOX_HOME/certs"`.

### What is not covered

Proxy → Metabase and Metabase → PostgreSQL stay plaintext on the
`autonox-local` container network, which is the right default while neither
publishes a reachable port. If the customer requires in-cluster encryption
too, that is a separate change (Metabase's `MB_DB_*` SSL settings for the
database leg).

## Stop or remove

These also interpolate the spec, so they need the same env file (or the
`COMPOSE_FILE` / `COMPOSE_ENV_FILES` exports from step 3):

```bash
docker compose down
```

That does not remove `$AUTONOX_HOME/metabase.env` or the certificates in
`METABASE_TLS_DIR` — your configuration survives teardown and repo upgrades
alike, and the next `up` serves the same certificate. Metabase itself is
stateless here; its metadata lives in the PostgreSQL database from step 1.

## Notes

- Metabase is optional and should not be treated as part of the AutoNox core
  bootstrap.
- Keep Metabase metadata in its own database instead of reusing the `autonox`
  database.
