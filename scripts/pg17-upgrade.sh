#!/usr/bin/env bash
#
# In-place Postgres 15 -> 17 upgrade of the Coolify-managed self-hosted Supabase db
# (supabase/postgres:15.14.1.163 -> supabase/postgres:17.6.1.163) on Docker NAMED volumes:
#   <UUID>_supabase-db-data     PGDATA
#   <UUID>_supabase-db-config   /etc/postgresql-custom (pgsodium_root.key, conf.d/)
#
# Derived from upstream supabase/supabase docker/utils/upgrade-pg17.sh (tag self-hosted/v0.8.3) and
# supabase/postgres ansible/files/admin_api_scripts/pg_upgrade_scripts/{initiate,complete,common}.sh
# (tag 17.6.1.163). Docs: docs/upgrades/05-postgres-15-to-17.md in the self-hosted-supabase handbook.
#
# Provided as is, without warranty. Rehearse it on a clone of your own data before any real run.
#
# Why not run upstream's initiate.sh as is: the .163 images are Alpine + nix (no apt/dpkg/locale-gen, which
# initiate.sh calls), and its nix path fetches the binaries from S3. Instead the "pg_upgrade bin tarball" here
# is the nix closure of the 17 image's postgresql-and-plugins store path, minus the store paths the 15 image
# already has. Extracted into a 15 container it gives a native 17 bindir at the same /nix/store path, which is
# what initiate.sh's nix mode does (PG_UPGRADE_BIN_DIR=$STORE_PATH). The pg_upgrade command line, the extension
# disable list and the preload exclusions follow initiate.sh; complete.sh's execute_patches is run verbatim.
#
# Usage:
#   UUID=<service uuid> WORK_DIR=/root/pg17-upgrade-$UUID bash upgrade.sh prepare   [--yes]   service RUNNING
#   UUID=<service uuid> WORK_DIR=/root/pg17-upgrade-$UUID bash upgrade.sh upgrade   [--yes]   every service container STOPPED
#   UUID=<service uuid> WORK_DIR=/root/pg17-upgrade-$UUID bash upgrade.sh finish    [--yes]   re-run the idempotent PG17 post-steps
#                                                                                on an already-swapped PG17 volume (STOPPED)
#   UUID=<service uuid> WORK_DIR=/root/pg17-upgrade-$UUID bash upgrade.sh rollback  [--yes]   every service container STOPPED
#       rollback after a finished upgrade also needs --discard-pg17-writes (--yes never implies it)
#       finish after a finished upgrade (state upgrade-done) needs --force-finish (--yes never implies it)
#
# Env:
#   UUID           Coolify service uuid (required). Volumes and container names derive from it.
#   WORK_DIR       tarball cache, backups (db-config tarball, key copy 0600), records, logs. Default /root/pg17-upgrade-$UUID
#   SOURCE_IMAGE   default supabase/postgres:15.14.1.163
#   TARGET_IMAGE   default supabase/postgres:17.6.1.163
#   SCRIPTS_REF    supabase/postgres tag for complete.sh/common.sh, default the TARGET_IMAGE tag
#   DB_CONTAINER   default supabase-db-$UUID (read for the password; must not be running for upgrade/rollback)
#   SERVICE_DIR    default /data/coolify/services/$UUID (.env fallback for the password when the container is gone)
#   ANALYZE        now (default): vacuumdb --analyze-in-stages in the window; defer: print it as a post-window step
#   EXTRA_FREE_GB  free space required on top of the datadir size, default 6
#   PG17_UPGRADE_FAIL_AT  test hook only: abort right after the named failpoint (see failpoint calls)
#   PG17_UPGRADE_SKIP_REINDEX  1 = never reindex in the window, even with ANALYZE=now: a collation mismatch is
#                  then written to WORK_DIR/REQUIRED-post-window-reindex.txt (with the deferred refresh) instead
#   PG17_UPGRADE_FORCE_EXT_VERSION  test hook only: "ext=version" recorded as the dropped version of ext, to prove
#                  rollback survives a version the source image does not ship (e.g. pg_graphql 1.5.11)
#   PG17_UPGRADE_SKIP_PGSUPER  test hook only (never in a real window): 1 = skip the ALTER USER postgres WITH
#                  SUPERUSER of pre_steps, so an e2e mutation check can prove pg_upgrade then fails on older databases'
#                  event-trigger ownership. The rolsuper record is still written.
#
# The password is read from the db container env (or the service .env), exported as PGPASSWORD and handed to
# containers with `-e PGPASSWORD` (name only, never the value in argv). It is never printed.

case "${BASH:-}" in */bash) ;; *) echo "Run with bash." >&2; exit 1 ;; esac
set -euo pipefail

MODE=""
AUTO_YES=false
DISCARD_PG17_WRITES=false
FORCE_FINISH=false
for arg in "$@"; do
  case "$arg" in
    prepare|upgrade|finish|rollback) MODE=$arg ;;
    --yes|-y) AUTO_YES=true ;;
    --discard-pg17-writes) DISCARD_PG17_WRITES=true ;;
    --force-finish) FORCE_FINISH=true ;;
    -h|--help) sed -n '2,40p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $arg (expected prepare|upgrade|finish|rollback [--yes] [--discard-pg17-writes] [--force-finish])" >&2; exit 2 ;;
  esac
done
[ -n "$MODE" ] || { echo "Usage: UUID=... WORK_DIR=... bash $0 prepare|upgrade|finish|rollback [--yes]" >&2; exit 2; }

UUID=${UUID:?UUID is required}
WORK_DIR=${WORK_DIR:-/root/pg17-upgrade-$UUID}
SOURCE_IMAGE=${SOURCE_IMAGE:-supabase/postgres:15.14.1.163}
TARGET_IMAGE=${TARGET_IMAGE:-supabase/postgres:17.6.1.163}
SCRIPTS_REF=${SCRIPTS_REF:-${TARGET_IMAGE##*:}}
DB_CONTAINER=${DB_CONTAINER:-supabase-db-$UUID}
SERVICE_DIR=${SERVICE_DIR:-/data/coolify/services/$UUID}
ANALYZE=${ANALYZE:-now}
EXTRA_FREE_GB=${EXTRA_FREE_GB:-6}
FAIL_AT=${PG17_UPGRADE_FAIL_AT:-}
FORCE_EXT_VERSION=${PG17_UPGRADE_FORCE_EXT_VERSION:-}

DATA_VOL="${UUID}_supabase-db-data"
CONFIG_VOL="${UUID}_supabase-db-config"
SIDE_VOL="${DATA_VOL}-pg15"
MIG_VOL="${UUID}_supabase-db-data-pg17-new"

H_UPG="pg17-upgrade-${UUID}"
H_FIN="pg17-finish-${UUID}"
H_RB="pg15-rollback-${UUID}"
H_INV="pg17-inventory-${UUID}"

SRC_TAG=${SOURCE_IMAGE##*:}
TGT_TAG=${TARGET_IMAGE##*:}
TARBALL="$WORK_DIR/pg17-closure_${TGT_TAG}_minus_${SRC_TAG}.tar.gz"
STOREPATH_FILE="$TARBALL.storepath"
PATHS_FILE="$TARBALL.paths"
SCRIPTS_DIR="$WORK_DIR/scripts-$SCRIPTS_REF"
REC_DROPPED="$WORK_DIR/dropped-extensions.tsv"
REC_CRON="$WORK_DIR/cron-active.ids"
REC_SLOTS="$WORK_DIR/replication-slots.tsv"
REC_PRE="$WORK_DIR/pre-counts.txt"
REC_CRON_JOBS="$WORK_DIR/cron-jobs.pre.tsv"
REC_PGSUPER="$WORK_DIR/postgres-rolsuper.pre"
REINDEX_TODO="$WORK_DIR/REQUIRED-post-window-reindex.txt"
CONFIG_TGZ="$WORK_DIR/db-config.pg15.tgz"
KEY_COPY="$WORK_DIR/pgsodium_root.key.pg15"
STATE_FILE="$WORK_DIR/state"

# Extensions initiate.sh drops before pg_upgrade and complete.sh recreates (initiate.sh EXTENSIONS_TO_DISABLE).
INITIATE_DISABLE="pg_graphql pg_stat_monitor pg_backtrace"
# Not in Postgres 17 images at all (upgrade-pg17.sh preflight). Never dropped automatically here: abort.
INCOMPATIBLE="timescaledb plv8 plcoffee plls"

# Upstream's PG17 post-migrations, the exact list of upgrade-pg17.sh apply_role_migrations (self-hosted/v0.8.3).
# 20260421000000_pg_graphql-off-by-default.sql is deliberately NOT applied (it drops pg_graphql), as upstream.
POST_MIGRATIONS="
20250710151649_supabase_read_only_user_default_transaction_read_only.sql
20251001204436_predefined_role_grants.sql
20251105172723_grant_pg_reload_conf_to_postgres.sql
20251121132723_correct_search_path_pgbouncer.sql
20260211120934_supabase_privileged_role.sql
20260413000000_fix-authenticator-session-preload-libraries.sql
20260421000001_rescope_pg_graphql_access_trigger.sql
"

# --- logging -------------------------------------------------------------------

T_START=$SECONDS
STEP_NAME=""
STEP_T=0
STEP_TIMES=()
ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }
log() { printf '%s %s\n' "$(ts)" "$*"; }
warn() { printf '%s WARNING: %s\n' "$(ts)" "$*"; }
end_step() {
  if [ -n "$STEP_NAME" ]; then
    local d=$((SECONDS - STEP_T))
    log "    done: $STEP_NAME (${d}s)"
    STEP_TIMES+=("$(printf '%-34s %5ss' "$STEP_NAME" "$d")")
    STEP_NAME=""
  fi
}
step() { end_step; STEP_NAME=$1; STEP_T=$SECONDS; log "==> STEP $1"; }
FAILED_STEP=""
die() { FAILED_STEP=${STEP_NAME:-startup}; log "ERROR: $*"; exit 1; }
failpoint() { if [ "$FAIL_AT" = "$1" ]; then die "failpoint '$1' reached (PG17_UPGRADE_FAIL_AT test hook)"; fi; }
summary() {
  end_step
  log "Step durations:"
  local l
  for l in "${STEP_TIMES[@]}"; do log "    $l"; done
  log "Total: $((SECONDS - T_START))s ($(( (SECONDS - T_START) / 60 ))m $(( (SECONDS - T_START) % 60 ))s)"
}

confirm() {
  [ "$AUTO_YES" = true ] && return 0
  test -t 0 || die "Not a terminal: pass --yes to run non-interactively."
  printf '%s (y/N) ' "$1"
  local reply
  read -r reply
  case "$reply" in [Yy]*) return 0 ;; *) log "Aborted by operator."; exit 0 ;; esac
}

# --- docker helpers ------------------------------------------------------------

vol_exists() { docker volume inspect "$1" >/dev/null 2>&1; }
container_exists() { docker inspect "$1" >/dev/null 2>&1; }
container_running() { [ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null || echo false)" = true ]; }

VOL_ROOT=""
volume_root() {
  local mp
  mp=$(docker volume inspect -f '{{.Mountpoint}}' "$DATA_VOL")
  VOL_ROOT=$(dirname "$(dirname "$mp")")
  [ "$(docker volume inspect -f '{{.Driver}}' "$DATA_VOL")" = local ] || die "$DATA_VOL is not a local-driver volume."
}

# Runs a root shell (SOURCE image, no network) with the docker volumes root at /dv. Moves between volumes are
# renames on the same filesystem; works on a Linux host and on Docker Desktop alike.
volsh() {
  local script=$1; shift
  docker run --rm --network none --user root --entrypoint sh -v "$VOL_ROOT:/dv" "$@" "$SOURCE_IMAGE" -c "$script"
}

# PG_VERSION of a volume's _data: prints 15, 17, "empty", "missing" or "other".
vol_pgversion() {
  volsh 'd=/dv/$V/_data
    if [ ! -d "$d" ]; then echo missing
    elif [ -f "$d/PG_VERSION" ]; then cat "$d/PG_VERSION"
    elif [ -z "$(ls -A "$d")" ]; then echo empty
    else echo other; fi' -e V="$1"
}

project_running() {
  {
    docker ps --filter "label=com.docker.compose.project=$UUID" --format '{{.Names}}'
    docker ps --filter "name=^${DB_CONTAINER}\$" --format '{{.Names}}'
  } | sort -u | sed '/^$/d'
}

require_stopped() {
  local running
  running=$(project_running)
  [ -z "$running" ] || die "Every container of compose project $UUID must be stopped. Still running: $(echo "$running" | tr '\n' ' ')"
  local h
  for h in "$H_UPG" "$H_FIN" "$H_RB"; do
    if container_running "$h"; then die "Helper container $h is running (another run in progress?)."; fi
  done
}

load_password() {
  local pw=""
  if container_exists "$DB_CONTAINER"; then
    pw=$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$DB_CONTAINER" | sed -n 's/^POSTGRES_PASSWORD=//p' | head -n 1)
  fi
  if [ -z "$pw" ] && [ -f "$SERVICE_DIR/.env" ]; then
    pw=$(sed -n 's/^SERVICE_PASSWORD_POSTGRES=//p' "$SERVICE_DIR/.env" | head -n 1 | sed "s/^['\"]//; s/['\"]\$//")
  fi
  [ -n "$pw" ] || die "No POSTGRES_PASSWORD on $DB_CONTAINER and no SERVICE_PASSWORD_POSTGRES in $SERVICE_DIR/.env."
  export PGPASSWORD="$pw"
  export POSTGRES_PASSWORD="$pw"
}

# psql as supabase_admin over localhost TCP inside container $1, database $2. Extra args follow.
psql_in() {
  local c=$1 db=$2; shift 2
  docker exec -e PGPASSWORD "$c" psql -X -q -h localhost -U supabase_admin -d "$db" -v ON_ERROR_STOP=1 "$@"
}
sqlv() { psql_in "$1" "$2" -At -c "$3"; }

wait_ready() {
  local c=$1 tries=${2:-120} ok=0
  while [ "$tries" -gt 0 ]; do
    if docker exec "$c" pg_isready -h localhost -U postgres >/dev/null 2>&1 \
       && psql_in "$c" postgres -At -c 'select 1' >/dev/null 2>&1; then
      ok=$((ok + 1))
      [ "$ok" -ge 2 ] && return 0
    else
      ok=0
    fi
    container_running "$c" || { docker logs --tail 40 "$c" 2>&1 | sed 's/^/    | /'; die "$c exited before Postgres was ready."; }
    tries=$((tries - 1))
    sleep 2
  done
  docker logs --tail 40 "$c" 2>&1 | sed 's/^/    | /'
  die "Postgres in $c did not become ready."
}

# Stops Postgres inside a helper container cleanly, then removes the container.
stop_helper() {
  local c=$1
  container_exists "$c" || return 0
  if container_running "$c"; then
    case "$c" in
      "$H_UPG")
        docker exec -u postgres "$c" /usr/lib/postgresql/bin/pg_ctl stop -D /var/lib/postgresql/data -m fast -w -t 120 >/dev/null 2>&1 || true ;;
      *)
        docker stop -t 120 "$c" >/dev/null 2>&1 || true ;;
    esac
  fi
  docker rm -f "$c" >/dev/null 2>&1 || true
}

