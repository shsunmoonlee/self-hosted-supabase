# Changelog

One entry per upgrade window. Newest first. Each entry: what changed, what it took, what broke, and links to the gotchas and version rows it added.

## 2026-10-24: a stored-versus-host comparison

A full read-only comparison of Coolify's stored compose, the host file and the running containers. Every literal in the host file was present in its container, images and networks included; the trap was in what the literals did not do. New gotcha 39: a literal in a service's `environment:` block does not feed `${VAR}` interpolation, so for interpolated values the stack `.env`, rendered from Coolify's environment rows, decides, and gotcha 2 now points to it. We nearly turned on phone signup with auto-confirm by "fixing" the rows to match the host file.

## 2026-10-23: second clone rehearsal (config change and a restart)

[Rehearse on a clone](docs/upgrades/02-rehearse-on-a-clone.md) gained a section on rehearsing a smaller planned change that touches the live database (replication role, `pg_hba`, `conf.d`, one restart under light load): how we built the clone this time, what we ran, what it found, and the measured outage (database about 6 s, PostgREST about 8 s, Realtime about 20 s). Six new gotchas, 33 to 38: the map-form `SERVICE_URL_*` variable that gives a clone a domain, a clone sharing the `supabase-db` alias on Coolify's network, the `conf.d` symlink on a fresh config volume, and Realtime's recovery after a restart (all from the clone); a lock test that must check why a write failed (from our backup tooling's own tests); and probe timestamps and permissions. Gotcha 2 now says what a stale stored compose does after a major upgrade, and gotcha 28 why the first clone had no cron jobs.

## 2026-10-21: Studio chapter

New chapter [Studio: private by default](docs/09-studio-private-by-default.md): why Studio must stay off the internet, what the stock `DASHBOARD_USERNAME` / `DASHBOARD_PASSWORD` basic auth covers on Kong and Envoy, three patterns (no public route plus a tunnel, a reverse-proxy allowlist, SSO forward-auth) with Caddy and Traefik snippets, Coolify notes, and a from-outside verify checklist. Snippets are from upstream docs and the linked references, untested by us. README contents and FAQ updated.

## 2026-10-20: handbook structure

The notes from the 2026-10-19 window became a general handbook: production checklist and hardening, backups and restore, point-in-time recovery (design), upgrades (the window's runbook now lives under `docs/upgrades/`), trimming, disk and WAL growth, monitoring, Coolify, FAQ and a condensed case study. New read-only script: `scripts/hardening-check.sql`. Gotcha numbers are unchanged.

## 2026-10-19: sync to upstream, Postgres 15 to 17

Stack: self-hosted Supabase as a Coolify 4.4.6 service, on one amd64 host. Rehearsed the same morning on a clone with production data, then run on production in one sitting.

**Removed:** Storage, imgproxy, MinIO and its bucket-creation job (Storage held no objects), Logflare and Supavisor (no clients). Logflare's `_analytics` and Supavisor's `_supavisor` schemas dropped after an export; the Logflare retention cron jobs unscheduled first.

**Changed:**
- Gateway: Kong 2.8.1 to Envoy v1.39.1, same container name.
- PostgREST v12.2.12 to v14.18.
- Realtime v2.34.47 to v2.143.3 in four hops (2.51.11, 2.76.5, 2.102.3, 2.143.3).
- postgres-meta v0.89.3 to v0.100.0; Studio to 2026.10.12; Vector 0.28.1 to 0.45.0 with an S3-compatible sink only.
- Postgres 15.14.1.163 to 17.6.1.163 with pg_upgrade in copy mode; `pgjwt` and `wrappers` dropped.

**User impact:** none for the removals; seconds of REST errors for PostgREST; about 10 seconds without live updates per Realtime hop; a few seconds for the gateway swap; about two minutes of database downtime behind a maintenance page. The one job in flight resumed by itself after the workers came back.

**What broke or nearly did** (details in `docs/gotchas.md`):
- PostgREST's first recreate rolled back: `PGRST_ADMIN_SERVER_HOST=localhost` was missing (gotcha 12).
- Kong kept routing to old container IPs after recreates until `kong reload` (gotcha 11).
- Realtime's `SECRET_KEY_BASE` had been empty since the stack was created (gotcha 13).
- On the clone: pg_upgrade failed on event-trigger ownership (gotcha 21), and our recreate tool's rollback left `kong.yml` unreadable (gotcha 30). Both fixed before production.
- After the window: a Vector transform error on Postgres lines without a severity tag, fixed by taking upstream's `vector.yml` fix (gotcha 17).

**Follow-ups (open when this entry was written):** move point-in-time recovery to the new major (gotcha 32); remove the rollback volume and saved images after 14 days.
