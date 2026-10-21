# 1. Production checklist and hardening

> **Basis.** Items marked **[verified]** were checked by us on a production stack between 2026-08 and 2026-10-20 (Supabase self-hosted on Docker Compose, managed by Coolify; Postgres 15.14 and 17.6 images). Items marked **[upstream]** come from the linked Supabase docs and were not re-tested by us for this guide.

The official [self-hosting overview](https://supabase.com/docs/guides/self-hosting) is clear that security, backups and monitoring are the operator's job. This is the list we work through on every stack. Each item ends with a check you can run.

## Network exposure

**1. Studio and admin ports are not reachable from the internet.** [verified]
Studio, Postgres (`5432`), the pooler (`6543`), the gateway's own port (`8000`), Realtime (`4000`) and postgres-meta should be reachable only from where you need them. Put the public API behind your reverse proxy and keep everything else private. The stock compose protects Studio with basic auth only ([docker guide](https://supabase.com/docs/guides/self-hosting/docker)); there is a long issue history of people finding their Studio open ([supabase#4934](https://github.com/supabase/supabase/issues/4934)). Three ways to keep it private: [Studio: private by default](09-studio-private-by-default.md).

Check, from a machine outside your network:
```bash
for port in 5432 6543 8000 4000 3000; do nc -z -w 3 <public-ip> $port && echo "OPEN $port" || echo "closed $port"; done
curl -s -o /dev/null -w '%{http_code}\n' https://<api-host>/            # not Studio: expect 404 or your own page; 401 means Studio is still there behind one shared password, see chapter 9
```

**2. The gateway blocks the admin APIs.** [verified]
Kong-based stacks, upstream's included before self-hosted v0.6.0 and v0.7.0 closed these, served two things to anyone holding the anon key: the PostgREST OpenAPI document (`GET /rest/v1/`) and Realtime's own API description (`/realtime/v1/api/openapi`). Upstream's Envoy config blocks both, and blocks the Realtime tenant admin API (`/realtime/v1/api/tenants`) for every caller. Check:
```bash
ANON=<anon key>
curl -s -o /dev/null -w 'tenants %{http_code}\n' https://<api-host>/realtime/v1/api/tenants -H "apikey: $ANON"   # 403
curl -s -o /dev/null -w 'openapi %{http_code}\n' https://<api-host>/rest/v1/ -H "apikey: $ANON"                  # 403 on Envoy
curl -s -o /dev/null -w 'analytics %{http_code}\n' https://<api-host>/analytics/v1/                               # not 200
```

## Keys and secrets

**3. No default keys.** [upstream]
The example `.env` ships placeholder secrets. Generate your own JWT secret, anon and service keys and every password before the first start, as the [docker guide](https://supabase.com/docs/guides/self-hosting/docker) describes. Rotating the JWT secret later invalidates every issued token and both API keys, so plan it as a change, not a quick fix. Read [API keys](https://supabase.com/docs/guides/api/api-keys) for the newer key types.

**4. Every secret has the length its consumer expects.** [verified]
Realtime's `SECRET_KEY_BASE` must be at least 64 bytes; ours had been empty for months because a template referenced a variable nobody filled ([gotcha 13](gotchas.md)). Upstream also has an open request to document it properly ([supabase#11520](https://github.com/supabase/supabase/issues/11520)). Check names and lengths without printing values:
```bash
bash scripts/check-secret-lengths.sh <stack dir>/.env <stack dir>/docker-compose.yml   # exit 0
```

**5. `service_role` never leaves the server.** [upstream]
The service key bypasses row level security. It belongs in server-side code and admin tools only; browsers and mobile apps get the anon (or publishable) key. See [Securing your API](https://supabase.com/docs/guides/api/securing-your-api). Check your client bundles: `grep -r "<first 20 chars of the service key>" <build output>` should find nothing.

**6. The `pgsodium` root key and the `.env` are treated as secrets, and backed up.** [verified]
The db config volume (`/etc/postgresql-custom`, `pgsodium_root.key`) decrypts Vault secrets. Lose it and every Vault secret is gone, even with a perfect database dump. See [Backups](02-backups-and-restore.md).

## Database roles and grants

**7. Know what Supabase grants by default.** [verified on a fresh `supabase/postgres:17.6.1.163`]
Supabase sets default privileges so that every new table, sequence and function in `public` is granted to `anon` and `authenticated` the moment it is created, including `EXECUTE` on functions. That is convenient, and it means row level security (on tables) and explicit revokes (on functions) are what actually protect your data. Section 4 of `scripts/hardening-check.sql` prints those defaults.

**8. Row level security on every exposed table.** [verified]
Any table in an exposed schema with RLS off is readable (and often writable) through `/rest/v1/` by anyone with the anon key. See [Row Level Security](https://supabase.com/docs/guides/database/postgres/row-level-security) and the [Security Advisor](https://supabase.com/docs/guides/observability/advisors), which flags tables without RLS.

**9. SECURITY DEFINER functions are locked down.** [verified]
A `SECURITY DEFINER` function runs with its owner's rights and bypasses RLS. In an exposed schema it is callable as `POST /rest/v1/rpc/<name>` by anyone with the anon key, because of item 7. For each one:
- `revoke execute on function <fn> from public, anon, authenticated;` then grant it only to the roles that need it;
- pin a safe `search_path`: one that ends in `pg_temp` (`set search_path = public, pg_temp`) or the empty one (`set search_path = ''` with fully qualified names). Postgres searches the temporary schema first when `pg_temp` is not listed explicitly, so `search_path = public` alone can still be shadowed by a temporary table;
- remember trigger functions: `EXECUTE` on them is checked when someone creates a trigger, so revoke it too.

```bash
docker exec supabase-db-<service-uuid> psql -U supabase_admin -d postgres -X -f /tmp/checks/hardening-check.sql
# sections 1-3: 0 rows (or only rows you can explain); section 5: only the built-in admin roles
```
Run it after every migration, not once: grants live in the database, not in your migration files.

**10. No superuser for the app.** [upstream]
The app connects as a normal role. Supabase documents how to [remove superuser access](https://supabase.com/docs/guides/self-hosting/remove-superuser-access) from `postgres` on self-hosted stacks. After a Postgres major upgrade, check that `postgres` is not left a superuser (the upgrade grants it temporarily; [gotcha 21](gotchas.md)):
```sql
select rolsuper from pg_roles where rolname = 'postgres';   -- f
```

## Operations

**11. Faithful backups exist and have been restored at least once.** [verified] See [Backups and restore](02-backups-and-restore.md).

**12. Replication slots cannot fill the disk.** [verified] `max_slot_wal_keep_size` is set, and you alert on inactive slots. See [Disk and WAL growth](06-disk-and-wal-growth.md).

**13. You probe the path your app uses.** [verified] A public uptime check can stay green while the app's internal path to the gateway is broken. See [Monitoring](07-monitoring-and-health-checks.md).

**14. Every image is pinned by digest, and the rollback images are saved.** [verified] See [Upgrades](04-upgrades.md).

**15. On Coolify: "delete unused volumes" is off while you keep a rollback volume.** [verified] See [Coolify](08-coolify.md).

## Not covered here (untested by us)

Storage (S3 backends, image transformation), Edge Functions, the connection pooler under load, SSO/SAML and multi-node setups. Start from the [official self-hosting guides](https://supabase.com/docs/guides/self-hosting) for those.
