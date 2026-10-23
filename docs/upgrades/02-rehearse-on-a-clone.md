# Upgrades 2: Rehearse on a clone

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose). The section "A second rehearsal" comes from a second clone on 2026-10-23, for a smaller change that had not yet run on production when this was written.

We rehearsed every step on a clone of the stack the same morning, and it found two bugs that would have hurt production: the pg_upgrade event-trigger failure (gotcha 21) and a recreate-tool rollback that left the gateway unable to read its config (gotcha 30). It also missed things; see "What a clone does not tell you" below.

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

## A second rehearsal: a config change and one restart (2026-10-23)

The next planned change on production is smaller but touches the live database: a new replication role, new `pg_hba` lines, one file in `conf.d`, and one `docker restart` under running apps. We cloned again for it, and the clone paid for itself again.

**Building it, with the lessons from this one:**

- **Image references from the running containers**, not from Coolify's stored compose, which still named the old Postgres major (gotcha 2).
- **No domain, no shared network.** Remove both the list form and the map form of `SERVICE_URL_*` and `SERVICE_FQDN_*`, replace any `${SERVICE_URL_*}` references with internal URLs, and read every app's `fqdn` back before the first start (gotcha 33). Keep the clone off Coolify's shared `coolify` network (gotcha 34). Drop autoheal: it watches the whole host's Docker socket.
- **Nothing calls out.** Leave pg_cron's `cron.job` and `cron.job_run_details` data out of the restore, so the clone never runs production's scheduled jobs, and pg_net's queue data, so it never sends queued HTTP calls. Leave out Realtime's tenant row too; Realtime seeds a fresh one with the clone's own secrets. Do not copy production's SMTP or log-sink credentials into the clone's environment. Before writing any test data, check for triggers that call pg_net (database webhooks fire on writes and would call the restored production URLs), or give the clone no outbound route. This time we did not mount the `pgsodium` root key: the rehearsal did not need Vault, and without the key nothing stored there can be decrypted on the clone.
- **Grants and queues.** The nightly dump had no grants, so we applied a catalog-level copy of production's grants after the restore, and recreated the pgmq queues (their tables are extension members and are not in the dump; a backup gap worth knowing about on its own).
- **Match the config layout before you rehearse a config change.** The fresh volume's `conf.d` was a symlink where production has a real directory (gotcha 35). Rehearsing on the symlink would have "passed" a change that does not survive a recreate.
- **A stand-in for remote clients.** The new `pg_hba` line admits replication only from the private range the receivers come from. We created a small Docker network inside that range and attached the clone's database to it, so the rule was tested exactly as written. Pick a slice nothing on the clone's host uses: a bridge network hides that slice of addresses from the host itself.

**What we ran:** each step in order; the undo of the steps before the restart, then the steps again; the restart under light load (only our probes: one write every 0.2 s, PostgREST and Auth every 0.5 s, one Realtime broadcast per second) with probes on the database (connect and write), PostgREST and Realtime through the gateway; a real receiver connection from the allowed range; four connections that must be refused (the role on an ordinary database, replication from another network, replication as another user, a wrong password); and the "database does not boot" recovery: we wrote a `conf.d` file that makes Postgres refuse to start, restarted, then removed the file from the config volume with a one-off container (`docker run --rm -v <config volume>:/vol --entrypoint rm <db image> /vol/conf.d/<file>`) and ran `docker start`.

**What it found:** the `conf.d` trap (gotcha 35); an undo that left the role able to log in, so redoing the first step tripped the role script's own guard (it refuses to reuse a role that can already log in); a runbook check for Realtime that would have raised a false alarm (gotcha 36); and three bugs in our own probes (gotchas 36 and 38). Measured: database back in about 6 seconds, PostgREST about 8, Realtime about 20; the "does not boot" recovery took about 30 seconds after the `rm` because of Docker's restart backoff, so wait rather than repeat the command. A busy database shuts down more slowly than this lightly loaded clone; we budget up to a minute.

**Tear it down the same day.** The clone holds a copy of production data. Delete the service with its volumes, the networks you created, the dump copy and any credentials you wrote on the server, the images you pulled only for it, and the project.

## Tests that are worth keeping

Our upgrade script has a local end-to-end test that seeds a Postgres 15 database with the extensions we use, then runs every failure point and every rollback path, and checks data, extensions, cron jobs, event triggers and `rolsuper` after each. Two lessons from it:

- **Reproduce the production shape.** The first version passed every check and still failed on production-shaped data, because a fresh image owns its event-trigger functions differently. The test now builds that ownership on purpose.
- **Prove the test can fail.** A mutation run skips the fix on purpose and must fail with the production error. If it passes, the test is not testing the fix.
