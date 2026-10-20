-- hardening-check.sql: read-only checks for the API-facing roles of a self-hosted Supabase database.
--
--   docker cp scripts/. supabase-db-<service-uuid>:/tmp/checks/
--   docker exec supabase-db-<service-uuid> psql -U supabase_admin -d postgres -X -f /tmp/checks/hardening-check.sql
--
-- Sections 1 to 3 should return 0 rows, or only rows you have decided on and can explain. Section 3 always lists
-- views granted to anon/authenticated (a plain view runs as its owner and bypasses RLS): check each view's owner
-- and whether it sets security_invoker. Section 4 shows the
-- default privileges stock Supabase sets (expected); it is why sections 1 and 3 need checking after every migration.
-- Section 5 should list only the built-in admin roles.
-- It only reads catalogs and prints object names, never data. Schemas checked: `public` by default; pass every
-- schema PostgREST exposes with -v schemas="'public','api'".

\set ON_ERROR_STOP on
\pset pager off
set default_transaction_read_only = on;
\if :{?schemas}
\else
\set schemas '''public'''
\endif

\echo '== 1. SECURITY DEFINER functions that anon or authenticated may EXECUTE (reachable as /rest/v1/rpc/<name>)'
select p.oid::regprocedure as function,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef
  and n.nspname in (:schemas)
  and (has_function_privilege('anon', p.oid, 'EXECUTE') or has_function_privilege('authenticated', p.oid, 'EXECUTE'))
order by 1::text;

\echo '== 2. SECURITY DEFINER functions without a safe search_path (must end in pg_temp, or be empty)'
select p.oid::regprocedure as function,
       coalesce((select c from unnest(p.proconfig) c where c like 'search_path=%'), '(none)') as search_path
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where p.prosecdef
  and n.nspname in (:schemas)
  and not exists (
    select 1 from unnest(coalesce(p.proconfig, '{}')) c
    where c = 'search_path=' or c = 'search_path=""' or c ~ 'search_path=.*pg_temp$')
order by 1::text;

\echo '== 3. Tables and views anon or authenticated can read or write, with row level security OFF (views are always listed: check owner and security_invoker)'
select c.oid::regclass as relation,
       c.relkind,
       has_table_privilege('anon', c.oid, 'SELECT') as anon_select,
       has_table_privilege('anon', c.oid, 'INSERT,UPDATE,DELETE') as anon_write,
       has_table_privilege('authenticated', c.oid, 'SELECT') as auth_select,
       has_table_privilege('authenticated', c.oid, 'INSERT,UPDATE,DELETE') as auth_write
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname in (:schemas)
  and c.relkind in ('r', 'p', 'v', 'm', 'f')
  and not c.relrowsecurity
  and (has_table_privilege('anon', c.oid, 'SELECT,INSERT,UPDATE,DELETE')
    or has_table_privilege('authenticated', c.oid, 'SELECT,INSERT,UPDATE,DELETE'))
order by 1::text;

\echo '== 4. Default privileges: what anon and authenticated get on objects created LATER (stock Supabase grants these; informational)'
select pg_get_userbyid(d.defaclrole) as creator,
       d.defaclnamespace::regnamespace as schema,
       case d.defaclobjtype when 'r' then 'tables' when 'S' then 'sequences' when 'f' then 'functions'
            when 'T' then 'types' when 'n' then 'schemas' else d.defaclobjtype::text end as objects,
       pg_get_userbyid(a.grantee) as grantee,
       string_agg(a.privilege_type, ',' order by a.privilege_type) as privileges
from pg_default_acl d
cross join lateral aclexplode(d.defaclacl) a
where a.grantee in ('anon'::regrole, 'authenticated'::regrole)
  and d.defaclnamespace::regnamespace::text in (:schemas)
group by 1, 2, 3, 4
order by 1, 2::text, 3, 4;

\echo '== 5. Roles that can log in with superuser or bypass RLS (expect only the built-in admin roles)'
select rolname, rolsuper, rolbypassrls, rolcanlogin
from pg_roles
where rolcanlogin and (rolsuper or rolbypassrls)
order by rolname;

\echo '== done'
