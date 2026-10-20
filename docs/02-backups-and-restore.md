# 2. Backups and restore

> **Basis.** Verified by us: the backup set and the restore traps below come from restore rehearsals on 2026-08-18 and 2026-10-19 (images `supabase/postgres:15.14.1.163` and `17.6.1.163`), and the Coolify behaviour from Coolify's source (`app/Jobs/DatabaseBackupJob.php`, read 2026-10-20). **Untested by us:** Storage backups (we removed Storage), Edge Functions code. For those, see the community thread [supabase discussion 37748](https://github.com/orgs/supabase/discussions/37748).

Self-hosted Supabase has no managed backups ([overview](https://supabase.com/docs/guides/self-hosting); compare [Cloud backups](https://supabase.com/docs/guides/platform/backups)). The official `update.sh` "does not back up Postgres or Storage data" ([updating](https://supabase.com/docs/guides/self-hosting/updating)). So you need your own, and you need to have restored from it at least once.

## What a full backup is

A dump of `postgres` alone is not a full backup. You need all four:

| Part | Command (inside the db container, as `supabase_admin`) | Why |
|---|---|---|
| Roles, memberships, role settings | `pg_dumpall --globals-only > globals.sql` | A per-database dump has none of them |
| Each database, with grants and owners | `pg_dump -Fc -d postgres > postgres.dump` (and `-d _supabase` if you still run Logflare or Supavisor and want their data) | `-Fc` keeps ACLs and owners unless you pass `--no-acl --no-owner` |
| The db config volume | `tar czf db-config.tgz -C <mountpoint of <service-uuid>_supabase-db-config> .` | Holds `pgsodium_root.key`. Without it Vault secrets never decrypt, even from a perfect dump |
| The stack directory | `tar czf stack.tgz -C <stack dir> .` | Compose file, `.env` (all your keys), gateway and Vector config |

Then copy them off the host, encrypted, and keep the encryption key somewhere that does not depend on that host. Every one of these files is a secret.

```bash
# verify: every file is non-empty and the dump is readable
ls -l globals.sql postgres.dump db-config.tgz stack.tgz
pg_restore --list postgres.dump | head -5           # prints a TOC, not an error
tar tzf db-config.tgz | grep -c pgsodium_root.key    # 1
```

## What can go wrong with the backups you already have

- **Coolify's scheduled backup drops grants.** For a single database it runs `pg_dump --format=custom --no-acl --no-owner` and covers only the database you pick. A restore of it had no grants: GoTrue failed with "no schema has been selected to create in" and PostgREST had no table privileges. It also has no roles. Keep using it if you like, but not as your only restore source. ([Coolify chapter](08-coolify.md).)
- **Your `pg_dump` client may crash.** In 2026-08 we found that Coolify's scheduled backup of our database had written one 0-byte file and then nothing for months. On our schema, `pg_dump` 15.8 (inside `supabase/postgres:15.8.1.048` and `15.8.1.085`) segfaulted after warning about circular foreign keys (`pgsodium.key` references itself, as did two of our own tables). `pg_dump` from 15.14 and 17 worked. If you run a 15.8 image, check that your backup files are not empty.
- **A backup nobody restored is a hope.** Nobody noticed the empty backups above until someone looked at the files.

## Restoring: the traps we hit

Restore into a throwaway container of the **same image** as the source, with no network:

```bash
docker run -d --name restore-test --network none --shm-size=1g \
  -e POSTGRES_PASSWORD=<throwaway> -e JWT_SECRET=<throwaway, 32+ chars> -e JWT_EXP=3600 \
  -v <copy of pgsodium_root.key>:/etc/postgresql-custom/pgsodium_root.key:ro \
  supabase/postgres:<same tag as the source>
until docker exec restore-test pg_isready -U postgres -h 127.0.0.1; do sleep 2; done

# roles first (errors for roles the image already created are expected)
docker exec -i restore-test psql -U supabase_admin -h 127.0.0.1 -d template1 < globals.sql

# the image pre-seeds schemas in `postgres`: the restore needs an empty database of that name
docker exec restore-test psql -U supabase_admin -h 127.0.0.1 -d template1 -c "DROP DATABASE postgres WITH (FORCE)"
until docker exec restore-test pg_isready -U postgres -h 127.0.0.1; do sleep 2; done   # see trap 6
docker exec restore-test psql -U supabase_admin -h 127.0.0.1 -d template1 -c "CREATE DATABASE postgres"

# extensions whose versions the image cannot install: create them first (trap 4), then
docker exec -i restore-test pg_restore -U supabase_admin -h 127.0.0.1 -d postgres < postgres.dump
```

What we had to know:

1. **Restore as `supabase_admin`, not `postgres`.** Extension config tables and event triggers fail otherwise.
2. **Give the container a larger `/dev/shm`.** Docker's 64 MB default broke large index builds.
3. **Mount the original `pgsodium` root key**, or Vault rows never decrypt. Copy it with the image's owner and mode (`chown 100:101`, `chmod 640` on the 15.14 and 17.6 images); a key only root can read is not loaded.
4. **The current image may not install your old extension versions.** Our 15.14 image could not install some versions an older database still had (for example `pg_cron` 1.6 and `pg_graphql` 1.5.11). `pg_restore` fails on those `CREATE EXTENSION ... VERSION` statements; create each extension at the image's version before the restore and note the difference.
5. **supautils refused two of our event triggers on restore**, for the same ownership reason that breaks `pg_upgrade` ([gotcha 21](gotchas.md)). Recreate the two by hand as `supabase_admin` afterwards, with the source's ownership, and recount `select count(*) from pg_event_trigger` against the source.
6. **`DROP DATABASE ... WITH (FORCE)` can trigger one crash-recovery restart** through a `pg_cron` / `pg_net` background worker. Wait for `pg_isready` and continue; do not treat it as a failed target.
7. **A dump made with `--no-acl` needs grants from somewhere else.** We copied them from the source database at the catalog level. Easier: dump without `--no-acl`.

## The restore drill

Monthly, and after any change to backups:

1. Restore the newest backup into a throwaway container as above.
2. Compare with the source: `scripts/verify.sql` row counts, event trigger count, extension list, the ACL fingerprints from `scripts/preflight.sql`.
3. Decrypt one Vault secret as `postgres` (`select count(*) from vault.decrypted_secrets;` returns rows without errors).
4. Start GoTrue and PostgREST against it if you can, and sign in once.
5. Write down the date and how long it took. That time is your real recovery time.

## Point-in-time recovery

A nightly dump can lose up to a day. For minutes or seconds, see [Point-in-time recovery](03-point-in-time-recovery.md).
