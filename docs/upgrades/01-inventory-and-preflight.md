# Upgrades 1: Inventory and preflight

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose).

Goal: know exactly what runs, what it depends on, and what a rollback needs, before you change anything. Everything in this chapter is read-only.

## What is actually running

- **List the running images, not the compose file.** `docker ps --format '{{.Names}}\t{{.Image}}'` on the host. Then compare with `docker compose config --images` for the stack. A difference means someone recreated a container from a different file, or the file was edited and never applied.
- **Compare the host compose with Coolify's stored copy.** Fetch it with `GET /api/v1/services/<service-uuid>` and diff it against `/data/coolify/services/<service-uuid>/docker-compose.yml`. Expect drift (gotcha 2). Write down every difference, and decide which side is the truth for each before the window. For us the host file was the truth everywhere.
- **Record the networks and aliases of every container.** Gotcha 1 explains why this matters.

  ```bash
  for c in $(docker ps --filter label=com.docker.compose.project=<service-uuid> --format '{{.Names}}'); do
    echo "$c $(docker inspect -f '{{json .NetworkSettings.Networks}}' "$c" | jq -c 'map_values(.Aliases)')"
  done
  ```
- **Find out who uses each service.** For each service you want to remove, look for real clients. Examples from our stack: Supabase Storage had zero buckets and zero objects; the Supavisor pooler held only its own internal sessions (we sampled `pg_stat_activity` three times); nothing called Logflare through the gateway. Those findings are why we could remove them instead of upgrading them.

## The database

Run `scripts/preflight.sql` as `supabase_admin` and keep the output. It prints:

- server version and every database with its size and owner (`_supabase` can be much larger than `postgres`; gotcha 28);
- extensions, including the ones Postgres 17 images do not ship (`pgjwt`) and the ones that block the upgrade;
- event triggers with their owners and their functions' owners, and the combinations supautils will refuse during pg_upgrade (gotcha 21);
- `postgres`'s `rolsuper`, replication slots, collation mismatches;
- an ACL fingerprint per schema, which you compare after the upgrade;
- pg_cron jobs and which are active;
- optionally, exact row counts for one schema (`-v count_schema=public`).

## Secrets and configuration

- Run `scripts/check-secret-lengths.sh <stack dir>/.env <stack dir>/docker-compose.yml`. It prints names and lengths only. Every variable interpolated into `SECRET_KEY_BASE` must be at least 64 characters (gotcha 13), and every secret-like variable must be non-empty.
- Note which variables are Coolify "magic" variables (`SERVICE_PASSWORD_*`, `SERVICE_URL_*`, ...). A new one only gets a value on a Coolify Save (gotcha 8).

## Backups that you can actually restore

Coolify's scheduled backup is useful but not enough (gotcha 10). Before the window, inside the db container, as `supabase_admin`, into a 0700 directory:

```bash
pg_dumpall --globals-only > globals.sql                 # roles, memberships, role settings
pg_dump -Fc -d postgres > postgres.dump                 # with grants and owners
pg_dump -Fc -d _supabase > _supabase.dump               # or only the schemas you keep; can be large
tar czf service-dir.tgz -C /data/coolify/services/<service-uuid> .   # compose, .env, bind files
```

Copy them off the host. Also keep the `pgsodium` root key from the db config volume, and treat every one of these files as a secret.

## Coolify settings to check

- **Docker cleanup, per server:** is "delete unused volumes" on? Turn it off until the rollback volume is gone (gotcha 6).
- **Cleanup schedule:** keep your window, including image pre-pulls, clear of it (gotcha 7).
- **`connect_to_docker_network`** on the service: note its value; check it again after every Coolify save or PATCH.

## Decide in advance

- The no-go deadline for the database step, and who decides.
- What you will drop (extensions, schemas, whole services) and what export you take before each drop.
- How long you keep the old data volume and the rollback images. We chose 14 days.
