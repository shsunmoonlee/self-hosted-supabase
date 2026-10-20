-- preflight.sql: read-only inventory of a self-hosted Supabase Postgres before an upgrade.
--
-- Run as supabase_admin (or another superuser) against the `postgres` database:
--   docker cp scripts/. supabase-db-<service-uuid>:/tmp/checks/
--   docker exec supabase-db-<service-uuid> psql -U supabase_admin -d postgres -X -f /tmp/checks/preflight.sql > preflight.out
--
-- Add `-v count_schema=public` for exact row counts of every table in one schema (psql 14 or newer).
--
-- It only reads catalogs. It prints names, counts, owners and sizes, never secret values.
-- Keep the output: verify.sql prints the same sections, so the two files diff cleanly.

\set ON_ERROR_STOP on
\pset pager off
set default_transaction_read_only = on;

\echo '== server'
select version();
show server_version;

\echo '== databases (every one pg_upgrade will touch: datallowconn = true)'
select datname,
       pg_get_userbyid(datdba) as owner,
       datallowconn,
       pg_size_pretty(pg_database_size(oid)) as size,
       pg_database_size(oid) as size_bytes
from pg_database
order by pg_database_size(oid) desc;

\echo '== database ACLs (a database ACL whose grantor differs from its owner can fail the pg_upgrade restore)'
select datname, pg_get_userbyid(datdba) as owner, datacl from pg_database order by datname;

\echo '== extensions in this database'
select extname, extversion, extnamespace::regnamespace as schema from pg_extension order by extname;

\echo '== extensions with no Postgres 17 package in Supabase images (must be 0 rows)'
select extname from pg_extension where extname in ('timescaledb', 'plv8', 'plcoffee', 'plls');

\echo '== extensions dropped before a 15 -> 17 upgrade when unused (pgjwt, wrappers)'
select extname, extversion from pg_extension where extname in ('pgjwt', 'wrappers');
select count(*) as foreign_servers from pg_foreign_server;

\echo '== event triggers (count, owner, function owner)'
select count(*) as event_triggers from pg_event_trigger;
select e.evtname,
       pg_get_userbyid(e.evtowner) as trigger_owner,
       e.evtfoid::regproc as function,
       pg_get_userbyid(p.proowner) as function_owner,
       e.evtenabled
from pg_event_trigger e
join pg_proc p on p.oid = e.evtfoid
order by e.evtname;

\echo '== superuser trigger running a non-superuser function (supautils refuses these during the pg_upgrade restore)'
select e.evtname, e.evtfoid::regproc as function, pg_get_userbyid(p.proowner) as function_owner
from pg_event_trigger e
join pg_proc p on p.oid = e.evtfoid
join pg_roles tr on tr.oid = e.evtowner
join pg_roles fr on fr.oid = p.proowner
where tr.rolsuper and not fr.rolsuper
order by e.evtname;

\echo '== roles that matter for the upgrade'
select rolname, rolsuper, rolcreaterole, rolreplication, rolbypassrls
from pg_roles
where rolname in ('postgres', 'supabase_admin', 'authenticator', 'anon', 'authenticated', 'service_role')
order by rolname;

\echo '== replication slots (logical slots are not carried by pg_upgrade from 15)'
select slot_name, slot_type, plugin, database, active from pg_replication_slots order by slot_name;

\echo '== collation version mismatches (should be 0 rows)'
select datname, datcollversion, pg_database_collation_actual_version(oid) as actual
from pg_database
where datcollversion is distinct from pg_database_collation_actual_version(oid)
  and datallowconn;

\echo '== objects in public owned by supabase_admin'
select
  (select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relowner = 'supabase_admin'::regrole)
+ (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proowner = 'supabase_admin'::regrole) as public_objects_owned_by_supabase_admin;

\echo '== ACL fingerprint per schema (compare before and after; a dump without grants changes these)'
select n.nspname as schema,
       count(*) as relations,
       md5(string_agg(c.relname || ':' || coalesce(c.relacl::text, '-'), ',' order by c.relname)) as relacl_md5
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'v', 'm', 'p', 'f', 'S')
  and n.nspname not like 'pg_%' and n.nspname <> 'information_schema'
group by n.nspname
order by n.nspname;

\echo '== largest tables (how big the pg_upgrade copy will be)'
select n.nspname || '.' || c.relname as relation, pg_size_pretty(pg_total_relation_size(c.oid)) as total
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where c.relkind in ('r', 'p', 'm')
order by pg_total_relation_size(c.oid) desc
limit 15;

-- Optional sections: each runs only when the object exists.
select to_regclass('cron.job') is not null as has_cron \gset
select to_regclass('auth.users') is not null as has_auth \gset
select to_regnamespace('_realtime') is not null as has_realtime \gset

\if :has_cron
\echo '== pg_cron jobs (note the active ids; the upgrade pauses and re-enables exactly these)'
select jobid, jobname, username, database, active from cron.job order by jobid;
select count(*) filter (where active) as active_jobs, count(*) as all_jobs from cron.job;
\endif

\if :has_auth
\echo '== row counts'
select count(*) as auth_users from auth.users;
\endif

\if :has_realtime
\echo '== realtime tenant migrations'
select count(*) as realtime_migrations from _realtime.schema_migrations;
\endif

\if :{?count_schema}
\echo '== exact row counts for every table in schema' :'count_schema' '(can be slow on big tables)'
select format('select %L as relation, count(*) as rows from %I.%I', n.nspname || '.' || c.relname, n.nspname, c.relname)
from pg_class c join pg_namespace n on n.oid = c.relnamespace
where n.nspname = :'count_schema' and c.relkind in ('r', 'p')
order by c.relname
\gexec
\endif

\echo '== done'
