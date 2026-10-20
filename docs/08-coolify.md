# 8. Supabase on Coolify

> **Basis.** Verified by us on Coolify 4.4.6 (and earlier 4.x) with a long-running Supabase service, 2026-08 to 2026-10-20. Template and code facts were read from [coollabsio/coolify](https://github.com/coollabsio/coolify) on 2026-10-20. Several behaviours are also documented in [Vadko's migration guide](https://gist.github.com/Vadko/57d1dbc309f5b7440036f6606027643f), which is the best starting point for moving an existing Coolify service to the newer stack.

## Where the template stands (2026-10-20)

- Coolify's one-click Supabase template on `main` still ships Postgres 15 (`15.8.1.085`) and Kong 3.9.1.
- One update PR was closed unmerged ([coolify#11862](https://github.com/coollabsio/coolify/pull/11862)). A newer one that moves to Envoy, RustFS and Postgres 17 is open ([coolify#12004](https://github.com/coollabsio/coolify/pull/12004)).
- **Coolify never re-applies a template to an existing service.** Template fixes reach new services only. Everything below applies to the service you already have.

## The gotchas, in one place

**1. A host-side recreate drops the `coolify` network.** Coolify attaches containers to its shared `coolify` network (alias `<service>-<service-uuid>`) as a separate step of its own deploys; the network is not in the compose file on disk. `docker compose up -d --force-recreate <service>` on the host gives you a container without it. Anything that reaches the service over `coolify` breaks, while public checks stay green. Record networks and aliases before, reconnect after, probe the internal path. `scripts/safe-recreate.sh` does all three. (Discussed upstream in [coolify#11371](https://github.com/coollabsio/coolify/issues/11371).)

**2. The host compose file is the truth.** The compose Coolify returns from its API differed from `/data/coolify/services/<service-uuid>/docker-compose.yml` for every service on our stack. The host file is what runs; take snapshots from it.

**3. Record every change in Coolify's stored compose.** Otherwise the next Save or Deploy reverts it. We used the API: `PATCH /api/v1/services/<service-uuid>` with `docker_compose_raw` (base64) and `instant_deploy: false`, so the PATCH does not deploy. Keep the previous raw compose for rollback, and check `connect_to_docker_network` afterwards.

**4. Redeploy recreates every container. The Stop button removes them** (`docker rm -f`) and queues a cleanup. For maintenance, use `docker stop` and one-container recreates.

**5. "Load from server" has no API.** Files managed as file storages (`content:` mounts such as `vector.yml` or gateway config) are stored in Coolify's database. After editing one on the host, press "Load from server" for that row, or the next Save writes the stored copy back. Compare checksums afterwards.

**6. "Delete unused volumes" deletes your rollback.** The server's Docker cleanup can run `docker volume prune -af`. A volume no container uses (the old Postgres data after an upgrade, or a service stopped with the Stop button) is exactly what it deletes. Check the setting on every server, and keep it off while you keep a rollback volume.

**7. The scheduled cleanup prunes images**, including images you pre-pulled for a window and the old images a rollback needs. Keep windows clear of it and `docker save` the rollback images.

**8. Magic variables get values only on a Save.** `SERVICE_PASSWORD_*` and similar are generated when Coolify parses the compose. A variable added only on the host stays empty. A variable whose name does not start with `SERVICE_` is never generated: the older template's `SECRET_PASSWORD_REALTIME` stayed empty for that reason, leaving Realtime without a `SECRET_KEY_BASE` ([coolify#11999](https://github.com/coollabsio/coolify/issues/11999), fixed for new services). Check with `scripts/check-secret-lengths.sh`.

**9. The rendered `.env` has no trailing newline.** A bare `>>` append glues two variables together. Start every append with a newline.

**10. The whole `.env` reaches every container.** Delete secrets of removed services from Coolify's environment rows.

**11. Scheduled database backups have no grants.** For one database Coolify runs `pg_dump --format=custom --no-acl --no-owner`, and it covers only the database you pick. Take your own faithful dumps ([Backups](02-backups-and-restore.md)).

**12. Check the backup files.** In 2026-08 we found that, on our schema, `pg_dump` in `15.8.1.048` and `15.8.1.085` images segfaulted and the scheduled backup had written an empty file ([Backups](02-backups-and-restore.md)). The current template still uses a `15.8.1` image.

**13. Realtime's container name matters.** Realtime derives the tenant from it; keep `realtime-dev.supabase-realtime` (an older Coolify bug overrode it: [coolify issue 2060](https://github.com/coollabsio/coolify/issues/2060)).

## A safe change on a Coolify Supabase service

1. Snapshot the host compose, `.env` and every bind file.
2. Edit the host compose; run `docker compose config -q`.
3. Make the same edit in Coolify's stored compose (PATCH, `instant_deploy: false`), press "Load from server" for any changed file storage.
4. Recreate the one container: `bash scripts/safe-recreate.sh --uuid <service-uuid> --service <name> --expect-image <image> --probe-url <internal health URL> --apply`.
5. Verify: networks match the record, the internal probe is green, the service's own check passes.

## Upgrading the database on Coolify

Coolify keeps Postgres data in named volumes (`<service-uuid>_supabase-db-data`, `<service-uuid>_supabase-db-config`), which the stock upgrade script does not expect. `scripts/pg17-upgrade.sh` handles that layout ([Postgres 15 to 17](upgrades/05-postgres-15-to-17.md)); Vadko's gist has another script for the same job.
