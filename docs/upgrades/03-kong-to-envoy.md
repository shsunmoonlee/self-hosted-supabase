# Upgrades 3: Kong to Envoy

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose). **From upstream:** the [Envoy guide](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy) covers the stock compose; this page covers porting a customised Kong config.

Upstream Supabase made Envoy the default self-hosted gateway, and Coolify's template is moving the same way ([coollabsio/coolify#12004](https://github.com/coollabsio/coolify/pull/12004)). We were on Kong 2.8, which is past vendor support.

## Why the gateway goes first

Do the gateway swap before you recreate the services behind it. Kong 2.8 cached the upstream IP addresses and kept sending traffic to containers that no longer existed, with `connect() failed (113: Host is unreachable)`, until we ran `kong reload` (gotcha 11). Envoy's clusters use `STRICT_DNS` and re-resolve every 5 seconds, so later recreates behind it need no reload.

## Start from upstream's files

Take the four files from upstream `supabase/supabase`, `docker/volumes/api/envoy/` at a release tag (we used `self-hosted/v0.8.3`): `envoy.yaml`, `cds.yaml`, `lds.template.yaml`, `docker-entrypoint.sh`. Then make your deltas. Ours were:

- **Cluster names.** Point clusters at your compose service names and drop the clusters for services you removed (Storage, Functions, Studio, Logflare).
- **Routes from your old `kong.yml`.** Anything your Kong config added that no template has: for us, a few extra open auth routes and some routes we answer with a fixed 403. Port each one, then test it.
- **Studio.** Upstream routes `/` to Studio behind basic auth. If Studio is not on your public host, the catch-all can become a fixed 404. If you want Studio on its own host behind SSO, see [Vadko's Studio guide](https://gist.github.com/Vadko/bb21b01757a3ca2c82f04343babcf333).
- **Timeouts.** We kept Kong's 60-second proxy timeouts where upstream has 30 seconds. The route timeout does not cut an upgraded WebSocket.
- **Fail closed.** Our entrypoint exits if `ANON_KEY` or `SERVICE_ROLE_KEY` is empty, as defense in depth, so a missing key can never render an empty match in the RBAC rules.

`envoy/README.md` in this repo lists what we changed and where it comes from.

## Keep the container name

We kept the compose key and container name `supabase-kong` and changed only the image, entrypoint, health check, environment and bind mounts. Everything that refers to the gateway by name (the public domain variable, Traefik labels, `GOTRUE_JWT_ISSUER`, Studio's `SUPABASE_URL`, internal URLs in our apps) kept working, and a rollback is one recreate back to the Kong image with the old block and `kong.yml`.

Keep `traefik.docker.network`, `networks: [coolify]` and any autoheal labels on the block. Envoy's image has no curl, so the health check is a TCP connect to port 8000, as upstream does it.

## Validate before you swap

`envoy --mode validate` on the bootstrap alone proves little (gotcha 20). What we did:

1. Render `lds.template.yaml` with fake keys and fold clusters and listeners into one static bootstrap; validate that.
2. Run the real entrypoint in the Envoy image with the four files mounted read-only and stub upstreams under your service names, then send a test matrix: open routes, keyed routes (401 without a key), routes only the service key may use, the blocked Realtime tenant API, your own extra routes, and the catch-all. Include odd paths: double slashes, dot segments, percent-encoded letters, upper case.
3. On the clone, run the same matrix against the real services, then hold a WebSocket open for a few minutes and send broadcasts through it.

## The swap

1. Snapshot the stack directory (it holds `kong.yml`, your rollback).
2. Copy the Envoy files to `volumes/api/envoy/` on the host (mode 0644). In Coolify, edit only the gateway block, Save (do not Deploy), then press "Load from server" for each new file (gotcha 5).
3. Check that the host compose differs from your snapshot only in the gateway block.
4. Recreate that one container (`scripts/safe-recreate.sh --uuid <service-uuid> --service supabase-kong --expect-image <envoy image> --apply`).
5. Run the test matrix against the public host, sign in by hand, and test a WebSocket broadcast.

On our clone the swap took about 7 seconds of gateway errors, and the rollback to Kong about 11. On production, every check passed with no 5xx.

**Hold before the next step.** We kept 10 minutes of real traffic on Envoy before the database step, so that an Envoy problem could not be confused with a Postgres one.

## Behaviour changes your clients may notice

- Header names with underscores get a 400 (gotcha 19).
- `GET /rest/v1/` (the OpenAPI document) needs the service key.
- The Realtime tenant API (`/realtime/v1/api/tenants`) and its OpenAPI document are blocked for every caller.
- Unknown paths get Kong's 404 body if you copy it, as we did, so clients that match on it keep working.
