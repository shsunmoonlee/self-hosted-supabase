# Gotchas: things that broke, or nearly did

> **Basis.** Each entry was hit or verified by us on a production stack or its rehearsal clone, 2026-08 to 2026-10-20, unless it links an upstream issue as its source.

Each entry: what happened, why, and what to do. "Fixed" means fixed in our stack or in our scripts; upstream status is linked where one exists. Numbers are rounded.

## Coolify

**1. A host-side recreate drops the `coolify` network.** Coolify attaches service containers to its shared `coolify` network (with an alias like `<service>-<service-uuid>`) as a separate `docker network connect` step during its own deploys. That network is not in the compose file on disk. So `docker compose up -d --force-recreate <service>` on the host builds a container without it. Anything that reaches the service over `coolify` (another app on the same server, for example) fails, while public checks that go through the proxy on the service network stay green. This happened to us more than once before this migration. Record each container's networks and aliases before a recreate (`docker inspect -f '{{json .NetworkSettings.Networks}}'`), reconnect any that are missing with exactly the recorded aliases, and probe a path that uses the internal hop, not only the public URL. `scripts/safe-recreate.sh` does all three. A newer Coolify change ([coollabsio/coolify#11371](https://github.com/coollabsio/coolify/issues/11371)) connects the network before start during Coolify's own deploys; it does not change the compose file on disk, so host-side recreates are still affected.

**2. The host compose file is the truth; Coolify's stored copy drifts.** The compose that Coolify returns over its API (`GET /api/v1/services/<service-uuid>`) differed from the file in `/data/coolify/services/<service-uuid>/docker-compose.yml` for every service in our stack (for us, network declarations and environment rows). The host file is what runs. Take rollback snapshots from the host file, and treat it as the truth when the two disagree.

**3. Record every compose change in Coolify, or the next deploy reverts it.** A change made only on the host disappears at the next Coolify Save or Deploy. We wrote every change twice: into the host file (what runs now) and into Coolify's raw compose with `PATCH /api/v1/services/<service-uuid>` (`docker_compose_raw` base64-encoded, `instant_deploy: false`, so the PATCH does not deploy). Keep a copy of the raw compose before each PATCH, and check that `connect_to_docker_network` is still true afterwards.

