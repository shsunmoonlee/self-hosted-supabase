# Case study: one maintenance window, 2026-10-19

> **Basis.** Our own production window and its same-day rehearsal. Numbers are rounded.

We run a production app on self-hosted Supabase, deployed as a Coolify service on one server. By October 2026 the stack had drifted far from upstream: Kong 2.8, Postgres 15, Realtime from the 2.34 line, and six services we did not use. We brought it to current upstream versions in one sitting.

## Before

| Service | Before | After |
|---|---|---|
| Postgres | 15.14 | 17.6 |
| Gateway | Kong 2.8.1 | Envoy v1.39.1 |
| PostgREST | v12.2.12 | v14.18 |
| Realtime | v2.34.47 | v2.143.3 |
| postgres-meta, Studio, Vector | old | current |
| Storage, imgproxy, MinIO, Logflare, Supavisor | running, unused | removed |

## Timeline (the same day)

1. **Morning: rehearsal on a clone.** Same Coolify, same server class, production data restored. Every step and every rollback was run. Two bugs found and fixed before production: pg_upgrade failing on event-trigger ownership ([gotcha 21](gotchas.md)), and our recreate tool's rollback restoring `kong.yml` unreadable ([gotcha 30](gotchas.md)).
2. **Afternoon: announce.** An in-app banner, then a maintenance page scheduled for the database step.
3. **Prechecks.** Pre-pull every image by digest, run the upgrade script's `prepare` gates, take faithful dumps off the host ([Backups](02-backups-and-restore.md)).
4. **Remove six services** (about 8 minutes, no user impact). Drop Logflare's schemas after exporting what we wanted ([Trimming](05-trimming-the-stack.md)).
5. **PostgREST 12 to 14.** First attempt rolled back by itself: the health check needed `PGRST_ADMIN_SERVER_HOST=localhost` ([gotcha 12](gotchas.md)). Second attempt went live. Kong then kept routing to old container IPs until `kong reload` ([gotcha 11](gotchas.md)).
6. **Kong to Envoy**, earlier than planned because of step 5. A few seconds of gateway errors on the clone; on production every gateway check passed with no 5xx.
7. **Realtime, four hops** behind Envoy, about seven minutes in all. While checking it we found its `SECRET_KEY_BASE` had always been empty ([gotcha 13](gotchas.md)) and set it.
8. **Postgres 15 to 17.** Intake paused, workers paused, paging muted. The script ran for about a minute; all services were healthy about two minutes after the database stopped. Apps restarted as soon as the automated checks passed; the go decision came about 15 minutes later.
9. **Lift the page, resume everything.** The one background job in flight resumed by itself once the workers were back; a job that had failed just before the window turned out to be unrelated ([gotcha 31](gotchas.md)).
10. **After:** a Vector transform error on Postgres lines without a severity tag, fixed by taking upstream's `vector.yml` fix ([gotcha 17](gotchas.md)).

## What worked

- Removing before upgrading.
- One service block per change, one container per recreate, each followed by a check of the internal path.
- A rehearsal that included every rollback.
- Faithful dumps and a saved copy of every rollback image before starting.
- A deadline for the database go/no-go, decided in advance.

## What we would change

- Swap the gateway first, before any service recreate.
- Compare the clone with production (database sizes, cron jobs) before trusting clone timings ([gotcha 28](gotchas.md)).
- Read a failed job's event history before counting it as window damage ([gotcha 31](gotchas.md)).
- Plan point-in-time recovery on the new major in the same window ([gotcha 32](gotchas.md)).

Full runbook: [Upgrades](04-upgrades.md) and its six sub-chapters.
