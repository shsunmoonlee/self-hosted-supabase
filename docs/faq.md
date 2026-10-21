# FAQ

> **Basis.** Short answers with links. "We" answers come from our own stack (verified 2026-08 to 2026-10-20); everything else links its upstream source.

**Is self-hosting Supabase worth it compared with Supabase Cloud?**
It depends on whether you want to own operations. Cloud includes managed backups and point-in-time recovery ([Cloud backups](https://supabase.com/docs/guides/platform/backups)); self-hosted leaves backups, PITR, security and monitoring to you ([self-hosting overview](https://supabase.com/docs/guides/self-hosting)). This handbook is about doing that part well.

**What hardware do I need?**
See the requirements in the official [Docker guide](https://supabase.com/docs/guides/self-hosting/docker). Plan disk for growth you might not expect: replication slots and Logflare's tables ([Disk and WAL growth](06-disk-and-wal-growth.md)).

**How do I back up a self-hosted Supabase?**
Roles (`pg_dumpall --globals-only`), each database (`pg_dump -Fc` with grants), the db config volume that holds the `pgsodium` key, and the stack directory. Then restore it once. See [Backups and restore](02-backups-and-restore.md).

**Does self-hosted Supabase have point-in-time recovery?**
Not built in. You can add WAL archiving yourself; see [Point-in-time recovery](03-point-in-time-recovery.md) for a design and its safety rules, or tools such as [pgBackRest](https://pgbackrest.org/) and [WAL-G](https://github.com/wal-g/wal-g).

**How do I update the images?**
For a stock install, the official [update guide](https://supabase.com/docs/guides/self-hosting/updating) and `update.sh`. For an older or platform-managed install, see [Upgrades](04-upgrades.md).

**How do I upgrade Postgres 15 to 17?**
Stock compose: the [official guide](https://supabase.com/docs/guides/self-hosting/postgres-upgrade-17). Coolify (named volumes): [Postgres 15 to 17](upgrades/05-postgres-15-to-17.md). Either way, rehearse on a clone and expect to rebuild any WAL archiving.

**Kong or Envoy?**
Upstream's default gateway is now Envoy ([Envoy guide](https://supabase.com/docs/guides/self-hosting/self-hosted-envoy)). If you have custom Kong routes, port them first and test: [Kong to Envoy](upgrades/03-kong-to-envoy.md). Known Envoy difference: header names with underscores are rejected ([supabase#51791](https://github.com/supabase/supabase/issues/51791), open).

**Why does `pg_wal` (or the db volume) keep growing?**
Usually a replication slot whose consumer is gone or behind, often the analytics one ([supabase#43643](https://github.com/supabase/supabase/issues/43643)), or Logflare's own tables in `_supabase`. See [Disk and WAL growth](06-disk-and-wal-growth.md).

**Can I remove services I do not use?**
Yes, with evidence that nothing uses them and attention to what depends on them. See [Trimming the stack](05-trimming-the-stack.md).

**How do I keep Studio private?**
Keep it off the public internet, or put real authentication in front of it. Basic auth alone is the stock setup. See [Studio: private by default](09-studio-private-by-default.md) for three patterns with a verify step each, [Production checklist](01-production-checklist.md) item 1, and [Vadko's Studio guide](https://gist.github.com/Vadko/bb21b01757a3ca2c82f04343babcf333) for SSO options on Envoy.

**Can I run multiple projects on one self-hosted instance?**
Not in the way Cloud does; one stack is one project. See the long-running request in [supabase discussion 4907](https://github.com/orgs/supabase/discussions/4907).

**How do I change the database password or the JWT secret?**
Both touch several services and every issued token. Start from the community thread [supabase discussion 20929](https://github.com/orgs/supabase/discussions/20929) and the [Docker guide](https://supabase.com/docs/guides/self-hosting/docker). We have not documented a tested procedure here.

**What is `SECRET_KEY_BASE` and why does Realtime return 500?**
Realtime needs it to be at least 64 bytes; a shorter or empty value makes routes that use the session fail ([gotcha 13](gotchas.md), [supabase#11520](https://github.com/supabase/supabase/issues/11520)).

**I run Supabase on Coolify. What is different?**
Almost everything about changing a running stack. Read [Coolify](08-coolify.md) before your next change.

**What about Kubernetes?**
See [supabase-kubernetes](https://github.com/supabase-community/supabase-kubernetes) (community Helm chart). This handbook is tested on Docker Compose only.

**Edge Functions, Storage, the pooler?**
Not tested by us; see the [official guides](https://supabase.com/docs/guides/self-hosting).