**4. Redeploy recreates every container; the Stop button removes them.** A Coolify Redeploy recreates the whole stack, not one service. The Stop button runs `docker rm -f` and queues a cleanup (documented in [Vadko's migration guide](https://gist.github.com/Vadko/57d1dbc309f5b7440036f6606027643f), and it matched what we saw). For maintenance we used `docker stop` and one-container recreates only.

**5. "Load from server" has no API.** Files that Coolify manages as file storages (`content:` mounts such as `vector.yml` or the Envoy config files) are stored in Coolify's database. After you edit one on the host, press "Load from server" for that row in the UI, or a later Save writes the stored copy back over your file. We found no API for it. Afterwards compare three checksums: the stored row, the host file, and your repository copy.

**6. Keep "delete unused volumes" off while a rollback volume exists.** Coolify's Docker cleanup can run `docker volume prune -af`. Our Postgres 15 data sat in a side volume that no container used, which is exactly what that prune deletes. Check the setting per server before the window and leave it off until you drop the side volume.

**7. The nightly cleanup also prunes images, including the ones you pre-pulled.** Images that no running container uses are removed by the scheduled cleanup. That includes images you pulled for the window and the old images a rollback needs. Keep the window clear of the cleanup time, and `docker save` the rollback images (old Postgres, old gateway) to a file until you are sure you will not roll back.

**8. A new "magic" variable is generated only on a Save.** Coolify generates values for `SERVICE_PASSWORD_*` style variables when it parses the compose on a Save. If you add one by editing the host file only, it does not exist yet. Before a recreate, confirm the name is in the rendered `.env` with a non-empty value (`scripts/check-secret-lengths.sh` prints names and lengths only).

**9. The rendered `.env` has no trailing newline.** A bare `echo NAME=value >> .env` glued the new variable onto the last line. Start every append with a newline. That is how our clone's postgres-meta started healthy with an empty `CRYPTO_KEY`: the appended name was glued onto the previous line.

**10. Coolify's scheduled backup is not a faithful restore source for Supabase.** For a single database it runs `pg_dump --format=custom --no-acl --no-owner` (see `app/Jobs/DatabaseBackupJob.php` in Coolify), and it covers only the database you select, usually `postgres`. A restore of that dump had no grants: GoTrue failed with "no schema has been selected to create in" and PostgREST had no table privileges. Roles and role memberships live outside any per-database dump. Before the window we took our own dumps: `pg_dumpall --globals-only`, then `pg_dump -Fc` per database, plus a tarball of the stack directory.

## Supabase services

**11. Kong 2.8 kept routing to old container IPs.** After we recreated PostgREST and postgres-meta, Kong answered `connect() failed (113: Host is unreachable)` for minutes, because it had cached the old container IPs. `kong reload` inside the container fixed it at once. Upstream later lowered Kong's DNS TTL in the self-hosted config for this reason ([supabase/supabase#47846](https://github.com/supabase/supabase/pull/47846)). Envoy's `STRICT_DNS` clusters re-resolve every 5 seconds, so we moved the gateway to Envoy first and did the remaining service upgrades behind it.

**12. PostgREST v14's `postgrest --ready` health check needs the admin server on localhost.** We set `PGRST_ADMIN_SERVER_PORT=3001` but not `PGRST_ADMIN_SERVER_HOST=localhost`. The container never became healthy, and our recreate tool rolled it back after 90 seconds. With the host set, it went live on the second attempt. Upstream's compose has both (see [supabase/supabase#46642](https://github.com/supabase/supabase/issues/46642)).

**13. Realtime ran for months with an empty `SECRET_KEY_BASE`.** Our service came from an older Coolify template that set `SECRET_KEY_BASE=${SECRET_PASSWORD_REALTIME}`. That name does not start with `SERVICE_`, so Coolify never generated a value, and the variable stayed empty. Realtime still served websockets, but routes that use the session failed with `cookie store expects conn.secret_key_base to be at least 64 bytes`, so `GET /` returned 500. Envoy's health check for the Realtime cluster requests `/`, which is where it showed up for us. Coolify fixed the template for new services ([coollabsio/coolify#11999](https://github.com/coollabsio/coolify/issues/11999)); an existing service keeps its empty value until you set one. We set a 64-character value in both the host `.env` and Coolify's environment rows. Lesson: before an upgrade, check the length of every secret the compose interpolates.

**14. Realtime migrations only go forward.** Realtime runs its schema migrations on every boot, and an older image may refuse to start on a newer schema. We went 2.34 to 2.143 in four hops (see [service hops](upgrades/04-service-hops.md)), took a `pg_dump` of the `_realtime` schema before each hop, and gave the container a 90-second health check `start_period` so nothing restarted it mid-migration. Keep `DB_ENC_KEY` unchanged (tenant rows are encrypted with it) and keep the container name, which Realtime parses for the tenant id.

**15. Autoheal will happily restart a container in the middle of a migration.** If you run an autoheal container, stop it first and start it last.

**16. Kong's entrypoint evaluated backticks in `kong.yml` comments.** A comment containing a backtick-quoted word was executed as a command at start. It was harmless for us, and it went away with Envoy, but do not put backticks in Kong config comments.

**17. Our Vector `db_logs` transform failed with `function call error for "upcase"`.** Fixed. In the remap, `parsed, err = parse_regex(...)` leaves `parsed` as an empty object (not null) when the regex does not match, so the old guard `if parsed != null` was always true. A Postgres line with no severity tag (`STATEMENT:`, `DETAIL:`, continuation lines) set the severity to null, and `upcase!` failed. Upstream had already fixed this ([supabase/supabase#41800](https://github.com/supabase/supabase/pull/41800)); our copy of `vector.yml` predated the fix. We reproduced and verified it with `vector vrl --input events.ndjson --program x.vrl --print-object` on the Vector image we run. Lesson: when you upgrade, diff your `vector.yml` against upstream's. A stale copy keeps old bugs.

**18. Check Vector's S3 sink against your object store before you bump Vector.** With Logflare gone, Vector writes only to an S3-compatible bucket. Our store did not accept uploads from Vector 0.46 and later (newer SDK checksum headers, [vectordotdev/vector#23029](https://github.com/vectordotdev/vector/issues/23029)), so we stayed on 0.45.

**19. Envoy rejects request header names with underscores.** Kong's nginx silently dropped them; Envoy answers 400. Check your clients. Also, `GET /rest/v1/` (the OpenAPI document) needs the service key under upstream's Envoy config, and the Realtime tenant API is blocked. Both are intended.

**20. `envoy --mode validate` does not load file-based CDS/LDS.** It reports "loading 0 cluster(s)" and passes. To validate the real config, render the template with test keys and fold clusters and listeners into one static bootstrap, then validate that.

## Postgres 15 to 17

**21. pg_upgrade failed on event-trigger ownership.** Older Supabase databases have `grant_pg_cron_access()` and `grant_pg_net_access()` owned by `postgres` ([supabase/postgres#1437](https://github.com/supabase/postgres/issues/1437)), while a trigger that calls one is owned by `supabase_admin`. During pg_upgrade's schema restore, supautils refused it: "Superuser owned event trigger must execute a superuser owned function". Supabase's own `initiate.sh` makes `postgres` a superuser for the run and `complete.sh` takes it back; our first rewrite of the script skipped that step, and a fresh test database does not show the problem. We found it only on a clone of real data. `scripts/pg17-upgrade.sh` records `rolsuper`, grants it for the run, restores the recorded value, and fails if `postgres` is left a superuser.

**22. Some extensions do not exist on 17.** `pgjwt` is not in the Postgres 17 images; `wrappers` with no foreign servers can be dropped first. `timescaledb`, `plv8`, `plcoffee` and `plls` block the upgrade. `pg_graphql`, `pg_stat_monitor` and `pgaudit` are dropped and recreated around pg_upgrade. A version that the old image does not ship comes back at the image default on a rollback.

**23. Logical replication slots are not carried from 15.** Drop them first (record names and plugins); Realtime recreates its own. A physical slot for your WAL archiving is lost too.

**24. Run pg_upgrade over every database that allows connections.** The `_supabase` database (Logflare and Supavisor metadata) is a separate database. A script that only handles `postgres` misses it.

**25. Fast shutdown.** Postgres treats SIGTERM as a "smart" shutdown that waits for every client session to end. Check the container's `StopSignal`; if it is not SIGINT, use `docker kill -s INT` and then `docker wait` with a timeout.

**26. A collation refresh hides a needed reindex.** If the C library version changes between images, indexes on text columns may be ordered differently. Reindex first, then `ALTER DATABASE ... REFRESH COLLATION VERSION`. A refresh alone clears the warning and keeps the bad indexes. (Both of the images we used had the same glibc, so we did not need to reindex.)

**27. A rollback after the go decision loses data.** Copy mode keeps the 15 data exactly as it was at the stop. Rolling back after apps have written to 17 discards those writes, so our script refuses unless you pass `--discard-pg17-writes`. Set a deadline for the decision and fix forward after it.

## Rehearsals and tooling

**28. A clone is not production.** Our clone was restored from Coolify's dump of `postgres` only, so the `_supabase` database on the clone was several hundred times smaller than on production, where Logflare's log tables made it almost twice the size of the app database. The clone also had zero pg_cron jobs, because the dump carried none, while production had about a dozen. So the rehearsal never exercised disabling and re-enabling real jobs, and its timings undercounted the copy. Compare sizes and job counts between clone and production with `scripts/preflight.sql` before you trust clone timings.

**29. Restoring a faithful clone is harder than restoring a backup.** Restore as `supabase_admin`, give the container a larger `/dev/shm` (large index builds failed with the 64 MB default), mount the original `pgsodium` root key or Vault secrets never decrypt, and expect that the current image cannot install some older extension versions. Copy grants from production at the catalog level if your dump has none. A database you create for the clone should have the same owner as on production: one we created as `supabase_admin` with production's ACL copied onto it failed pg_upgrade's restore of the database ACL.

**30. Our recreate tool restored config files as 0600.** Its rollback restored bind-mounted files from 0600 backup copies with `cp -p`, so the live `kong.yml` became readable by root only. Kong runs as user `kong` and went into a restart loop. On production that rollback would have taken the gateway down instead of saving it. We found it on the clone, fixed the tool to record and restore each file's mode and owner, and added a check that each bind file is readable as the container user. `scripts/safe-recreate.sh` has the same check.

**31. Read a job's history before blaming the window.** One job was mid-stage when the database went down. It carried on by itself about 30 seconds after the workers came back, because our queue consumers acknowledge a message only when the work is done, so a paused job is simply delivered again. A different job had failed a few minutes before the window for an unrelated reason (an upstream download error), and at first we counted it as window damage; its event history showed otherwise.

**32. Point-in-time recovery has to move with the major version.** A major upgrade ends the old WAL history: base backups and WAL from 15 do not restore onto 17, and the client tools in your backup images must match the new server major. Plan a new base backup right after the upgrade and update the backup images.