LOCK_HELD=false
on_exit() {
  local rc=$?
  set +e
  stop_helper "$H_INV"
  stop_helper "$H_UPG"
  stop_helper "$H_FIN"
  stop_helper "$H_RB"
  if [ "$MODE" = prepare ] && [ -n "${CHECK_CONTAINER:-}" ]; then live_check_cleanup; fi
  if [ "$rc" -ne 0 ]; then
    log "FAILED (exit $rc) in step: ${FAILED_STEP:-${STEP_NAME:-unknown}}"
    if [ "$MODE" = upgrade ] || [ "$MODE" = finish ]; then
      if grep -q ' swapped$' "$STATE_FILE" 2>/dev/null && ! grep -q ' upgrade-done$' "$STATE_FILE" 2>/dev/null; then
        log "The swap happened: $DATA_VOL is PG17, the PG15 copy is in $SIDE_VOL."
        log "First path, fix the cause and resume the PG17 post-steps: UUID=$UUID WORK_DIR=$WORK_DIR bash $0 finish"
        log "Second path, back to PG15:                             UUID=$UUID WORK_DIR=$WORK_DIR bash $0 rollback"
      else
        log "PG15 data: side volume $SIDE_VOL if the swap happened, otherwise still in $DATA_VOL."
        log "Return to PG15 with: UUID=$UUID WORK_DIR=$WORK_DIR bash $0 rollback"
      fi
    fi
  fi
  [ "$LOCK_HELD" = true ] && rmdir "$WORK_DIR/.lock" 2>/dev/null
  exit "$rc"
}
trap on_exit EXIT
trap 'die "interrupted"' INT TERM

setup_workdir() {
  mkdir -p "$WORK_DIR"
  chmod 700 "$WORK_DIR"
  mkdir "$WORK_DIR/.lock" 2>/dev/null || { echo "Another run holds $WORK_DIR/.lock (remove it if stale)." >&2; exit 1; }
  LOCK_HELD=true
  LOG_FILE="$WORK_DIR/${MODE}-$(date -u +%Y%m%dT%H%M%SZ).log"
  exec > >(tee -a "$LOG_FILE") 2>&1
  log "upgrade.sh $MODE: uuid=$UUID source=$SOURCE_IMAGE target=$TARGET_IMAGE work_dir=$WORK_DIR log=$LOG_FILE"
}

set_state() { printf '%s %s\n' "$(ts)" "$1" >>"$STATE_FILE"; }

dbs_in() { sqlv "$1" postgres "select datname from pg_database where datallowconn order by datname"; }

# --- inner script: pg_upgrade the way initiate.sh runs it -------------------------------------------------
# Runs as postgres inside a container that has the 17 closure extracted. MODE: live-check | check | run.
inner_pg_upgrade() {
  cat <<'EOS'
set -euo pipefail
: "${STORE:?}" "${XDIR:?}" "${NEWDATA:?}" "${OLDDATA:?}" "${SPL:?}" "${UPMODE:?}"
NEWBIN="$STORE/bin"
NEWSHARE="$STORE/share/postgresql"
OLDBIN="$(pg_config --bindir)"
CONF=/etc/postgresql/postgresql.conf
mkdir -p "$XDIR/run"
# initiate.sh L538-550: a copy of the old config, max_slot_wal_keep_size=-1, no db_user_namespace (15 -> 16+).
# Ours adds a trust-only hba for the pg_upgrade-started servers (unix socket in $XDIR/run, nothing else) and
# archive_mode=off, appended last so they win over conf.d (a WAL-archiving conf.d file may set hba_file).
cp "$CONF" "$XDIR/postgresql.conf"
sed -i '/^db_user_namespace/d' "$XDIR/postgresql.conf"
printf 'local all all trust\n' >"$XDIR/pg_hba.conf"
{
  echo "max_slot_wal_keep_size = -1"
  echo "archive_mode = off"
  echo "hba_file = '$XDIR/pg_hba.conf'"
} >>"$XDIR/postgresql.conf"
CHECKSUM_FLAG=""
[ "${CHECKSUMS:-off}" = on ] && CHECKSUM_FLAG="--data-checksums"
LOCALE_ARGS=(--encoding="$ENCODING" --lc-collate="$LC_COLLATE_V" --lc-ctype="$LC_CTYPE_V")
if [ "$LOC_PROVIDER" = i ]; then LOCALE_ARGS+=(--locale-provider=icu --icu-locale="$ICU_LOCALE_V"); else LOCALE_ARGS+=(--locale-provider=libc); fi
rm -rf "$NEWDATA"
echo "initdb (17) -> $NEWDATA"
"$NEWBIN/initdb" --allow-group-access $CHECKSUM_FLAG "${LOCALE_ARGS[@]}" -L "$NEWSHARE" -D "$NEWDATA" --username=supabase_admin >"$XDIR/initdb.log" 2>&1 \
  || { cat "$XDIR/initdb.log"; exit 1; }
CHECK=""
[ "$UPMODE" != run ] && CHECK="--check"
cd "$XDIR/run"
# initiate.sh L552-566 UPGRADE_COMMAND, plus --copy made explicit (initiate.sh passes neither --link nor --clone).
set -x
GRN_PLUGINS_DIR=/var/lib/postgresql/.nix-profile/lib/groonga/plugins \
"$NEWBIN/pg_upgrade" \
  --old-bindir="$OLDBIN" \
  --new-bindir="$NEWBIN" \
  --old-datadir="$OLDDATA" \
  --new-datadir="$NEWDATA" \
  --username=supabase_admin \
  --jobs="${JOBS:-1}" -r --copy \
  --old-options="-c config_file=$XDIR/postgresql.conf" \
  --old-options="-c shared_preload_libraries='$SPL'" \
  --new-options="-c data_directory=$NEWDATA" \
  --new-options="-c config_file=$XDIR/postgresql.conf" \
  --new-options="-c shared_preload_libraries='$SPL'" \
  $CHECK
EOS
}

# Reads the settings pg_upgrade needs from a running PG15 in container $1 into the CTX_* variables.
CTX_SPL="" CTX_OLDDATA="" CTX_CHECKSUMS="" CTX_ENC="" CTX_PROV="" CTX_COLL="" CTX_CTYPE="" CTX_ICU="" CTX_BOOT=""
read_cluster_context() {
  local c=$1 spl
  spl=$(sqlv "$c" postgres "show shared_preload_libraries")
  # initiate.sh L229-249: drop timescaledb (17), pg_cron, pg_net, check_role_membership, safeupdate, pg_backtrace.
  CTX_SPL=$(printf '%s' "$spl" | tr ',' '\n' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//' \
    | sed '/^$/d' | { grep -vxE 'timescaledb|pg_cron|pg_net|check_role_membership|safeupdate|pg_backtrace' || true; } | paste -sd, -)
  CTX_OLDDATA=$(sqlv "$c" postgres "show data_directory")
  CTX_CHECKSUMS=$(sqlv "$c" postgres "show data_checksums")
  CTX_ENC=$(sqlv "$c" postgres "select pg_encoding_to_char(encoding) from pg_database where datname='template0'")
  CTX_PROV=$(sqlv "$c" postgres "select datlocprovider from pg_database where datname='template0'")
  CTX_COLL=$(sqlv "$c" postgres "select datcollate from pg_database where datname='template0'")
  CTX_CTYPE=$(sqlv "$c" postgres "select datctype from pg_database where datname='template0'")
  CTX_ICU=$(sqlv "$c" postgres "select coalesce(daticulocale,'') from pg_database where datname='template0'")
  CTX_BOOT=$(sqlv "$c" postgres "select rolname from pg_authid where oid = 10")
  log "    cluster: data_directory=$CTX_OLDDATA checksums=$CTX_CHECKSUMS encoding=$CTX_ENC provider=$CTX_PROV collate=$CTX_COLL ctype=$CTX_CTYPE icu=${CTX_ICU:-none} bootstrap=$CTX_BOOT"
  log "    pg_upgrade shared_preload_libraries: $CTX_SPL"
  [ "$CTX_BOOT" = supabase_admin ] || die "Bootstrap superuser is $CTX_BOOT, not supabase_admin; initiate.sh's role swap is not implemented here."
}

