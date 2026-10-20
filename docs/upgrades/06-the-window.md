# Upgrades 6: The window, verification and rollback

> **Basis.** Verified by us on 2026-10-19: rehearsed on a clone with production data, then run on a production stack (Coolify 4.4.6, Docker Compose).

## Before the window

- **Tell users.** We showed an in-app banner some time ahead and a maintenance page for the database step. The page was set to 60 minutes, much longer than the expected two minutes of downtime: lifting it early is free, and you cannot extend it easily while the database is down if the page itself needs the database.
- **Pause intake.** Stop accepting new background work about 20 minutes before the database step, so jobs in flight can finish.
- **Pause consumers.** Scale background workers, schedulers and synthetic checks down, and record what you changed so you can put it back exactly.
- **Mute paging.** Disable uptime alerts for the window, and put a reminder on re-enabling them.
- **Merge freeze.** No deploys to anything that talks to this stack.
- **Pre-pull** every image by digest and run `pg17-upgrade.sh prepare` again.

## Order inside the window

1. Remove unused services ([Trimming the stack](../05-trimming-the-stack.md)).
2. Kong to Envoy, then a hold on real traffic ([Kong to Envoy](03-kong-to-envoy.md)).
3. Service hops ([Service hops](04-service-hops.md)).
4. Postgres 15 to 17 ([Postgres 15 to 17](05-postgres-15-to-17.md)).

Steps 1 to 3 had no or seconds-long user impact for us. Step 4 is the only real outage. Leave slack: our plan allowed for one surprise, and a second one would have moved the database step to another day. We had three small surprises (gotchas 11, 12 and 13) before the database step and still had time.

## Checks after each recreate

- The internal path your apps use through the gateway, not only the public URL (gotcha 1).
- The container's networks match the record.
- A request that exercises the changed service.
- No new errors in that container's log for a few minutes.

## Go / no-go for the database step

Set a deadline (ours was 25 minutes after the database stopped) and check, with `scripts/verify.sql` and a diff against the preflight output:

- server version is 17.x;
- event trigger count equals the preflight count;
- active pg_cron jobs equal the preflight list (minus any you removed on purpose);
- row counts equal for the tables you chose;
- `postgres` is not a superuser;
- no collation mismatch;
- the ACL fingerprints match, or every difference is explained;
- `_supabase` is present;
- sign-in works, a REST read works, a Realtime broadcast is delivered.

We started the apps as soon as the automated checks passed, to keep the outage short, and the go decision came about 15 minutes later. That meant a no-go would have discarded whatever the apps wrote on 17 in between. Decide that trade-off before the window.

## Rollback paths

| Situation | What to do |
|---|---|
| A service recreate fails its checks | Restore the snapshot's compose, `.env` and bind files (with their original modes, gotcha 30), recreate that one container, reconnect networks, PATCH the old raw compose back into Coolify |
| Envoy misbehaves | Same as above with `kong.yml`; on the clone this took about 11 seconds |
| A Realtime hop wedges | Stop Realtime, restore `_realtime` from the hop's dump, drop the new slots, previous image |
| pg_upgrade fails | `pg17-upgrade.sh rollback --yes`, keep the db image at 15, start the apps. Never start 15 by hand from the side volume: it still has the temporary SUPERUSER grant until `rollback` takes it back |
| No-go after a finished upgrade | Stop the db, `pg17-upgrade.sh rollback --yes --discard-pg17-writes`, db image back to 15, start the apps |
| After the go | Fix forward |

## After the window

- Resume everything you paused, in reverse order, and re-enable paging.
- Check every job that failed around the window against its event history, and retry the ones the window caused. For us that was none: the one job in flight resumed by itself (gotcha 31).
- Take a database backup on 17, and set up your WAL archiving or point-in-time recovery again on 17 (gotcha 32).
- Keep the rollback volume and images for the period you chose, then remove them.
- Write down every deviation from the plan while it is fresh. Most of the gotchas in this repo came from that list.
