# 5. Trimming the stack

> **Basis.** Verified by us on 2026-10-19 on a production stack (removal of Storage, imgproxy, MinIO, Logflare, Supavisor). **From upstream:** recent releases make Analytics and Vector opt-in (see `docker/CHANGELOG.md` in [supabase/supabase](https://github.com/supabase/supabase/tree/master/docker)); the analytics replication slot issue is [supabase#43643](https://github.com/supabase/supabase/issues/43643). **Untested by us:** removing Edge Functions, Studio or the pooler from a stack that uses them.

Every service you remove is one you never have to upgrade again. We removed six from a Coolify Supabase stack: Storage, imgproxy, MinIO and its bucket-creation job, Logflare (the `analytics` service) and Supavisor. This step had no user-visible impact for us and took about 8 minutes.

Do it only with evidence that nothing uses the service ([Inventory and preflight](upgrades/01-inventory-and-preflight.md)).

## Order

1. **Snapshot** the host compose, `.env` and every bind file into a dated directory.
2. **Edit the compose, structurally, with no image changes:**
   - delete the service blocks;
   - delete every `depends_on` entry that names them (the gateway, Studio and others often depend on `analytics`);
   - delete the environment variables only they used;
   - run `docker compose config -q`.

   Make the same edit in Coolify's stored compose (`PATCH` with `instant_deploy: false`, gotcha 3), then check in the Coolify UI that the sub-resources are gone. Delete leftovers as records only, and do not deploy.
3. **`docker stop` and `docker rm` the removed containers** by their exact names.
4. **Snapshot again.** This is the base for the per-service changes that follow.

## Storage, imgproxy, MinIO

If `storage.buckets` and `storage.objects` are both empty, there is nothing to migrate. We left the `storage` schema and its roles in the database, unused, and removed `storage` from `PGRST_DB_SCHEMAS`. The gateway's `/storage/v1/` route goes away with it.

If you do use Storage, this chapter is not for you. Coolify's new template moves MinIO to RustFS; see [coollabsio/coolify#12004](https://github.com/coollabsio/coolify/pull/12004) and [Vadko's migration guide](https://gist.github.com/Vadko/57d1dbc309f5b7440036f6606027643f).

## Supavisor

Check `pg_stat_activity` for sessions from the pooler's IP addresses that are not its own internal ones. Check that no client connects to the pooler port. Our apps all connected to Postgres directly.

## Logflare (`analytics`) and Vector

Logflare is the most involved removal, because other pieces point at it:

- **Vector.** Its Logflare sinks have to go. If you keep logs, point Vector at something else first; we already had an S3-compatible bucket sink, so Vector kept only that. Upgrade `vector.yml` from upstream at the same time (gotcha 17), and check the sink against your store before choosing a Vector version (gotcha 18).
- **Studio.** The Logs pages need Logflare. Set `ENABLED_FEATURES_LOGS_ALL=false` for Studio. That was the only feature we lost.
- **The gateway.** The `/analytics/v1/` route and any `depends_on: analytics` go.
- **The `_supabase` database.** Logflare stores its data in the `_analytics` schema of the `_supabase` database, and Supavisor uses `_supavisor`. On our production stack `_analytics` made `_supabase` almost twice the size of the app database, almost all of it log tables.

While Logflare runs it also holds a logical replication slot on `_supabase`; an inactive or lagging one keeps WAL ([Disk and WAL growth](06-disk-and-wal-growth.md)). Stopping Logflare for good should leave no slot behind: check `pg_replication_slots` afterwards.

To drop the schemas:

1. Export what you want to keep, then copy it off the host. We exported every service log table and the Logflare metadata, but not the gateway access log table, because every gateway event was already in the bucket. Put a timeout on the export: if it does not finish, keep the schema and accept a larger upgrade.
2. **Unschedule any pg_cron jobs that touch it first.** We had added two retention jobs that pruned Logflare's tables; pg_cron runs in the `postgres` database, and those jobs targeted `_supabase`. Find them with `select jobid, jobname, database from cron.job where database = '_supabase'` and remove them with `cron.unschedule`.
3. In `_supabase`, as `supabase_admin`, with a lock timeout:

   ```sql
   set lock_timeout = '5s';
   drop schema _analytics cascade;
   drop schema _supavisor cascade;
   ```
4. `select pg_size_pretty(pg_database_size('_supabase'));` should now be a few MB, as ours was.

Do this before the Postgres upgrade: it makes the pg_upgrade copy smaller and faster.

## Clean up the environment

Coolify loads the whole service `.env` into every container, including variables nothing references any more. Delete stale secrets (MinIO keys, Logflare tokens, Supavisor secrets) from Coolify's environment rows once the services are gone, so they stop reaching every container.

## Verify

- An internal request through the gateway (the path your apps use), and a public one.
- No errors in Vector's log for 5 minutes.
- Any new secret is non-empty inside its container (gotcha 8).