# Runs inner_pg_upgrade in container $1 as postgres. $2 = live-check|check|run, $3 = XDIR, $4 = NEWDATA.
run_pg_upgrade() {
  local c=$1 upmode=$2 xdir=$3 newdata=$4 jobs
  jobs=$(docker exec "$c" nproc 2>/dev/null || echo 2)
  jobs=$(( jobs > 1 ? jobs - 1 : 1 ))
  docker exec -u root "$c" sh -c "mkdir -p '$xdir' && chown -R postgres:postgres '$xdir'"
  inner_pg_upgrade | docker exec -i -u postgres -w "$xdir" -e PGPASSWORD \
    -e STORE="$(cat "$STOREPATH_FILE")" -e XDIR="$xdir" -e NEWDATA="$newdata" -e OLDDATA="$CTX_OLDDATA" \
    -e SPL="$CTX_SPL" -e UPMODE="$upmode" -e CHECKSUMS="$CTX_CHECKSUMS" -e ENCODING="$CTX_ENC" \
    -e LOC_PROVIDER="$CTX_PROV" -e LC_COLLATE_V="$CTX_COLL" -e LC_CTYPE_V="$CTX_CTYPE" -e ICU_LOCALE_V="$CTX_ICU" \
    -e JOBS="$jobs" "$c" bash -s 2>&1 | sed 's/^/    | /'
}

# --- prepare -------------------------------------------------------------------------------------------

pull_images() {
  step "pull images"
  docker pull -q "$SOURCE_IMAGE" >/dev/null
  docker pull -q "$TARGET_IMAGE" >/dev/null
  local img
  for img in "$SOURCE_IMAGE" "$TARGET_IMAGE"; do
    log "    $img digest=$(docker image inspect -f '{{index .RepoDigests 0}}' "$img" 2>/dev/null | sed 's/.*@//') postgres_uid=$(docker run --rm --network none --entrypoint id "$img" -u postgres)"
  done
  {
    echo "source $SOURCE_IMAGE $(docker image inspect -f '{{index .RepoDigests 0}}' "$SOURCE_IMAGE" 2>/dev/null)"
    echo "target $TARGET_IMAGE $(docker image inspect -f '{{index .RepoDigests 0}}' "$TARGET_IMAGE" 2>/dev/null)"
  } >"$WORK_DIR/images.txt"
  # glibc decides collation order. The images are Alpine (musl) with a nix-built Postgres, so `getconf
  # GNU_LIBC_VERSION` reports the system libc (or nothing); the glibc Postgres links is the one in its nix closure.
  local g15 g17
  g15=$(glibc_of "$SOURCE_IMAGE")
  g17=$(glibc_of "$TARGET_IMAGE")
  log "    glibc $SOURCE_IMAGE: $g15"
  log "    glibc $TARGET_IMAGE: $g17"
  { echo "glibc source: $g15"; echo "glibc target: $g17"; } >>"$WORK_DIR/images.txt"
  if [ "${g15##*postgres: }" != "${g17##*postgres: }" ]; then
    warn "the Postgres glibc differs between the images: collation versions can change; upgrade reindexes before the refresh"
  fi
}

glibc_of() {
  docker run --rm --network none --user root --entrypoint bash "$1" -c '
    g=$(getconf GNU_LIBC_VERSION 2>/dev/null || echo "none (musl system libc)")
    P=$(dirname "$(dirname "$(readlink -f /usr/lib/postgresql/bin/postgres)")")
    n=$(nix-store -qR "$P" 2>/dev/null | grep -E -- "-glibc-[0-9][0-9.]*(-[0-9]+)?$" | sed "s|.*-glibc-|glibc |" | sort -u | paste -sd, -)
    echo "getconf: $g; postgres: ${n:-unknown}"' 2>/dev/null || echo "unknown"
}

download_scripts() {
  step "download upstream scripts (supabase/postgres@$SCRIPTS_REF)"
  mkdir -p "$SCRIPTS_DIR"
  local base="https://raw.githubusercontent.com/supabase/postgres/${SCRIPTS_REF}/ansible/files/admin_api_scripts/pg_upgrade_scripts" s
  for s in complete.sh common.sh initiate.sh; do
    if [ ! -s "$SCRIPTS_DIR/$s" ]; then
      curl -fsSL "$base/$s" -o "$SCRIPTS_DIR/$s.tmp" || die "Download of $s failed."
      mv "$SCRIPTS_DIR/$s.tmp" "$SCRIPTS_DIR/$s"
    fi
    log "    $s sha256=$(sha256sum "$SCRIPTS_DIR/$s" 2>/dev/null | cut -d' ' -f1 || shasum -a 256 "$SCRIPTS_DIR/$s" | cut -d' ' -f1)"
  done
}

