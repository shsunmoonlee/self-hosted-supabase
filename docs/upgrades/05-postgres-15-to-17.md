# Upgrades 5: Postgres 15 to 17 with pg_upgrade

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose). The script also has a local end-to-end test suite (not published). **From upstream:** the [Postgres 17 guide](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) covers the stock compose; use it if your stack is stock.

`scripts/pg17-upgrade.sh` upgrades the Supabase db container of a Coolify service from `supabase/postgres:15.14.1.163` to `supabase/postgres:17.6.1.163`, in place, on Coolify's named volumes `<service-uuid>_supabase-db-data` and `<service-uuid>_supabase-db-config`. It is derived from upstream's `docker/utils/upgrade-pg17.sh` (supabase/supabase, tag `self-hosted/v0.8.3`) and the `initiate.sh` / `complete.sh` scripts in supabase/postgres. [Vadko's gist](https://gist.github.com/Vadko/57d1dbc309f5b7440036f6606027643f) takes a closer path: it runs upstream's `initiate.sh` itself. Read both and pick one.

## How it works

- **Binaries.** The `.163` images are Alpine with a nix-built Postgres, so upstream's `initiate.sh` cannot run in them as is. The script builds the nix closure of the 17 image's Postgres, minus what the 15 image already has, and extracts it into a 15 container. That gives a native 17 binary directory and avoids the C library mismatch question.
- **Copy mode.** `pg_upgrade --copy`, never `--link` or `--clone`. The 15 data stays untouched, and after the swap it is kept in a side volume `<service-uuid>_supabase-db-data-pg15` for rollback.
- **Every database that allows connections**, including `_supabase` (gotcha 24).
- **Extensions.** Aborts on extensions that have no 17 package. Drops `pgjwt` and `wrappers` only if unused (no CASCADE). Drops `pg_graphql`, `pg_stat_monitor`, `pg_backtrace` and `pgaudit` before pg_upgrade and recreates them after, recording versions and schemas. Runs `ALTER EXTENSION ... UPDATE` for every extension afterwards and logs each result.
- **Event triggers.** Grants `postgres` SUPERUSER for the run (as `initiate.sh` does), restores the recorded value after, and fails if `postgres` is left a superuser (gotcha 21).
- **pg_cron.** Records the active jobs, disables them for the run, and re-enables exactly those at the end, so no job fires in a helper container.
- **Replication slots.** Records and drops logical slots (gotcha 23).
- **Collation.** Compares recorded and actual collation versions. On a mismatch it reindexes before refreshing, or with `ANALYZE=defer` writes the reindex down as a required post-window step (gotcha 26).
- **Helpers have no network.** Every helper container runs with `--network none`, and `pg_net` sends nothing while the helper is up.
- **The password** is read from the db container's environment or the service `.env` and passed to containers by name (`-e PGPASSWORD`), never as a value on a command line, and never printed.

## Modes

```bash
export UUID=<service-uuid> WORK_DIR=/root/pg17-upgrade-<service-uuid>

bash pg17-upgrade.sh prepare     # service RUNNING. All gates; exit 1 = no-go
bash pg17-upgrade.sh upgrade     # every container of the stack STOPPED
bash pg17-upgrade.sh finish      # re-run the PG17 post-steps after a failure past the swap
bash pg17-upgrade.sh rollback    # back to 15; after a finished upgrade it also needs --discard-pg17-writes
```

Use the same `WORK_DIR` for every mode: its records (dropped extensions, cron ids, slots, `rolsuper`) drive the recreate, the re-enable and the rollback. It also holds a copy of the `pgsodium` root key: keep it 0600 and delete it with the side volume.

`prepare` runs with the service up and changes nothing in the database: it pulls both images, downloads the upstream helper scripts (so `upgrade` needs no network), builds the binary bundle, checks disk space (datadir plus 6 GB by default), checks every extension against the target image, checks that a rollback could recreate what the upgrade drops, checks that the target image can read your `pgsodium` key, and runs a live `pg_upgrade --check` against a scratch 17 cluster inside the running container.

## In the window

1. Stop autoheal first, then the apps, then the database. Use a fast shutdown (gotcha 25).
2. `bash pg17-upgrade.sh upgrade --yes`.
3. Change the db image in the host compose and in Coolify's stored compose, `docker compose up -d --no-deps supabase-db`, and check that the `coolify` network is back (gotcha 1).
4. Go or no-go, before a fixed deadline ([The window](06-the-window.md) has the checks). Before the go, `rollback` restores the exact state at the stop.
5. Start the apps in dependency order, gateway last, autoheal after everything is healthy.

On production: the script ran for about a minute (the copy itself took well under a minute for our database with `--copy`), and all services were healthy about two minutes after the database stopped.

## After

- Keep the side volume and saved images for a while (we chose 14 days), with "delete unused volumes" off (gotcha 6). Then `docker volume rm <service-uuid>_supabase-db-data-pg15`.
- Take a new base backup and move your WAL tooling to 17 (gotcha 32).
- Take a Coolify backup on 17 too, for parity, but do not rely on it alone (gotcha 10).

## Things to check before you try it

- PG16 changed `CREATEROLE` semantics. If you have SQL tests for role management, rerun them.
- PG17 runs VACUUM, ANALYZE, REINDEX and REFRESH MATERIALIZED VIEW with a safe `search_path`. An expression index or materialized view that calls one of your functions without a schema prefix fails at maintenance time. List those first.
- If you run anything on 17 that depends on `app.settings.jwt_secret`, look at upstream's post-upgrade steps; we had nothing that read it.

## Not covered

The script was tested on arm64 locally and on amd64 servers with these two image tags only. Other tag pairs need the extension gates rechecked, and the order of the extension update pass against `complete.sh` needs a fresh look whenever `supabase_vault` or `pg_net` versions differ between the two images. Upstream runs the extension update pass before `complete.sh`'s patches; this script runs it after. With these two images that is harmless, because both ship the same `supabase_vault` and `pg_net` versions, and the vault grants are re-applied after the update pass anyway.
