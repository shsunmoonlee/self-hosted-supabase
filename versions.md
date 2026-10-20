# Tested versions

One row per service. "Tested" means it ran on a production self-hosted Supabase stack on Coolify after the migration on 2026-10-19, and the whole sequence was rehearsed the same day on a clone. Digests are the multi-arch index digests we pulled. Check them yourself with `docker buildx imagetools inspect <image>:<tag>` before you use them.

Coolify: 4.4.6. Host: amd64 Linux.

| Service (compose key) | Before | After (tested 2026-10-19) | Notes |
|---|---|---|---|
| supabase-db | `supabase/postgres:15.14.1.163` | `supabase/postgres:17.6.1.163@sha256:f11fe685b7a65673740ed4beda14a1c2e3722d038a7df5f0df086e73ac230afb` | pg_upgrade in copy mode; `pgjwt` and `wrappers` dropped ([Postgres 15 to 17](docs/upgrades/05-postgres-15-to-17.md)) |
| supabase-kong (gateway) | `kong:2.8.1` | `envoyproxy/envoy:v1.39.1@sha256:57e14a549d7bd43c8d3f6d03e8cfa653e037d4b38e133acd9b54f38c524401b4` | compose key and container name kept; config from upstream `self-hosted/v0.8.3` ([Kong to Envoy](docs/upgrades/03-kong-to-envoy.md)) |
| supabase-rest | `postgrest/postgrest:v12.2.12` | `postgrest/postgrest:v14.18@sha256:c7cd7e265a85b05248abf53f4473fcec7e327c282d0bd0cf60f1551996d09fcf` | `PGRST_ADMIN_SERVER_PORT=3001`, `PGRST_ADMIN_SERVER_HOST=localhost`, health check `postgrest --ready` |
| realtime-dev | `supabase/realtime:v2.34.47` | `supabase/realtime:v2.143.3@sha256:768b559241dd234c4e8852c5c0f504e598b80f1df2ad4dd78d5486fbed2f17a2` | via the four hops below; `_realtime` migrations 21 to 33 |
| supabase-meta | `supabase/postgres-meta:v0.89.3` | `supabase/postgres-meta:v0.100.0@sha256:145325b7e39f8ef4931d6e8cfd3f6f4d655de09d72a2ccc96d9513542c2202bd` | `CRYPTO_KEY` set, `PG_META_DB_USER=postgres` |
| supabase-studio | `supabase/studio:2026.01.07-sha-037e5f9` | `supabase/studio:2026.10.12-sha-3699278@sha256:948770ec467f00e6ae34c35018ef7cb23d7b30eb806b42c2cc0d7bcfdcf8a7a8` | Logs pages off (`ENABLED_FEATURES_LOGS_ALL=false`) |
| supabase-vector | `timberio/vector:0.28.1-alpine` | `timberio/vector:0.45.0-alpine@sha256:936e7e05f54b817f5957acbc72ad32a9b7016f7071c03937ee5cbd199e204c02` | S3-compatible sink only; see gotcha 18 before going past 0.45 |
| supabase-auth | `supabase/gotrue:v2.197.0` | unchanged | |

Realtime intermediate hops (each ran on the clone and on production):

| Hop | Image |
|---|---|
| 1 | `supabase/realtime:v2.51.11@sha256:d16d126c1cd0d827c9f78d00286883727029aaedeafa73bb0c3183ed0a9a7a50` |
| 2 | `supabase/realtime:v2.76.5@sha256:ec6607368a2b41f54fb6edffbb821984522d0ba47399937aeeba75673c36a6f8` |
| 3 | `supabase/realtime:v2.102.3@sha256:aa1c92c0cf326007563641730ec9da9c60478caa6853887775365fa2c097a471` |
| 4 | `supabase/realtime:v2.143.3@sha256:768b559241dd234c4e8852c5c0f504e598b80f1df2ad4dd78d5486fbed2f17a2` |

Removed on 2026-10-19 (not upgraded): Storage, imgproxy, MinIO and its bucket-creation job, Logflare (`supabase/logflare:1.4.0`), Supavisor.

Helper image used by our checks: `curlimages/curl:8.11.1@sha256:c1fe1679c34d9784c1b0d1e5f62ac0a79fca01fb6377cdd33e90473c6f9f9a69`.

## Adding a row

Add a new dated column or a new table below this one; do not edit a tested row. Say what "tested" means for your row (production, clone, local only), and link the CHANGELOG entry.