build_tarball() {
  step "build pg_upgrade bin tarball (17 nix closure)"
  if [ -s "$TARBALL" ] && [ -s "$STOREPATH_FILE" ] && [ -s "$PATHS_FILE" ]; then
    log "    cached: $TARBALL ($(du -h "$TARBALL" | cut -f1)), store path $(cat "$STOREPATH_FILE")"
    return
  fi
  docker run --rm --network none --entrypoint sh "$SOURCE_IMAGE" -c 'ls -1d /nix/store/*' | sort >"$WORK_DIR/.source-store.txt"
  docker run --rm --network none --user root --entrypoint bash -v "$WORK_DIR:/work" -e TB="$(basename "$TARBALL")" "$TARGET_IMAGE" -c '
    set -euo pipefail
    P=$(dirname "$(dirname "$(readlink -f /usr/lib/postgresql/bin/postgres)")")
    case "$P" in /nix/store/*) ;; *) echo "unexpected store path: $P" >&2; exit 1 ;; esac
    nix-store -qR "$P" | sort >/tmp/closure
    comm -23 /tmp/closure /work/.source-store.txt >/tmp/missing
    echo "closure $(wc -l </tmp/closure) store paths, $(wc -l </tmp/missing) not in the source image"
    sed "s|^/||" /tmp/missing >/tmp/list
    tar -C / -czf "/work/$TB.tmp" -T /tmp/list
    cp /tmp/missing "/work/$TB.paths"
    echo "$P" >"/work/$TB.storepath"
    mv "/work/$TB.tmp" "/work/$TB"
  ' 2>&1 | sed 's/^/    | /'
  [ -s "$TARBALL" ] || die "Tarball build failed."
  log "    $TARBALL ($(du -h "$TARBALL" | cut -f1)), store path $(cat "$STOREPATH_FILE")"
}

GATES_FAILED=0
gate_fail() { warn "GATE FAILED: $*"; GATES_FAILED=$((GATES_FAILED + 1)); }

disk_gate() {
  # $1 = container whose datadir to measure (running PG15) or empty to measure the volume offline.
  step "disk gate (free >= datadir + ${EXTRA_FREE_GB} GB)"
  local out size_kb free_kb need_kb
  out=$(volsh 'du -sk "/dv/$V/_data" | cut -f1; df -Pk /dv | awk "NR==2 {print \$4}"' -e V="$DATA_VOL")
  size_kb=$(echo "$out" | sed -n 1p)
  free_kb=$(echo "$out" | sed -n 2p)
  need_kb=$(( size_kb + EXTRA_FREE_GB * 1024 * 1024 ))
  log "    datadir $((size_kb / 1024)) MB, free $((free_kb / 1024)) MB, need $((need_kb / 1024)) MB"
  if [ "$free_kb" -lt "$need_kb" ]; then
    gate_fail "not enough free disk: $((free_kb / 1024)) MB < $((need_kb / 1024)) MB"
    return 1
  fi
}

version_ge() { [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

extension_inventory() {
  step "extension inventory against $TARGET_IMAGE"
  local inv_pw db rows
  rows=""
  for db in $(dbs_in "$DB_CONTAINER"); do
    rows+=$(sqlv "$DB_CONTAINER" "$db" "select '$db', extname, extversion from pg_extension order by extname")$'\n'
  done
  inv_pw=$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')
  docker rm -f "$H_INV" >/dev/null 2>&1 || true
  PGPASSWORD="$inv_pw" POSTGRES_PASSWORD="$inv_pw" docker run -d --name "$H_INV" --network none \
    -e POSTGRES_PASSWORD -e PGPASSWORD "$TARGET_IMAGE" >/dev/null
  PGPASSWORD="$inv_pw" wait_ready "$H_INV" 150
  local avail
  avail=$(PGPASSWORD="$inv_pw" sqlv "$H_INV" postgres "select name || '|' || default_version from pg_available_extensions")
  local d e v def status bad=0
  printf '%s %-22s %-12s %-12s %s\n' "$(ts)" "    extension" "installed" "target" "result"
  while IFS='|' read -r d e v; do
    [ -n "$e" ] || continue
    def=$(printf '%s\n' "$avail" | sed -n "s/^${e}|//p" | head -n 1)
    status=""
    if [[ " $INCOMPATIBLE " == *" $e "* ]]; then
      status="FAIL: not supported on 17 (drop it first)"
    elif [ -z "$def" ]; then
      case "$e" in pgjwt|wrappers) status="ok: absent in target, dropped by upgrade (unused only)" ;; *) status="FAIL: no control file in target" ;; esac
    elif [ "$v" = "$def" ]; then
      status="ok: same version"
    else
      local has_path
      has_path=$(PGPASSWORD="$inv_pw" sqlv "$H_INV" postgres "select count(*) from pg_extension_update_paths('$e') where source = '$v' and target = '$def' and path is not null" 2>/dev/null || echo 0)
      if [ "$has_path" != 0 ]; then
        status="ok: update path $v -> $def"
      else
        case "$e" in
          pgaudit) status="ok: dropped before pg_upgrade, CREATE EXTENSION after ($def)" ;;
          pg_cron) status="ok: no path; relabelled to $def after (upgrade-pg17.sh)" ;;
          pg_graphql|pg_stat_monitor|pg_backtrace) status="ok: dropped by the initiate.sh list, recreated at $def" ;;
          pgjwt|wrappers) status="ok: dropped by upgrade (unused only)" ;;
          *) if version_ge "$def" "$v"; then status="ok: no path, keeps $v SQL on the $def library"; else status="FAIL: target $def is older than $v"; fi ;;
        esac
      fi
    fi
    [[ "$status" == FAIL* ]] && bad=$((bad + 1))
    printf '%s %-22s %-12s %-12s %s\n' "$(ts)" "    $d.$e" "$v" "${def:--}" "$status"
  done <<<"$(printf '%s' "$rows")"
  # Named checks.
  local x
  x=$(PGPASSWORD="$inv_pw" sqlv "$H_INV" postgres "select count(*) from pg_available_extension_versions where name='pgsodium' and version='3.1.8'")
  log "    named: pgsodium 3.1.8 in target: $([ "$x" = 1 ] && echo yes || echo NO)"; [ "$x" = 1 ] || bad=$((bad + 1))
  x=$(PGPASSWORD="$inv_pw" sqlv "$H_INV" postgres "select count(*) from pg_available_extension_versions where name='pg_net' and version='0.20.4'")
  log "    named: pg_net 0.20.4 in target: $([ "$x" = 1 ] && echo yes || echo NO)"; [ "$x" = 1 ] || bad=$((bad + 1))
  x=$(PGPASSWORD="$inv_pw" sqlv "$H_INV" postgres "select coalesce(string_agg(version, ',' order by version), 'none') from pg_available_extension_versions where name='pgaudit'")
  log "    named: pgaudit versions in target: $x (15 line has no ALTER path; dropped before, created after)"
  x=$(sqlv "$DB_CONTAINER" postgres "select coalesce(string_agg(distinct split_part(c, '=', 1), ','), 'none') from pg_db_role_setting, unnest(setconfig) c where c like 'pgaudit.%'")
  log "    pgaudit.* settings in pg_db_role_setting (names only): $x"
  echo "$x" >"$WORK_DIR/pgaudit-settings.txt"
  stop_helper "$H_INV"
  [ "$bad" -eq 0 ] || gate_fail "$bad extension inventory problem(s)"
}

key_gate() {
  step "pgsodium key readable by the target image"
  local len
  len=$(docker run --rm --network none --user root --entrypoint bash -v "$CONFIG_VOL:/etc/postgresql-custom:ro" "$TARGET_IMAGE" \
    -c 'k=$(/usr/lib/postgresql/bin/pgsodium_getkey.sh 2>/dev/null) || exit 0; printf %s "${#k}"' || true)
  log "    pgsodium_getkey.sh output length with our key: ${len:-error} (expect 64 hex chars)"
  [ "$len" = 64 ] || gate_fail "pgsodium key script did not return a 64-char key"
}

CHECK_CONTAINER=""
live_check_cleanup() {
  local c=$CHECK_CONTAINER
  CHECK_CONTAINER=""
  [ -n "$c" ] && container_running "$c" || return 0
  docker exec -i -u root "$c" sh -c 'while read -r p; do case "$p" in /nix/store/?*) chmod -R u+w "$p" 2>/dev/null; rm -rf "$p" ;; esac; done; rm -rf /tmp/pg17check' <"$PATHS_FILE" || true
  log "    removed the extracted 17 closure and the scratch cluster from $c"
}

live_check() {
  step "pg_upgrade --check (live, inside the running PG15 container)"
  local pre
  pre=$(docker exec -i "$DB_CONTAINER" sh -c 'n=0; while read -r p; do [ -e "$p" ] && n=$((n+1)); done; echo $n' <"$PATHS_FILE")
  [ "$pre" = 0 ] || warn "$pre closure paths already present in $DB_CONTAINER (left from an earlier prepare); they are removed afterwards"
  CHECK_CONTAINER=$DB_CONTAINER
  docker exec -i -u root "$DB_CONTAINER" tar -C / -xzf - <"$TARBALL"
  read_cluster_context "$DB_CONTAINER"
  local rc=0
  run_pg_upgrade "$DB_CONTAINER" live-check /tmp/pg17check /tmp/pg17check/newdata || rc=$?
  live_check_cleanup
  [ "$rc" -eq 0 ] || gate_fail "pg_upgrade --check failed (output above)"
  [ "$rc" -eq 0 ] && log "    pg_upgrade --check: Clusters are compatible"
  return 0
}

# The extensions upgrade drops and a rollback recreates on PG15 (initiate.sh list + pgaudit) must be creatable in
# the SOURCE image. The running db is the source image, so its pg_available_extension_versions is the answer.
# Absent entirely = rollback cannot restore it = gate failure. Installed version not shipped (e.g. pg_graphql
# 1.5.11 in 15.14.1.163) = rollback brings it back at the image default: logged, not a failure.
rollback_recreate_gate() {
  step "rollback can recreate the dropped extensions on PG15"
  local db e v ok def
  for db in $(dbs_in "$DB_CONTAINER"); do
    for e in $INITIATE_DISABLE pgaudit; do
      v=$(sqlv "$DB_CONTAINER" "$db" "select extversion from pg_extension where extname='$e'")
      [ -n "$v" ] || continue
      ok=$(sqlv "$DB_CONTAINER" "$db" "select count(*) from pg_available_extension_versions where name='$e' and version='$v'")
      def=$(sqlv "$DB_CONTAINER" "$db" "select coalesce((select default_version from pg_available_extensions where name='$e'), '')")
      if [ "$ok" != 0 ]; then
        log "    $db.$e $v: shipped in $SOURCE_IMAGE, rollback restores $v"
      elif [ -n "$def" ]; then
        warn "$db.$e $v is not shipped in $SOURCE_IMAGE: a rollback would bring it back at the default $def"
      else
        gate_fail "$db.$e is not available in $SOURCE_IMAGE at all: a rollback could not recreate it"
      fi
    done
  done
  return 0
}

do_prepare() {
  setup_workdir
  step "preflight (prepare)"
  container_running "$DB_CONTAINER" || die "$DB_CONTAINER is not running; prepare needs the PG15 service up."
  docker ps --filter "label=com.docker.compose.project=$UUID" --format '{{.Names}}' | grep -qx "$DB_CONTAINER" \
    || die "$DB_CONTAINER is not a container of compose project $UUID (label com.docker.compose.project). Wrong UUID or DB_CONTAINER?"
  local img
  img=$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER")
  [ "$img" = "$SOURCE_IMAGE" ] || [[ "$img" == "$SOURCE_IMAGE@"* ]] || die "$DB_CONTAINER runs $img, expected $SOURCE_IMAGE."
  vol_exists "$DATA_VOL" || die "Volume $DATA_VOL not found."
  vol_exists "$CONFIG_VOL" || die "Volume $CONFIG_VOL not found."
  vol_exists "$SIDE_VOL" && warn "$SIDE_VOL exists (an earlier upgrade's PG15 copy). upgrade refuses until it is resolved."
  load_password
  volume_root
  pull_images
  download_scripts
  build_tarball
  disk_gate || true
  extension_inventory
  rollback_recreate_gate
  key_gate
  live_check
  end_step
  if [ "$GATES_FAILED" -gt 0 ]; then
    summary
    die "prepare: $GATES_FAILED gate(s) failed. NO-GO."
  fi
  log "prepare: all gates passed (live pg_upgrade --check, extension inventory, pgsodium key, disk)."
  summary
}

# --- upgrade --------------------------------------------------------------------------------------------

backup_config() {
  step "back up db-config (tarball + key copy, 0600)"
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  [ -f "$CONFIG_TGZ" ] && mv "$CONFIG_TGZ" "$CONFIG_TGZ.prev-$stamp"
  [ -f "$KEY_COPY" ] && mv "$KEY_COPY" "$KEY_COPY.prev-$stamp"
  docker run --rm --network none --user root --entrypoint sh -v "$CONFIG_VOL:/src:ro" -v "$WORK_DIR:/dst" "$SOURCE_IMAGE" -c '
    set -e
    umask 077
    tar -czf /dst/db-config.pg15.tgz -C /src .
    cp /src/pgsodium_root.key /dst/pgsodium_root.key.pg15
    chmod 600 /dst/db-config.pg15.tgz /dst/pgsodium_root.key.pg15'
  [ -s "$CONFIG_TGZ" ] && [ -s "$KEY_COPY" ] || die "db-config backup failed."
  log "    $CONFIG_TGZ ($(du -h "$CONFIG_TGZ" | cut -f1)), key copy $(wc -c <"$KEY_COPY" | tr -d ' ') bytes"
  echo "$SOURCE_IMAGE" >"$WORK_DIR/source-image"
  set_state config-backed-up
}

start_upgrade_container() {
  step "start PG15 in $H_UPG (no network)"
  docker rm -f "$H_UPG" >/dev/null 2>&1 || true
  if vol_exists "$MIG_VOL"; then docker volume rm "$MIG_VOL" >/dev/null; fi
  docker volume create "$MIG_VOL" >/dev/null
  docker run -d --init --name "$H_UPG" --network none --user root --entrypoint sleep \
    -v "$DATA_VOL:/var/lib/postgresql/data" \
    -v "$MIG_VOL:/data_migration" \
    -v "$CONFIG_VOL:/etc/postgresql-custom" \
    -v "$WORK_DIR:/work:ro" \
    -e PGPASSWORD "$SOURCE_IMAGE" infinity >/dev/null
  docker exec -u root "$H_UPG" sh -c "chown postgres:postgres /data_migration && tar -C / -xzf '/work/$(basename "$TARBALL")'"
  docker exec -u postgres "$H_UPG" /usr/lib/postgresql/bin/pg_ctl start -w -t 600 -D /var/lib/postgresql/data \
    -o "-c config_file=/etc/postgresql/postgresql.conf" -l /tmp/pg15.log >/dev/null \
    || { docker exec "$H_UPG" tail -n 40 /tmp/pg15.log | sed 's/^/    | /'; die "PG15 did not start in $H_UPG."; }
  wait_ready "$H_UPG" 60
  log "    $(sqlv "$H_UPG" postgres 'select version()')"
}

# Counts as name=value lines. Relations that may be absent are counted lazily (query_to_xml) so the query parses.
counts_sql() {
  local rel q r w
  cat <<'EOS'
select 'server_version', current_setting('server_version')
union all select 'extensions', count(*)::text from pg_extension
EOS
  for rel in "cron_jobs|cron.job|" "cron_jobs_active|cron.job| where active" "auth_users|auth.users|" "vault_secrets|vault.secrets|"; do
    IFS='|' read -r q r w <<<"$rel"
    echo "union all select '$q', case when to_regclass('$r') is null then 'n/a' else (xpath('/row/c/text()', query_to_xml('select count(*) as c from $r$w', false, true, '')))[1]::text end"
  done
  cat <<'EOS'
union all select 'replication_slots', count(*)::text from pg_replication_slots
union all select 'public_objects_owned_by_supabase_admin',
  ((select count(*) from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = 'public' and c.relowner = 'supabase_admin'::regrole)
 + (select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace where n.nspname = 'public' and p.proowner = 'supabase_admin'::regrole)
 + (select count(*) from pg_type t join pg_namespace n on n.oid = t.typnamespace where n.nspname = 'public' and t.typowner = 'supabase_admin'::regrole and t.typrelid = 0 and t.typelem = 0))::text
EOS
}

# Vault decrypt check as postgres (SET ROLE keeps the password out of it). Prints "readable/total".
vault_check() {
  local c=$1
  if [ "$(sqlv "$c" postgres "select count(*) from pg_extension where extname='supabase_vault'")" = 0 ]; then echo "n/a"; return; fi
  psql_in "$c" postgres -At -c "set role postgres; select (select count(*) from vault.decrypted_secrets where decrypted_secret is not null) || '/' || (select count(*) from vault.secrets)"
}

cron_jobs_tsv() {
  psql_in "$1" postgres -At -F $'\t' -c "select jobid, coalesce(jobname, ''), username, active from cron.job order by jobid"
}

# Diffs cron.job principals (jobid, jobname, username) in container $1 against the pre-upgrade record.
cron_principals_check() {
  local c=$1 now
  [ -s "$REC_CRON_JOBS" ] || { log "    no cron.job record to compare"; return 0; }
  [ "$(sqlv "$c" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 1 ] || { warn "pg_cron missing"; return 0; }
  now=$(cron_jobs_tsv "$c" | cut -f1-3)
  if [ "$now" = "$(cut -f1-3 "$REC_CRON_JOBS")" ]; then
    log "    cron.job jobid/jobname/username identical to the pre-upgrade record ($(printf '%s\n' "$now" | sed '/^$/d' | wc -l | tr -d ' ') jobs)"
  else
    warn "cron.job jobid/jobname/username differ from the pre-upgrade record (complete.sh can rewrite username supabase_admin -> postgres):"
    diff <(cut -f1-3 "$REC_CRON_JOBS") <(printf '%s\n' "$now") | sed 's/^/    /' || true
  fi
}

pre_steps() {
  step "record pre-upgrade counts"
  psql_in "$H_UPG" postgres -At -F '=' -c "$(counts_sql)" | tee "$REC_PRE" | sed 's/^/    /'
  echo "vault_readable_as_postgres=$(vault_check "$H_UPG")" | tee -a "$REC_PRE" | sed 's/^/    /'
  if [ "$(sqlv "$H_UPG" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 1 ]; then
    cron_jobs_tsv "$H_UPG" >"$REC_CRON_JOBS"
    log "    cron.job (jobid, jobname, username, active) recorded: $(wc -l <"$REC_CRON_JOBS" | tr -d ' ') rows in $REC_CRON_JOBS"
  fi

  step "abort on extensions missing from 17"
  local db bad=""
  for db in $(dbs_in "$H_UPG"); do
    bad+=$(sqlv "$H_UPG" "$db" "select string_agg('$db.' || extname, ' ') from pg_extension where extname in ('timescaledb','plv8','plcoffee','plls')")
  done
  [ -z "$bad" ] || die "Not supported on Postgres 17: $bad. Drop them deliberately first; nothing was changed."

  step "drop pgjwt and wrappers (only if unused)"
  touch "$REC_DROPPED"
  local e row servers
  for db in $(dbs_in "$H_UPG"); do
    if [ "$(sqlv "$H_UPG" "$db" "select count(*) from pg_extension where extname='wrappers'")" = 1 ]; then
      servers=$(sqlv "$H_UPG" "$db" "select count(*) from pg_foreign_server")
      [ "$servers" = 0 ] || die "$db: wrappers is in use ($servers foreign servers). Abort; resolve it before the window."
    fi
    for e in pgjwt wrappers; do
      row=$(sqlv "$H_UPG" "$db" "select extname || E'\t' || extversion || E'\t' || extnamespace::regnamespace from pg_extension where extname = '$e'")
      [ -n "$row" ] || continue
      psql_in "$H_UPG" "$db" -c "DROP EXTENSION \"$e\"" \
        || die "$db: DROP EXTENSION $e failed (objects depend on it). Abort; PG15 otherwise unchanged."
      printf '%s\t%s\tkeep-dropped\n' "$db" "$row" >>"$REC_DROPPED"
      log "    $db: dropped $e (${row//$'\t'/ })"
    done
  done

  step "drop pgaudit (created again on 17)"
  for db in $(dbs_in "$H_UPG"); do
    row=$(sqlv "$H_UPG" "$db" "select extname || E'\t' || extversion || E'\t' || extnamespace::regnamespace from pg_extension where extname = 'pgaudit'")
    [ -n "$row" ] || continue
    psql_in "$H_UPG" "$db" -c 'DROP EXTENSION pgaudit'
    printf '%s\t%s\trecreate\n' "$db" "$row" >>"$REC_DROPPED"
    log "    $db: dropped pgaudit (${row//$'\t'/ })"
  done

  step "drop replication slots (record name, plugin)"
  local slots
  slots=$(sqlv "$H_UPG" postgres "select slot_name || E'\t' || coalesce(plugin,'') || E'\t' || slot_type || E'\t' || coalesce(database,'') from pg_replication_slots order by 1")
  if [ -n "$slots" ]; then
    local now_ts s
    now_ts=$(ts)
    while IFS= read -r s; do printf '%s\t%s\n' "$now_ts" "$s"; done <<<"$slots" >>"$REC_SLOTS"
    printf '%s\n' "$slots" | tr '\t' ' ' | sed 's/^/    slot: /'
    psql_in "$H_UPG" postgres -c "select pg_drop_replication_slot(slot_name) from pg_replication_slots where slot_type = 'logical'" >/dev/null
    local phys
    phys=$(sqlv "$H_UPG" postgres "select string_agg(slot_name, ' ') from pg_replication_slots")
    [ -z "$phys" ] || warn "physical slot(s) left (pg_upgrade does not carry them; recreate them for your WAL/PITR tooling after the upgrade): $phys"
  else
    log "    no replication slots"
  fi

  step "disable pg_cron jobs (record the active ones)"
  if [ "$(sqlv "$H_UPG" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 1 ]; then
    local active
    active=$(sqlv "$H_UPG" postgres "select jobid from cron.job where active order by jobid")
    { [ -f "$REC_CRON" ] && cat "$REC_CRON"; printf '%s\n' "$active"; } | sed '/^$/d' | sort -n -u >"$REC_CRON.tmp"
    mv "$REC_CRON.tmp" "$REC_CRON"
    psql_in "$H_UPG" postgres -c "update cron.job set active = false where active" >/dev/null
    log "    active now: $(echo "$active" | sed '/^$/d' | wc -l | tr -d ' '); recorded ids to re-enable: $(paste -sd, "$REC_CRON")"
  else
    log "    pg_cron not installed"
  fi

  step "drop the initiate.sh list ($INITIATE_DISABLE)"
  for db in $(dbs_in "$H_UPG"); do
    for e in $INITIATE_DISABLE; do
      row=$(sqlv "$H_UPG" "$db" "select extname || E'\t' || extversion || E'\t' || extnamespace::regnamespace from pg_extension where extname = '$e'")
      [ -n "$row" ] || continue
      psql_in "$H_UPG" "$db" -c "DROP EXTENSION IF EXISTS \"$e\" CASCADE"
      if [ -n "$FORCE_EXT_VERSION" ] && [ "${FORCE_EXT_VERSION%%=*}" = "$e" ]; then
        row="$e"$'\t'"${FORCE_EXT_VERSION#*=}"$'\t'"$(printf '%s' "$row" | cut -f3)"
        warn "TEST HOOK: recording $e as version ${FORCE_EXT_VERSION#*=}"
      fi
      printf '%s\t%s\trecreate\n' "$db" "$row" >>"$REC_DROPPED"
      log "    $db: dropped $e (${row//$'\t'/ })"
    done
  done

  # initiate.sh 8.1. pg_upgrade restores the schema as supabase_admin with supautils loaded, and supautils refuses
  # "Superuser owned event trigger must execute a superuser owned function" on databases where issue_pg_cron_access
  # (owner supabase_admin) and issue_pg_net_access (owner postgres) run postgres-owned functions (older databases,
  # see supabase/postgres#1437). A fresh image does not show it; a clone of a real database did.
  # Upstream makes postgres a superuser for the run and complete.sh 4.1 takes it back; restore_pg_super does that.
  step "grant SUPERUSER to postgres for pg_upgrade (initiate.sh 8.1)"
  local was
  was=$(sqlv "$H_UPG" postgres "select rolsuper from pg_roles where rolname = 'postgres'")
  case "$was" in t|f) ;; *) die "Could not read postgres's rolsuper (got '$was')." ;; esac
  # A re-run after a partial failure finds postgres already SUPERUSER: the first run's record stays authoritative.
  if [ -s "$REC_PGSUPER" ]; then
    log "    keeping the existing record $REC_PGSUPER ($(head -n 1 "$REC_PGSUPER")); rolsuper right now: $was"
  else
    printf '%s\n' "$was" >"$REC_PGSUPER.tmp"
    mv "$REC_PGSUPER.tmp" "$REC_PGSUPER"
  fi
  if [ "${PG17_UPGRADE_SKIP_PGSUPER:-0}" = 1 ]; then
    [ "$UUID" = testuuid ] || die "PG17_UPGRADE_SKIP_PGSUPER is a test-only hook (an e2e suite's UUID=testuuid); unset it"
    warn "TEST HOOK PG17_UPGRADE_SKIP_PGSUPER=1: postgres NOT made SUPERUSER (pg_upgrade is expected to fail on the older event-trigger ownership)"
  else
    psql_in "$H_UPG" postgres -c "ALTER USER postgres WITH SUPERUSER" >/dev/null || die "ALTER USER postgres WITH SUPERUSER failed"
  fi
  log "    postgres rolsuper before: $(cat "$REC_PGSUPER") (recorded); SUPERUSER until the PG17 post-steps or a rollback"
  set_state pre-steps-done
}

# complete.sh 4.1 (and initiate.sh's failure cleanup): put postgres back to its recorded rolsuper. No record
# means NOSUPERUSER, as upstream does unconditionally. Returns 1 (never exits) so rollback can still re-enable cron.
restore_pg_super() {
  local c=$1 want=f now src="recorded before"
  if [ -s "$REC_PGSUPER" ]; then want=$(head -n 1 "$REC_PGSUPER"); else src="no record: defaulting to NOSUPERUSER"; fi
  if [ "$want" = t ]; then
    log "    postgres stays SUPERUSER (it was one before the upgrade)"
  elif ! psql_in "$c" postgres -c "ALTER USER postgres WITH NOSUPERUSER" >/dev/null; then
    warn "ALTER USER postgres WITH NOSUPERUSER failed"
    return 1
  fi
  now=$(sqlv "$c" postgres "select rolsuper from pg_roles where rolname = 'postgres'" || echo error)
  log "    postgres rolsuper now: $now ($src: $want)"
  [ "$now" = "$want" ] || { warn "postgres rolsuper is $now, expected $want"; return 1; }
}

do_pg_upgrade() {
  read_cluster_context "$H_UPG"
  step "stop PG15 (clean shutdown)"
  docker exec -u postgres "$H_UPG" /usr/lib/postgresql/bin/pg_ctl stop -D /var/lib/postgresql/data -m fast -w -t 300 >/dev/null
  failpoint after-presql

  step "pg_upgrade --check (offline)"
  run_pg_upgrade "$H_UPG" check /tmp/pg17x /data_migration/pgdata || die "pg_upgrade --check failed; PG15 data not modified by pg_upgrade, but the pre-steps ARE applied (postgres is SUPERUSER, cron disabled, extensions dropped): run rollback before starting PG15."

  step "pg_upgrade --copy (15 -> 17)"
  run_pg_upgrade "$H_UPG" run /tmp/pg17x /data_migration/pgdata || {
    mkdir -p "$WORK_DIR/pg_upgrade-failed"
    docker cp "$H_UPG:/data_migration/pgdata/pg_upgrade_output.d" "$WORK_DIR/pg_upgrade-failed/" >/dev/null 2>&1 || true
    die "pg_upgrade failed (logs in $WORK_DIR/pg_upgrade-failed); PG15 data not modified by pg_upgrade, but the pre-steps ARE applied (postgres is SUPERUSER, cron disabled, extensions dropped): run rollback before starting PG15."
  }
  rm -rf "$WORK_DIR/pg_upgrade-run"
  mkdir -p "$WORK_DIR/pg_upgrade-run"
  docker cp "$H_UPG:/tmp/pg17x/run/." "$WORK_DIR/pg_upgrade-run/" >/dev/null 2>&1 || true
  docker cp "$H_UPG:/data_migration/pgdata/pg_upgrade_output.d" "$WORK_DIR/pg_upgrade-run/" >/dev/null 2>&1 || true
  docker exec -u root "$H_UPG" rm -rf /data_migration/pgdata/pg_upgrade_output.d
  log "    pg_upgrade outputs (update_extensions.sql etc.) in $WORK_DIR/pg_upgrade-run"
  stop_helper "$H_UPG"
  set_state pg-upgrade-done
  failpoint after-pgupgrade
}

chown_config_target() {
  step "chown db-config with the TARGET image (uid trap)"
  docker run --rm --network none --user root --entrypoint sh -v "$CONFIG_VOL:/vol" "$TARGET_IMAGE" \
    -c 'mkdir -p /vol/conf.d && chown -R postgres:postgres /vol && chmod 600 /vol/pgsodium_root.key && ls -ln /vol/pgsodium_root.key' | sed 's/^/    /'
}

swap_data() {
  step "swap: PG15 data -> $SIDE_VOL, PG17 data -> $DATA_VOL"
  # A daemon restart with restart: unless-stopped could have brought PG15 (or another service) back mid-copy.
  require_stopped
  volsh '[ -f "/dv/$M/_data/pgdata/PG_VERSION" ] && [ "$(cat "/dv/$M/_data/pgdata/PG_VERSION")" = 17 ]' -e M="$MIG_VOL" \
    || die "Upgraded data not found in $MIG_VOL."
  vol_exists "$SIDE_VOL" && die "$SIDE_VOL already exists."
  docker volume create "$SIDE_VOL" >/dev/null
  volsh 'set -e
    [ "$(stat -c %d "/dv/$D/_data")" = "$(stat -c %d "/dv/$M/_data")" ] || { echo "volumes on different filesystems" >&2; exit 1; }
    rmdir "/dv/$S/_data"
    mv "/dv/$D/_data" "/dv/$S/_data"
    echo "    moved $D/_data -> $S/_data"
    [ -n "$FAILSWAP" ] && { echo "failpoint mid-swap" >&2; exit 1; }
    mv "/dv/$M/_data/pgdata" "/dv/$D/_data"
    echo "    moved $M/_data/pgdata -> $D/_data"' \
    -e D="$DATA_VOL" -e S="$SIDE_VOL" -e M="$MIG_VOL" -e FAILSWAP="$([ "$FAIL_AT" = mid-swap ] && echo 1 || true)" \
    || die "swap failed"
  docker volume rm "$MIG_VOL" >/dev/null
  set_state swapped
  failpoint after-swap
}

start_finish_container() {
  step "start PG17 once in $H_FIN (no network)"
  docker rm -f "$H_FIN" >/dev/null 2>&1 || true
  docker run -d --name "$H_FIN" --network none \
    -v "$DATA_VOL:/var/lib/postgresql/data" \
    -v "$CONFIG_VOL:/etc/postgresql-custom" \
    -v "$WORK_DIR:/work:ro" \
    -e POSTGRES_PASSWORD -e PGPASSWORD \
    "$TARGET_IMAGE" postgres -c config_file=/etc/postgresql/postgresql.conf -c pg_net.batch_size=0 >/dev/null
  wait_ready "$H_FIN" 150
  log "    pg_net.batch_size=$(sqlv "$H_FIN" postgres "select coalesce(current_setting('pg_net.batch_size', true), 'n/a')") (0 = pg_net sends nothing while in this helper)"
  local v
  v=$(sqlv "$H_FIN" postgres "show server_version")
  log "    server_version $v"
  case "$v" in 17.*) ;; *) die "Expected 17.x, got $v" ;; esac
}

# complete.sh equivalents: recreate the initiate.sh-disabled extensions (its pg_upgrade_extensions.sql) and run
# complete.sh's execute_patches verbatim (pg_net grants, pg_cron owner fix, extension owner fixes, vault, predefined roles).
complete_steps() {
  step "complete.sh: recreate disabled extensions, execute_patches"
  local db name ver schema reason
  while IFS=$'\t' read -r db name ver schema reason; do
    [ "$reason" = recreate ] || continue
    [ "$name" = pgaudit ] && continue
    psql_in "$H_FIN" "$db" -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_available_extensions WHERE name = '$name') THEN CREATE EXTENSION IF NOT EXISTS \"$name\" SCHEMA \"$schema\" CASCADE; END IF; END \$\$;" \
      || die "$db: recreating $name failed"
    log "    $db: $name -> $(sqlv "$H_FIN" "$db" "select coalesce((select extversion from pg_extension where extname='$name'), 'not available')")"
  done < <(sort -u -t$'\t' -k1,2 "$REC_DROPPED")
  if ! docker exec -i -u root -e PGPASSWORD -e IS_CI=true "$H_FIN" bash -c \
    "mkdir -p /tmp/upgrade && cp /work/$(basename "$SCRIPTS_DIR")/complete.sh /work/$(basename "$SCRIPTS_DIR")/common.sh /tmp/upgrade/ && bash /tmp/upgrade/complete.sh execute_patches" 2>&1 | sed 's/^/    | /'; then
    die "complete.sh execute_patches failed"
  fi
  restore_pg_super "$H_FIN" || die "could not put postgres back to its recorded rolsuper"
}

post_migrations() {
  step "1. upstream PG17 post-migrations"
  local m fails=0
  psql_in "$H_FIN" postgres -c "
    DO \$\$ BEGIN
      IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = 'supabase_etl_admin') THEN
        CREATE USER supabase_etl_admin WITH LOGIN REPLICATION;
        GRANT pg_read_all_data TO supabase_etl_admin;
        GRANT CREATE ON DATABASE postgres TO supabase_etl_admin;
      END IF;
    END \$\$;" >/dev/null || { warn "supabase_etl_admin creation failed"; fails=$((fails + 1)); }
  for m in $POST_MIGRATIONS; do
    if psql_in "$H_FIN" postgres -f "/docker-entrypoint-initdb.d/migrations/$m" >/dev/null 2>"$WORK_DIR/.mig.err"; then
      log "    ok   $m"
    else
      warn "failed $m: $(head -n 3 "$WORK_DIR/.mig.err" | tr '\n' ' ')"
      fails=$((fails + 1))
    fi
  done
  rm -f "$WORK_DIR/.mig.err"
  POST_MIGRATION_FAILS=$fails
}

# Collation versions recorded in the catalog vs what the running library reports. A mismatch means indexes on
# collatable columns may be ordered differently: reindex BEFORE the refresh, never refresh alone (a refresh alone hides the need to reindex).
collation_mismatches() {
  local db n=0 d c
  d=$(sqlv "$H_FIN" postgres "select count(*) from pg_database where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid)")
  n=$((n + d))
  for db in $(dbs_in "$H_FIN"); do
    c=$(sqlv "$H_FIN" "$db" "select count(*) from pg_collation where collversion is not null and collversion is distinct from pg_collation_actual_version(oid)")
    [ "$c" = 0 ] || log "    $db: $c pg_collation row(s) with a changed version" >&2
    n=$((n + c))
  done
  [ "$d" = 0 ] || log "    $d database(s) with datcollversion != actual: $(sqlv "$H_FIN" postgres "select string_agg(datname || ' ' || coalesce(datcollversion,'?') || '->' || coalesce(pg_database_collation_actual_version(oid),'?'), ', ') from pg_database where datallowconn and datcollversion is distinct from pg_database_collation_actual_version(oid)")" >&2
  echo "$n"
}

refresh_collation() {
  step "2. collation check, reindex if needed, ALTER DATABASE ... REFRESH COLLATION VERSION"
  local db mism
  mism=$(collation_mismatches)
  if [ "$mism" != 0 ]; then
    warn "!!! COLLATION VERSION MISMATCH ($mism): indexes on text columns may be ordered differently on this glibc !!!"
    if [ "${PG17_UPGRADE_SKIP_REINDEX:-0}" != 1 ] && [ "$ANALYZE" = now ]; then
      log "    reindexdb --all before the refresh (ANALYZE=now)"
      if ! docker exec -e PGPASSWORD "$H_FIN" reindexdb --all -j 2 -h localhost -U supabase_admin 2>&1 | sed 's/^/    | /'; then
        die "reindexdb failed; the collation refresh was NOT run"
      fi
      refresh_collation_rows
    else
      {
        echo "REQUIRED post-window step ($(ts)): $mism collation version mismatch(es) after the PG17 upgrade."
        echo "Run on the live PG17 db container, in a quiet hour, BEFORE trusting text-index ordering:"
        echo "  docker exec $DB_CONTAINER reindexdb --all --concurrently -h localhost -U supabase_admin"
        echo "then: ALTER DATABASE <db> REFRESH COLLATION VERSION for postgres, template1, _supabase,"
        echo "and ALTER COLLATION <name> REFRESH VERSION for every pg_collation row whose collversion differs."
      } >"$REINDEX_TODO"
      warn "ANALYZE=$ANALYZE: reindex NOT run in the window; REQUIRED post-window step written to $REINDEX_TODO; the refresh is deferred with it"
      return 0
    fi
  else
    log "    no collation version mismatch"
  fi
  # Nothing is deferred by this run: an older REQUIRED file (an earlier ANALYZE=defer run) no longer applies.
  if [ -f "$REINDEX_TODO" ]; then mv "$REINDEX_TODO" "$REINDEX_TODO.resolved-$(date -u +%Y%m%dT%H%M%SZ)"; log "    earlier REQUIRED reindex note resolved by this run"; fi
  for db in postgres template1 _supabase; do
    if [ "$(sqlv "$H_FIN" postgres "select count(*) from pg_database where datname='$db'")" = 1 ]; then
      psql_in "$H_FIN" "$db" -c "ALTER DATABASE \"$db\" REFRESH COLLATION VERSION" 2>&1 | sed 's/^/    /' || warn "$db: refresh failed"
    else
      log "    $db: no such database"
    fi
  done
}

# After a reindex: refresh the version of every pg_collation row whose recorded collversion differs.
refresh_collation_rows() {
  local db q
  for db in $(dbs_in "$H_FIN"); do
    for q in $(sqlv "$H_FIN" "$db" "select format('%I.%I', n.nspname, c.collname) from pg_collation c join pg_namespace n on n.oid = c.collnamespace where c.collversion is not null and c.collversion is distinct from pg_collation_actual_version(c.oid)"); do
      psql_in "$H_FIN" "$db" -c "ALTER COLLATION $q REFRESH VERSION" 2>&1 | sed 's/^/    /' || warn "$db: ALTER COLLATION $q REFRESH VERSION failed"
    done
  done
}

update_extensions() {
  step "3. ALTER EXTENSION ... UPDATE (every extension)"
  local db e before after err
  for db in $(dbs_in "$H_FIN"); do
    for e in $(sqlv "$H_FIN" "$db" "select extname from pg_extension order by extname"); do
      before=$(sqlv "$H_FIN" "$db" "select extversion from pg_extension where extname='$e'")
      if err=$(psql_in "$H_FIN" "$db" -c "ALTER EXTENSION \"$e\" UPDATE" 2>&1); then
        after=$(sqlv "$H_FIN" "$db" "select extversion from pg_extension where extname='$e'")
        if [ "$before" = "$after" ]; then log "    $db.$e $before (unchanged)"; else log "    $db.$e $before -> $after"; fi
      else
        log "    $db.$e $before SKIPPED: $(printf '%s' "$err" | grep -m1 -E 'ERROR' | sed 's/^.*ERROR: *//')"
      fi
    done
  done
  # upgrade-pg17.sh: pg_cron 1.6 has no path to the packaged 1.6.4 (no SQL delta); relabel, no DROP.
  psql_in "$H_FIN" postgres -c "
    DO \$\$ DECLARE want text; BEGIN
      SELECT default_version INTO want FROM pg_available_extensions WHERE name = 'pg_cron';
      IF want IS NOT NULL AND EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron' AND extversion <> want) THEN
        UPDATE pg_extension SET extversion = want WHERE extname = 'pg_cron';
        RAISE NOTICE 'pg_cron relabelled to %', want;
      END IF;
    END \$\$;" 2>&1 | sed 's/^/    /'
  failpoint in-finish
}

