# 4. Upgrades

> **Basis.** The official mechanics are **from upstream docs** (linked below; we did not re-test `update.sh`). Everything under "What the official guides leave to you" was **verified by us** on 2026-10-19, upgrading a long-running Coolify-managed stack (Kong 2.8 to Envoy, PostgREST 12 to 14, Realtime 2.34 to 2.143, Postgres 15.14 to 17.6), after a full rehearsal on a clone.

## Start with the official guides

Supabase now documents the mechanics well. Read these first; this chapter does not repeat them.

| Guide | What it gives you |
|---|---|
| [Updating self-hosted Supabase](https://supabase.com/docs/guides/self-hosting/updating) | `update.sh`, a three-way merge of your compose with a new release, for installs tracked from the upstream `docker/` directory |
| [Upgrade to Postgres 17](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17) | The `pg_upgrade` script for the stock compose, with rollback steps |
| [Envoy gateway](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy) | The Envoy replacement for Kong |

Also read `docker/versions.md` and `docker/CHANGELOG.md` in [supabase/supabase](https://github.com/supabase/supabase/tree/master/docker) before every upgrade: they list each month's image bumps, and which releases contain one-way migrations.

## What the official guides leave to you

**Installs that `update.sh` cannot track.** It expects a compose that started from upstream's `docker/` directory. A Coolify, Portainer, Swarm or hand-edited install, or one that is years old, needs a manual path: diff your compose against the target release service by service, change one service at a time, and verify each. That is what [upgrades/04-service-hops.md](upgrades/04-service-hops.md) does.

**Order.** Our order, and why ([case study](case-study-2026-10-19.md) has the details):
1. Remove services you do not use ([Trimming](05-trimming-the-stack.md)). Fewer things to upgrade, and a smaller database copy later.
2. Swap the gateway before recreating services behind it. Kong cached old container IPs after recreates ([gotcha 11](gotchas.md)); Envoy re-resolves every 5 seconds.
3. One service at a time, each with its own check.
4. Postgres last, on its own, after the rest has been stable for a while.

**Services that migrate on boot need hops.** Realtime runs its schema migrations on every start and they only go forward. We went 2.34.47 to 2.51.11, 2.76.5, 2.102.3 and 2.143.3: versions that upstream's `versions.md` had pinned, with a `_realtime` schema dump before each hop and a long health check `start_period`. See [Service hops](upgrades/04-service-hops.md).

**Health checks change between versions.** PostgREST 14's `postgrest --ready` needs `PGRST_ADMIN_SERVER_HOST=localhost` next to the admin port ([gotcha 12](gotchas.md)). Realtime's `GET /` needs a `SECRET_KEY_BASE` of at least 64 bytes ([gotcha 13](gotchas.md)). Envoy's image has no curl, so its check is a TCP connect.

**Non-Compose details that bite.** On Coolify, a host-side recreate drops the shared `coolify` network ([gotcha 1](gotchas.md)), the stored compose drifts from the host file, and a later Save reverts host-only edits. See [Coolify](08-coolify.md).

**Clones lie about size.** Rehearse on a clone, then compare the clone with production before trusting its timings ([Rehearse on a clone](upgrades/02-rehearse-on-a-clone.md)).

**Rollback has to be tested too.** Our worst bug was in a rollback path ([gotcha 30](gotchas.md)). Releases with one-way migrations have no image rollback at all; check `CHANGELOG.md` for them before you start.

**Major upgrades end your WAL history.** Point-in-time recovery must start over on the new major ([PITR](03-point-in-time-recovery.md), rule 9).

## The upgrade chapters

| Chapter | Content |
|---|---|
| [01 Inventory and preflight](upgrades/01-inventory-and-preflight.md) | What runs, what depends on what, backups you can restore, settings to check |
| [02 Rehearse on a clone](upgrades/02-rehearse-on-a-clone.md) | Building a faithful clone, what to run, what a clone does not tell you |
| [03 Kong to Envoy](upgrades/03-kong-to-envoy.md) | Porting a custom Kong config, validating Envoy, the swap |
| [04 Service hops](upgrades/04-service-hops.md) | PostgREST 12 to 14, Realtime in four hops, postgres-meta, Studio, Vector |
| [05 Postgres 15 to 17](upgrades/05-postgres-15-to-17.md) | `scripts/pg17-upgrade.sh` for Coolify's named volumes, with prepare gates and rollback |
| [06 The window](upgrades/06-the-window.md) | Maintenance choreography, go/no-go checks, rollback paths |

## Tested matrix

The exact image references and digests we ran are in [versions.md](../versions.md). Tested on 2026-10-19: Postgres `17.6.1.163`, Envoy `v1.39.1`, PostgREST `v14.18`, Realtime `v2.143.3`, postgres-meta `v0.100.0`, Studio `2026.10.12-sha-3699278`, Vector `0.45.0`, GoTrue `v2.197.0`, on Coolify 4.4.6.
