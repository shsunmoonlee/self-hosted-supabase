-- verify.sql: read-only checks after an upgrade, in the same shape as preflight.sql.
--
--   docker cp scripts/. supabase-db-<service-uuid>:/tmp/checks/      (verify.sql includes preflight.sql with \ir)
--   docker exec supabase-db-<service-uuid> psql -U supabase_admin -d postgres -X -v expect_major=17 -f /tmp/checks/verify.sql > verify.out
--   diff preflight.out verify.out    # expected differences: version lines, extension versions, sizes
--
-- Set -v expect_event_triggers=<n> and -v expect_active_cron=<n> to the numbers from preflight.out to turn
-- those into hard checks. Every check prints PASS or FAIL; nothing is changed.

\set ON_ERROR_STOP on
\pset pager off
set default_transaction_read_only = on;

\if :{?expect_major}
\else
\set expect_major 17
\endif

\echo '== checks'
select case when current_setting('server_version_num')::int / 10000 = :expect_major::int
            then 'PASS' else 'FAIL' end as server_major_is_expected,
       current_setting('server_version') as server_version;

select case when not rolsuper then 'PASS' else 'FAIL' end as postgres_is_not_superuser
from pg_roles where rolname = 'postgres';

select case when count(*) = 0 then 'PASS' else 'FAIL' end as no_collation_mismatch, count(*) as mismatches
from pg_database
where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid);

\if :{?expect_event_triggers}
select case when count(*) = :expect_event_triggers::int then 'PASS' else 'FAIL' end as event_trigger_count,
       count(*) as event_triggers
from pg_event_trigger;
\endif

select to_regclass('cron.job') is not null as has_cron_v \gset
\if :has_cron_v
\if :{?expect_active_cron}
select case when count(*) filter (where active) = :expect_active_cron::int then 'PASS' else 'FAIL' end as active_cron_jobs,
       count(*) filter (where active) as active
from cron.job;
\endif
\endif

select case when count(*) = 0 then 'PASS' else 'FAIL' end as no_inactive_logical_slots
from pg_replication_slots where slot_type = 'logical' and not active;

\echo '== the same inventory as preflight.sql, for the diff'
\ir preflight.sql