vault_grants() {
  step "4. vault grants (after the update batch)"
  if [ "$(sqlv "$H_FIN" postgres "select count(*) from pg_extension where extname='supabase_vault'")" = 0 ]; then
    log "    supabase_vault not installed"; return
  fi
  # Vault grants re-applied after the extension update pass.
  psql_in "$H_FIN" postgres -c "
    grant usage on schema vault to postgres with grant option;
    grant select, delete, truncate, references on vault.secrets, vault.decrypted_secrets to postgres with grant option;
    grant execute on function vault.create_secret, vault.update_secret, vault._crypto_aead_det_decrypt to postgres with grant option;
    grant usage on schema vault to service_role;
    grant select, delete on vault.secrets, vault.decrypted_secrets to service_role;
    grant execute on function vault.create_secret, vault.update_secret, vault._crypto_aead_det_decrypt to service_role;" >/dev/null \
    || die "vault grants failed"
  log "    vault readable as postgres: $(vault_check "$H_FIN")"
}

create_pgaudit() {
  step "5. CREATE EXTENSION pgaudit"
  local db name ver schema reason done_any=false
  while IFS=$'\t' read -r db name ver schema reason; do
    [ "$name" = pgaudit ] || continue
    psql_in "$H_FIN" "$db" -c "CREATE EXTENSION IF NOT EXISTS pgaudit SCHEMA \"$schema\"" >/dev/null || die "$db: CREATE EXTENSION pgaudit failed"
    log "    $db: pgaudit $(sqlv "$H_FIN" "$db" "select extversion from pg_extension where extname='pgaudit'") in $schema (was $ver)"
    done_any=true
  done < <(sort -u -t$'\t' -k1,2 "$REC_DROPPED")
  if [ "$done_any" = false ]; then
    local s
    s=$(sqlv "$H_FIN" postgres "select case when exists (select from pg_namespace where nspname='extensions') then 'extensions' else 'public' end")
    psql_in "$H_FIN" postgres -c "CREATE EXTENSION IF NOT EXISTS pgaudit SCHEMA \"$s\"" >/dev/null || die "CREATE EXTENSION pgaudit failed"
    log "    postgres: pgaudit $(sqlv "$H_FIN" postgres "select extversion from pg_extension where extname='pgaudit'") (no drop recorded, created in $s)"
  fi
  log "    pgaudit in shared_preload_libraries: $(sqlv "$H_FIN" postgres "select current_setting('shared_preload_libraries') like '%pgaudit%'")"
  log "    pgaudit.* settings now: $(sqlv "$H_FIN" postgres "select coalesce(string_agg(distinct split_part(c, '=', 1), ','), 'none') from pg_db_role_setting, unnest(setconfig) c where c like 'pgaudit.%'") (before: $(cat "$WORK_DIR/pgaudit-settings.txt" 2>/dev/null || echo unknown))"
}

