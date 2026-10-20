# 6. Disk and WAL growth

> **Basis.** Verified by us on a production stack (2026-08 to 2026-10): `_supabase` growth from Logflare, Realtime and Logflare replication slots, image pruning on Coolify. **From upstream issues:** the analytics replication slot falling behind ([supabase#43643](https://github.com/supabase/supabase/issues/43643), open) and the large `db-data` reports ([discussion 40546](https://github.com/orgs/supabase/discussions/40546)).

Self-hosted stacks tend to run out of disk in three places: WAL held by replication slots, the `_supabase` database, and Docker images and volumes.

## 1. Replication slots

A replication slot keeps every WAL file its consumer has not confirmed. An inactive or slow consumer means `pg_wal` grows until the disk is full.

Who creates slots in a Supabase stack:
- **Realtime** creates logical slots for its own use. Check after each upgrade hop: a new slot should be active and no old one left behind. In our hops none was, because Realtime's slot is temporary, but an abandoned slot would hold WAL, so check.
- **Logflare (analytics)** keeps a logical slot on `_supabase` while it runs. Upstream has an open issue about `pg_wal` growing because analytics replication falls behind ([supabase#43643](https://github.com/supabase/supabase/issues/43643)).
- **Your own** WAL archiving or replicas.

Check:
```sql
select slot_name, slot_type, database, active, wal_status,
       pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) as retained,
       pg_size_pretty(safe_wal_size) as headroom
from pg_replication_slots order by restart_lsn;
show max_slot_wal_keep_size;                                  -- not -1
select pg_size_pretty(sum(size)) as pg_wal from pg_ls_waldir();
```
Verify: no inactive slot you cannot name; `max_slot_wal_keep_size` is set.

What to do:
- Set `max_slot_wal_keep_size` so one stuck consumer cannot fill the disk. The trade-off: past the cap, the slot is lost and its consumer must resync. For Realtime that is automatic; for your WAL archive it means a new base backup.
- Drop slots that belong to nothing: `select pg_drop_replication_slot('<name>');` (only when `active` is false and you know whose it was).
- If you do not use Logflare, removing it removes its slot ([Trimming](05-trimming-the-stack.md)).

## 2. The `_supabase` database

Logflare (`_analytics` schema) and Supavisor (`_supavisor`) store their data in a separate `_supabase` database. On our stack, Logflare's log tables had made `_supabase` almost twice the size of the application database. The Logflare version we ran did not prune them by itself; we had added our own retention jobs, then removed Logflare altogether. Upstream issues report similar sizes ([discussion 40557](https://github.com/orgs/supabase/discussions/40557)).

Check:
```sql
select datname, pg_size_pretty(pg_database_size(oid)) from pg_database order by pg_database_size(oid) desc;
-- inside _supabase:
select n.nspname, pg_size_pretty(sum(pg_total_relation_size(c.oid))) from pg_class c
join pg_namespace n on n.oid = c.relnamespace where c.relkind = 'r' group by 1 order by sum(pg_total_relation_size(c.oid)) desc;
```

It matters beyond disk: `_supabase` is part of every `pg_dumpall` and every `pg_upgrade` copy. On our stack, keeping Logflare would have made the Postgres 17 copy about three times larger.

## 3. Docker images and volumes

- **Old images pile up** with every upgrade. Prune unused images regularly, but `docker save` the images a rollback needs first, because a prune removes them too.
- **Unused volumes:** never run `docker volume prune` while you keep a rollback volume (for example the old Postgres data after a major upgrade). On Coolify, this is the "delete unused volumes" setting of the server's Docker cleanup ([Coolify](08-coolify.md)).
- **Container logs** (general Docker practice, not one of our findings): set a log size limit (`max-size` / `max-file` in the Docker daemon config or per service), or busy containers fill the disk with JSON logs.

Check:
```bash
df -h /                      # and the filesystem that holds /var/lib/docker
docker system df             # images, containers, volumes, build cache
```

## Alerts worth having

- Disk use above 80 and 90 percent on the Docker filesystem.
- Any inactive replication slot, and slot headroom under half of `max_slot_wal_keep_size`.
- `pg_wal` size growing for an hour while traffic is flat.
- `_supabase` size, weekly, if you run Logflare.
