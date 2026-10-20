# 7. Monitoring and health checks

> **Basis.** Verified by us on a production stack (2026-08 to 2026-10): the health endpoints below are the ones our compose, our Envoy config and our external probes use. **From upstream:** the [supabase-observability](https://github.com/supabase-community/supabase-observability) project (logs, metrics, traces) and the overview's note that advanced metrics are not provided self-hosted. We have not run that project.

## Per-service health checks

| Service | Inside the stack | Through the gateway | Notes |
|---|---|---|---|
| Postgres (`supabase-db`) | `pg_isready -U postgres -h localhost` | n/a | |
| GoTrue (`supabase-auth`) | `GET /health` on port 9999 | `GET /auth/v1/health` with the anon key | |
| PostgREST (`supabase-rest`) | `postgrest --ready` (needs `PGRST_ADMIN_SERVER_PORT` and `PGRST_ADMIN_SERVER_HOST=localhost`) | an anon read of a table anon may read: `GET /rest/v1/<table>?select=id&limit=1` | Under Envoy the OpenAPI root `/rest/v1/` is 403 for anon, so do not probe it |
| Realtime (`realtime-dev`) | `GET /api/tenants/<tenant>/health`; `GET /` returns 200 only with a valid `SECRET_KEY_BASE` | a WebSocket handshake to `/realtime/v1/websocket` with the anon key (expect 101) | The tenant API is 403 through Envoy by design |
| postgres-meta | `GET /health` on port 8080 | `/pg/` needs the service key; do not probe it publicly | |
| Gateway (Envoy) | TCP connect to 8000 (the image has no curl) | any keyed route above | Envoy also health-checks its clusters: auth `/health`, rest `/`, realtime `/`, meta `/health` |
| Vector | no errors in `docker logs --since 5m` | n/a | |

## Probe the path your app uses

Two different paths reach your stack:

- **Public:** client, reverse proxy, gateway.
- **Internal:** your own backend to the gateway (or to Postgres) over a private Docker network.

On our stack the internal path broke more than once (a host-side container recreate dropped the shared Docker network, [gotcha 1](gotchas.md)) while every public check stayed green, because public traffic never used that network. So we run both:

1. **An external uptime check** on a public health URL, every minute, that pages after two consecutive failures.
2. **An app health route** that calls the gateway the way your backend does (same base URL, same network) and reports `auth`, `rest` and a signed-in user's token read separately. Probe it from outside every few minutes.

Design rules that cut false pages for us:
- **Re-check before paging.** A single slow answer is asked again a few seconds later; only the second answer counts.
- **Separate "down" from "degraded".** Realtime down on its own is logged and attached to the next page, not a page by itself, if your product can live without live updates for a while.
- **Fail fast on "no path".** DNS or connect errors on the internal path mean the network is gone: page at once, without a re-check.
- **Mute paging for a maintenance window,** and put the unmute in the runbook's last step.

## What to alert on

| Signal | Threshold we use or suggest |
|---|---|
| Public health URL | 2 consecutive failures, 1 minute apart |
| Internal path (`auth`, `rest`) | any no-path error at once; other failures after one re-check |
| Disk on the Docker filesystem | 80 and 90 percent |
| Replication slots | any inactive slot; headroom under half of `max_slot_wal_keep_size` ([Disk and WAL](06-disk-and-wal-growth.md)) |
| Containers | restart count rising, or `unhealthy` for more than a few minutes |
| Connections | close to `max_connections`; upstream has a report of `supabase_admin` alone using many ([supabase#33099](https://github.com/supabase/supabase/issues/33099)) |
| Backups | the newest backup older than its schedule, or smaller than half the previous one |
| PITR, if you run it | see [PITR, what to alert on](03-point-in-time-recovery.md#what-to-alert-on) |

## Logs without Logflare

If you remove Logflare ([Trimming](05-trimming-the-stack.md)), Vector can still collect container logs and ship them to an S3-compatible bucket with a lifecycle rule. We keep a year of gateway logs that way and query the archive with DuckDB when we need it. Three things to know:

- Diff your `vector.yml` against upstream's when you upgrade; our old copy had a remap bug upstream had fixed ([gotcha 17](gotchas.md)).
- Check the S3 sink against your store before bumping Vector ([gotcha 18](gotchas.md)).
- Make the sink drop the newest events with a bounded retry when the bucket is unreachable, so a storage outage never back-pressures the log pipeline.