# Re-enables exactly the recorded cron jobs in container $1.
reenable_cron() {
  local c=$1
  if [ "$(sqlv "$c" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 0 ]; then log "    pg_cron not installed"; return; fi
  if [ ! -s "$REC_CRON" ]; then log "    no recorded active jobs"; return; fi
  local ids got want
  ids=$(paste -sd, "$REC_CRON")
  psql_in "$c" postgres -c "update cron.job set active = true where jobid in ($ids)" >/dev/null || die "cron re-enable failed"
  got=$(sqlv "$c" postgres "select coalesce(string_agg(jobid::text, ',' order by jobid), '') from cron.job where active")
  want=$(sqlv "$c" postgres "select coalesce(string_agg(jobid::text, ',' order by jobid), '') from cron.job where jobid in ($ids)")
  log "    recorded: $ids; active now: ${got:-none}"
  [ "$got" = "$want" ] || die "cron active set ($got) differs from the recorded set present in cron.job ($want)"
  [ "$want" = "$ids" ] || warn "recorded job ids missing from cron.job: recorded $ids, present $want"
}

run_analyze() {
  step "7. vacuumdb --all --analyze-in-stages"
  local cmd="PGOPTIONS='-c vacuum_cost_delay=0' vacuumdb --all --analyze-in-stages -j 2 -h localhost -U supabase_admin"
  if [ "$ANALYZE" = defer ]; then
    log "    DEFERRED (ANALYZE=defer). Post-window, on the live PG17 container: docker exec $DB_CONTAINER sh -c \"$cmd\""
    log "    Until stage 1 finishes the planner has no statistics (pg_upgrade carries none)."
    return
  fi
  local t=$SECONDS
  if ! docker exec -e PGPASSWORD "$H_FIN" sh -c "$cmd" 2>&1 | sed 's/^/    | /'; then
    warn "vacuumdb returned non-zero"
  fi
  log "    analyze-in-stages took $((SECONDS - t))s"
}

verify() {
  local c=$1 label=$2
  step "8. verification ($label)"
  log "    server_version: $(sqlv "$c" postgres "show server_version")"
  log "    extensions:"
  sqlv "$c" postgres "select extname || ' ' || extversion from pg_extension order by 1" | sed 's/^/        /'
  if [ "$(sqlv "$c" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 1 ]; then
    log "    cron jobs: $(sqlv "$c" postgres "select count(*) from cron.job"), active: $(sqlv "$c" postgres "select count(*) from cron.job where active") (ids $(sqlv "$c" postgres "select coalesce(string_agg(jobid::text, ',' order by jobid), 'none') from cron.job where active"))"
  fi
  log "    auth.users: $(sqlv "$c" postgres "select case when to_regclass('auth.users') is null then 'n/a' else (select count(*)::text from auth.users) end")"
  log "    vault decrypt as postgres (readable/total, 0/0 is OK): $(vault_check "$c")"
  log "    public objects owned by supabase_admin: $(psql_in "$c" postgres -At -F '=' -c "$(counts_sql)" | sed -n 's/^public_objects_owned_by_supabase_admin=//p')"
  log "    replication slots: $(sqlv "$c" postgres "select count(*) from pg_replication_slots")"
  local su want=f
  su=$(sqlv "$c" postgres "select rolsuper from pg_roles where rolname = 'postgres'")
  [ -s "$REC_PGSUPER" ] && want=$(head -n 1 "$REC_PGSUPER")
  log "    postgres superuser: $su (expected $want)"
  [ "$su" = "$want" ] || die "postgres is SUPERUSER=$su after $label, expected $want: run ALTER USER postgres WITH $([ "$want" = t ] && echo SUPERUSER || echo NOSUPERUSER)"
  cron_principals_check "$c"
  log "    pre vs now:"
  local now k v pre
  now=$(psql_in "$c" postgres -At -F '=' -c "$(counts_sql)")
  while IFS='=' read -r k v; do
    pre=$(sed -n "s/^$k=//p" "$REC_PRE" 2>/dev/null | head -n 1)
    printf '%s         %-40s before=%-12s now=%s\n' "$(ts)" "$k" "${pre:--}" "$v"
  done <<<"$now"
}

do_upgrade() {
  setup_workdir
  step "preflight (upgrade)"
  [ -s "$TARBALL" ] && [ -s "$STOREPATH_FILE" ] && [ -s "$PATHS_FILE" ] || die "No tarball in $WORK_DIR: run prepare first."
  [ -s "$SCRIPTS_DIR/complete.sh" ] && [ -s "$SCRIPTS_DIR/common.sh" ] || die "No upstream scripts in $SCRIPTS_DIR: run prepare first."
  docker image inspect "$SOURCE_IMAGE" >/dev/null 2>&1 || die "$SOURCE_IMAGE not present (run prepare)."
  docker image inspect "$TARGET_IMAGE" >/dev/null 2>&1 || die "$TARGET_IMAGE not present (run prepare)."
  vol_exists "$DATA_VOL" || die "Volume $DATA_VOL not found."
  vol_exists "$CONFIG_VOL" || die "Volume $CONFIG_VOL not found."
  vol_exists "$SIDE_VOL" && die "$SIDE_VOL exists: a previous upgrade's PG15 data. Run rollback, or remove it deliberately after a verified upgrade."
  require_stopped
  volume_root
  local v
  v=$(vol_pgversion "$DATA_VOL")
  [ "$v" = 15 ] || die "$DATA_VOL holds PG_VERSION=$v, expected 15."
  if container_exists "$DB_CONTAINER"; then
    local img
    img=$(docker inspect -f '{{.Config.Image}}' "$DB_CONTAINER")
    [ "$img" = "$SOURCE_IMAGE" ] || [[ "$img" == "$SOURCE_IMAGE@"* ]] || die "$DB_CONTAINER was created from $img, expected $SOURCE_IMAGE."
  fi
  load_password
  disk_gate || die "disk gate failed"
  log "About to upgrade $DATA_VOL in place (copy mode). PG15 data will move to $SIDE_VOL."
  confirm "Proceed with the Postgres 15 -> 17 upgrade?"
  set_state upgrade-started

  backup_config
  start_upgrade_container
  pre_steps
  do_pg_upgrade
  chown_config_target
  swap_data
  start_finish_container
  finish_steps
  log "UPGRADE DONE. $DATA_VOL is PG17; PG15 copy in $SIDE_VOL; db-config backup $CONFIG_TGZ; key copy $KEY_COPY."
  log "Next: switch the compose db image to $TARGET_IMAGE, up -d --no-deps supabase-db, check the coolify network."
  summary
}

# The PG17 post-steps, all idempotent, shared by upgrade and finish. Cron jobs are re-enabled last, after analyze
# and verify and right before the stop, so nothing fires while the helper runs (pg_net.batch_size=0 as well).
POST_MIGRATION_FAILS=0
finish_steps() {
  complete_steps
  POST_MIGRATION_FAILS=0
  post_migrations
  refresh_collation
  update_extensions
  vault_grants
  create_pgaudit
  run_analyze
  verify "$H_FIN" PG17
  step "6. re-enable the recorded cron jobs (last, right before the stop)"
  reenable_cron "$H_FIN"
  log "    cron jobs active after the re-enable (the verify table above was taken before it, so its 0 is expected): $(cron_active_ids "$H_FIN")"
  step "stop PG17 helper"
  stop_helper "$H_FIN"
  set_state upgrade-done
  [ "$POST_MIGRATION_FAILS" -eq 0 ] || warn "$POST_MIGRATION_FAILS upstream post-migration(s) failed (non-fatal, as upstream); see above."
  if [ -s "$REINDEX_TODO" ]; then
    warn "REQUIRED POST-WINDOW STEP (from $REINDEX_TODO):"
    sed 's/^/    /' "$REINDEX_TODO"
  fi
}

cron_active_ids() {
  if [ "$(sqlv "$1" postgres "select count(*) from pg_extension where extname='pg_cron'")" = 0 ]; then echo "n/a"; return; fi
  sqlv "$1" postgres "select coalesce(string_agg(jobid::text, ',' order by jobid), 'none') from cron.job where active"
}

# Refuses when a PG15 side volume exists but this WORK_DIR has no state file: the records that drive the
# finished-upgrade refusal, the extension recreate and the cron re-enable live there.
require_state_for_side() {
  if vol_exists "$SIDE_VOL" && [ ! -s "$STATE_FILE" ]; then
    die "$SIDE_VOL exists but $STATE_FILE is missing: WORK_DIR=$WORK_DIR is not the one the upgrade used (default /root/pg17-upgrade-$UUID). Re-run with the upgrade's WORK_DIR."
  fi
}

# finish: re-run the PG17 post-steps on an already-swapped volume (a transient failure there need not mean rollback).
do_finish() {
  setup_workdir
  step "preflight (finish)"
  [ -s "$SCRIPTS_DIR/complete.sh" ] && [ -s "$SCRIPTS_DIR/common.sh" ] || die "No upstream scripts in $SCRIPTS_DIR: run prepare first."
  require_stopped
  vol_exists "$DATA_VOL" || die "Volume $DATA_VOL not found."
  vol_exists "$SIDE_VOL" || die "No $SIDE_VOL: the swap has not happened; finish only resumes after the swap."
  volume_root
  local dv sv
  dv=$(vol_pgversion "$DATA_VOL")
  sv=$(vol_pgversion "$SIDE_VOL")
  [ "$dv" = 17 ] && [ "$sv" = 15 ] || die "Expected $DATA_VOL=17 and $SIDE_VOL=15, found $dv and $sv."
  require_state_for_side
  grep -q ' swapped$' "$STATE_FILE" 2>/dev/null || die "$STATE_FILE has no 'swapped' record; not resuming."
  local last
  last=$(grep -E ' (upgrade-started|swapped|upgrade-done|rolled-back)$' "$STATE_FILE" | tail -n 1)
  if [[ "$last" == *" upgrade-done" ]]; then
    warn "The upgrade already FINISHED ($last). If PG17 has served traffic, finish re-activates the recorded cron jobs (and re-runs the post-steps)."
    [ "$FORCE_FINISH" = true ] || die "Refusing: finish after upgrade-done needs --force-finish (--yes does not imply it)."
  fi
  load_password
  confirm "Re-run the PG17 post-steps on $DATA_VOL?"
  chown_config_target
  start_finish_container
  finish_steps
  log "FINISH DONE. $DATA_VOL is PG17 with the post-steps applied; PG15 copy in $SIDE_VOL."
  summary
}

# --- rollback --------------------------------------------------------------------------------------------

do_rollback() {
  setup_workdir
  step "preflight (rollback)"
  require_stopped
  vol_exists "$DATA_VOL" || die "Volume $DATA_VOL not found."
  vol_exists "$CONFIG_VOL" || die "Volume $CONFIG_VOL not found."
  volume_root
  load_password
  if vol_exists "$SIDE_VOL" && [ "$(vol_pgversion "$SIDE_VOL")" = 15 ]; then require_state_for_side; fi
  local dv sv=none
  dv=$(vol_pgversion "$DATA_VOL")
  vol_exists "$SIDE_VOL" && sv=$(vol_pgversion "$SIDE_VOL")
  log "    $DATA_VOL: $dv; $SIDE_VOL: $sv"
  if [ "$sv" = empty ] || [ "$sv" = missing ]; then
    # Created by swap_data but the first move never happened (or was undone): nothing in it to restore.
    log "    $SIDE_VOL holds no data: treated as absent and removed"
    volsh 'mkdir -p "/dv/$S/_data"' -e S="$SIDE_VOL"
    docker volume rm "$SIDE_VOL" >/dev/null
    sv=none
  fi
  local plan=""
  if [ "$sv" = 15 ]; then
    case "$dv" in
      missing|empty) plan="move-back" ;;
      17|other) plan="aside-and-move-back" ;;
      15) die "Both $DATA_VOL and $SIDE_VOL hold PG15 data. Resolve by hand." ;;
    esac
  elif [ "$sv" = none ]; then
    [ "$dv" = 15 ] || die "$DATA_VOL holds '$dv' and there is no $SIDE_VOL. Nothing to roll back to."
    plan="data-in-place"
  else
    die "$SIDE_VOL holds '$sv', expected 15."
  fi
  local last_state
  last_state=$(grep -E ' (upgrade-started|upgrade-done|rolled-back)$' "$STATE_FILE" 2>/dev/null | tail -n 1 || true)
  if [ "$plan" = aside-and-move-back ] && [[ "$last_state" == *" upgrade-done" ]]; then
    local ckpt
    ckpt=$(docker run --rm --network none --user root --entrypoint pg_controldata -v "$DATA_VOL:/d:ro" "$TARGET_IMAGE" /d 2>/dev/null \
      | sed -n 's/^Time of latest checkpoint:[[:space:]]*//p')
    warn "The upgrade FINISHED (state: $last_state). PG17's latest checkpoint: ${ckpt:-unknown}."
    warn "Anything written to PG17 after the upgrade finished is LOST by this rollback (it returns to the PG15 stop)."
    [ "$DISCARD_PG17_WRITES" = true ] || die "Refusing: rolling back a finished upgrade discards PG17 writes. Re-run with --discard-pg17-writes (--yes does not imply it)."
    confirm "Roll back to Postgres 15 and LOSE every write made on PG17 since ${last_state%% *}?"
  else
    confirm "Roll back to Postgres 15 ($plan)?"
  fi

  step "restore PG15 data ($plan)"
  if [ "$plan" = aside-and-move-back ]; then
    local aside
    aside="${DATA_VOL}-pg17-failed-$(date -u +%Y%m%d%H%M%S)"
    docker volume create "$aside" >/dev/null
    volsh 'set -e; rmdir "/dv/$A/_data"; mv "/dv/$D/_data" "/dv/$A/_data"' -e A="$aside" -e D="$DATA_VOL"
    log "    PG17 data moved aside to volume $aside (remove it once PG15 is verified)"
  fi
  if [ "$plan" != data-in-place ]; then
    volsh 'set -e; [ -d "/dv/$D/_data" ] && rmdir "/dv/$D/_data"; mv "/dv/$S/_data" "/dv/$D/_data"; mkdir "/dv/$S/_data"' -e D="$DATA_VOL" -e S="$SIDE_VOL"
    docker volume rm "$SIDE_VOL" >/dev/null
    log "    $SIDE_VOL -> $DATA_VOL; side volume removed"
  fi
  if vol_exists "$MIG_VOL"; then docker volume rm "$MIG_VOL" >/dev/null; log "    removed scratch volume $MIG_VOL"; fi
  [ "$(vol_pgversion "$DATA_VOL")" = 15 ] || die "$DATA_VOL is not PG15 after the move."

  step "restore db-config and chown with the SOURCE image"
  if [ -s "$CONFIG_TGZ" ]; then
    # Extract into a temp dir inside the volume and verify it first; only then replace the old content.
    if ! docker run --rm --network none --user root --entrypoint sh -v "$CONFIG_VOL:/vol" -v "$WORK_DIR:/src:ro" "$SOURCE_IMAGE" -c '
      set -e
      T=/vol/.pg15-restore
      rm -rf "$T"
      mkdir "$T"
      tar -xzf /src/db-config.pg15.tgz -C "$T"
      cmp -s "$T/pgsodium_root.key" /src/pgsodium_root.key.pg15 || { echo "restored key differs from the key copy; volume untouched" >&2; rm -rf "$T"; exit 1; }
      find /vol -mindepth 1 -maxdepth 1 ! -name .pg15-restore -exec rm -rf {} \;
      for f in "$T"/.[!.]* "$T"/..?* "$T"/*; do
        if [ -e "$f" ] || [ -L "$f" ]; then mv "$f" /vol/; fi
      done
      rmdir "$T"
      chown -R postgres:postgres /vol
      chmod 600 /vol/pgsodium_root.key
      ls -ln /vol/pgsodium_root.key' | sed 's/^/    /'; then
      die "db-config restore failed"
    fi
  else
    warn "no $CONFIG_TGZ (the upgrade failed before the backup): config left as is, chown only"
    docker run --rm --network none --user root --entrypoint sh -v "$CONFIG_VOL:/vol" "$SOURCE_IMAGE" -c 'chown -R postgres:postgres /vol'
  fi

  step "start PG15 once in $H_RB (no network) and undo the pre-steps"
  docker rm -f "$H_RB" >/dev/null 2>&1 || true
  docker run -d --name "$H_RB" --network none \
    -v "$DATA_VOL:/var/lib/postgresql/data" -v "$CONFIG_VOL:/etc/postgresql-custom" \
    -e POSTGRES_PASSWORD -e PGPASSWORD "$SOURCE_IMAGE" postgres -c config_file=/etc/postgresql/postgresql.conf >/dev/null
  wait_ready "$H_RB" 150
  local v
  v=$(sqlv "$H_RB" postgres "show server_version")
  case "$v" in 15.*) log "    server_version $v" ;; *) die "Expected 15.x, got $v" ;; esac
  # Nothing here may stop the cron re-enable below: errors are collected and reported after it.
  local rb_errors=0
  if [ -s "$REC_DROPPED" ]; then
    local db name ver schema reason
    while IFS=$'\t' read -r db name ver schema reason; do
      [ "$reason" = recreate ] || { log "    $db: $name stays dropped (unused cleanup)"; continue; }
      if psql_in "$H_RB" "$db" -c "CREATE EXTENSION IF NOT EXISTS \"$name\" VERSION '$ver' SCHEMA \"$schema\" CASCADE" >/dev/null 2>"$WORK_DIR/.rb.err"; then
        log "    $db: $name $(sqlv "$H_RB" "$db" "select extversion from pg_extension where extname='$name'") restored"
      elif psql_in "$H_RB" "$db" -c "CREATE EXTENSION IF NOT EXISTS \"$name\" SCHEMA \"$schema\" CASCADE" >/dev/null 2>>"$WORK_DIR/.rb.err"; then
        warn "$db: $name $ver is not installable in $SOURCE_IMAGE ($(grep -m1 ERROR "$WORK_DIR/.rb.err" | sed 's/.*ERROR: *//')); restored at the default $(sqlv "$H_RB" "$db" "select extversion from pg_extension where extname='$name'") instead"
      else
        warn "$db: could not recreate $name: $(grep ERROR "$WORK_DIR/.rb.err" | tail -n 1 | sed 's/.*ERROR: *//')"
        rb_errors=$((rb_errors + 1))
      fi
    done < <(sort -u -t$'\t' -k1,2 "$REC_DROPPED")
    rm -f "$WORK_DIR/.rb.err"
  fi
  step "postgres back to its recorded rolsuper"
  restore_pg_super "$H_RB" || rb_errors=$((rb_errors + 1))
  step "re-enable the recorded cron jobs"
  reenable_cron "$H_RB"
  if [ -s "$REC_SLOTS" ]; then log "    logical slots are not recreated (Realtime recreates its own; recreate any slot your WAL/PITR tooling needs): $(cut -f2 "$REC_SLOTS" | sort -u | paste -sd' ' -)"; fi
  verify "$H_RB" PG15-after-rollback
  step "stop PG15 helper"
  stop_helper "$H_RB"
  [ "$rb_errors" -eq 0 ] || die "rollback restored the data and re-enabled cron, but $rb_errors step(s) failed (extension recreate or postgres rolsuper, above). Records kept for a re-run."
  local stamp
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  for f in "$REC_DROPPED" "$REC_CRON" "$REC_SLOTS" "$REC_PGSUPER"; do [ -f "$f" ] && mv "$f" "$f.rolledback-$stamp"; done
  set_state rolled-back
  log "ROLLBACK DONE. $DATA_VOL is PG15 again (exact state at the stop; PG17 writes, if any, are not carried)."
  log "Next: keep the compose db image at $SOURCE_IMAGE, up -d --no-deps supabase-db, start the rest; then re-point any WAL/PITR tooling."
  summary
}

case "$MODE" in
  prepare) do_prepare ;;
  upgrade) do_upgrade ;;
  finish) do_finish ;;
  rollback) do_rollback ;;
esac
