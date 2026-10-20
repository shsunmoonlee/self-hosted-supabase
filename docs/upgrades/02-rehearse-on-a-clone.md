# Upgrades 2: Rehearse on a clone

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose).

We rehearsed every step on a clone of the stack the same morning, and it found two bugs that would have hurt production: the pg_upgrade event-trigger failure (gotcha 21) and a recreate-tool rollback that left the gateway unable to read its config (gotcha 30). It also missed things, which is the second half of this chapter.

## Building the clone

- **Same Coolify, same server class.** We created a separate Coolify project with production's compose and fresh secrets, no public domain and no published port, on a server of the same size.
- **Faithful data.** Restore from your own dumps, not only Coolify's (gotcha 10). Restore as `supabase_admin`, give the db container a larger `/dev/shm`, mount the original `pgsodium` root key, and copy grants if the dump has none. Expect that a current image cannot install some older extension versions that production still has; note each one, because a rollback on production will hit the same limit.
- **Database ownership.** A database you create on the clone should have the same owner as on production (gotcha 29).
- **Do not point anything at production.** Every probe URL, every tool default, every environment variable that names a host should be checked. Our recreate tool refuses a clone run unless the probe and gateway URLs are set explicitly, and refuses a production run if a clone URL is still exported.

## What to run

Run the whole sequence in order, with the same scripts and the same flags you will use on production:

1. Remove unused services ([Trimming the stack](../05-trimming-the-stack.md)).
2. The gateway swap, then roll it back, then forward again ([Kong to Envoy](03-kong-to-envoy.md)).
3. Each service hop ([Service hops](04-service-hops.md)).
4. `pg17-upgrade.sh prepare`, `upgrade`, verify; then a rollback after a deliberately failed upgrade; then a rollback of a finished upgrade with `--discard-pg17-writes`; then a second upgrade ([Postgres 15 to 17](05-postgres-15-to-17.md)).
5. The verification checklist ([The window](06-the-window.md)) after each step.

Record the time of every step. On our clone: about 40 seconds per gateway swap through the recreate tool, about 10 seconds per Realtime hop, about 2 minutes from database stop to all services healthy for the Postgres upgrade, and about 10 seconds for a rollback after a failed pg_upgrade.

## What a clone does not tell you

- **Sizes.** Our clone's `_supabase` database was several hundred times smaller than production's, which was almost twice the size of the app database (gotcha 28). The Postgres copy on production would have been about three times larger than on the clone. We dropped the Logflare schemas before the upgrade, which brought production back to the rehearsed size.
- **Background jobs.** The clone had no pg_cron jobs, so it never exercised disabling and re-enabling real jobs. Our local end-to-end test covers that; check the job count before and after on production anyway.
- **Live sessions and traffic.** The clone had no real clients, so it could not show stale connections, open transactions that delay a shutdown, or a client that depends on a route you are about to remove.
- **Timings.** Use clone timings to size the window, then add margin. Production had more data, more connections and other workloads on the same host.

## Tests that are worth keeping

Our upgrade script has a local end-to-end test that seeds a Postgres 15 database with the extensions we use, then runs every failure point and every rollback path, and checks data, extensions, cron jobs, event triggers and `rolsuper` after each. Two lessons from it:

- **Reproduce the production shape.** The first version passed every check and still failed on production-shaped data, because a fresh image owns its event-trigger functions differently. The test now builds that ownership on purpose.
- **Prove the test can fail.** A mutation run skips the fix on purpose and must fail with the production error. If it passes, the test is not testing the fix.
