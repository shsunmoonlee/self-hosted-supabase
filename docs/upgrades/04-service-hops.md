# Upgrades 4: Service hops (PostgREST, Realtime, postgres-meta, Studio, Vector)

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose).

One service at a time, each with the same loop:

1. Edit the service block in the host compose and in Coolify's stored compose (gotcha 3).
2. Recreate that one container, keeping its networks (`scripts/safe-recreate.sh --uuid <service-uuid> --service <name> --expect-image <new image> --apply`).
3. Check it, then move on. Never change two service blocks between two recreates: if the second one fails you will not know which change caused it.

Pin every image by digest (`versions.md`). Pre-pull them before the window, and keep the nightly image cleanup in mind (gotcha 7).

## PostgREST v12 to v14

- Remove options that v13 dropped (`PGRST_DB_USE_LEGACY_GUCS`) and anything that only fed `app.settings.jwt_secret` if no code of yours reads it.
- Every schema in `PGRST_DB_SCHEMAS` must exist, or v13+ refuses to start. We removed `storage` along with the Storage service.
- Health check: `postgrest --ready` with `PGRST_ADMIN_SERVER_PORT=3001` **and** `PGRST_ADMIN_SERVER_HOST=localhost` (gotcha 12). Without the host, the first attempt never became healthy and rolled back.
- Check: an anonymous read of a table that anon may read returns 200.

User impact for us: a few seconds of REST errors.

## Realtime v2.34 to v2.143, in four hops

Why hops and not one jump:

- Realtime runs its schema migrations (`_realtime`) on every boot, and they only go forward (gotcha 14). If one image fails half way, you want the gap between "last known good schema" and "new schema" to be small.
- There were known bad spots in the range: a migration failure in the 2.34 line, fixed in 2.35.3 ([supabase/realtime#1351](https://github.com/supabase/realtime/issues/1351)), and a release that made `DASHBOARD_USER` mandatory and crashed migrations, fixed one patch later ([supabase/realtime#1765](https://github.com/supabase/realtime/issues/1765)).
- So we hopped through versions that upstream's own self-hosted compose had pinned at some point (its `docker/versions.md` lists them): 2.34.47 to **2.51.11**, **2.76.5**, **2.102.3**, **2.143.3**. Each one had shipped together with the rest of an upstream release.

Before the first hop:

- add `METRICS_JWT_SECRET` and `DISABLE_HEALTHCHECK_LOGGING=true`;
- give the health check `start_period: 90s`, so the container is not restarted while it migrates;
- check that the variable behind `SECRET_KEY_BASE` is at least 64 characters (gotcha 13; ours was empty);
- keep `DB_ENC_KEY`, the container name, and any `command` override you rely on (ours still worked on 2.143.3).

Each hop:

1. `pg_dump --schema=_realtime` (your rollback for this hop).
2. Change the image, recreate.
3. Check: the tenant health endpoint answers 200 inside the container; `_realtime.schema_migrations` advanced; the new replication slot is active and no old Realtime slot is left behind (we found none, since Realtime's slot is temporary; drop one if you do, because an abandoned slot holds WAL); a broadcast is delivered.

On the clone each hop took about 10 seconds of no live updates; on production the four hops took about seven minutes in all, including checks. `_realtime` migrations went from 21 to 33. A 12-minute soak through Envoy on the clone delivered every broadcast and never dropped the socket.

Rollback for a hop: stop Realtime, restore `_realtime` from the hop's dump, drop the new slots, put the previous image back.

## postgres-meta and Studio

- postgres-meta v0.100.0: set `CRYPTO_KEY` and make sure it is non-empty inside the container (gotchas 8 and 9), and `PG_META_DB_USER=postgres` as upstream does.
- Studio: the upstream image of the same period. With Logflare removed, turn the Logs pages off (`ENABLED_FEATURES_LOGS_ALL=false`).

## Vector

- Take `vector.yml` from upstream again and re-apply your changes on top. Our old copy carried a bug upstream had already fixed (gotcha 17).
- With Logflare removed, only your own sinks remain. Pick the Vector version against your sink (gotcha 18).
- After the recreate: `docker logs --since 5m <vector container> | grep -ci error` should be 0, and a fresh object should appear in your bucket.
- Press "Load from server" for `vector.yml` in Coolify (gotcha 5).
