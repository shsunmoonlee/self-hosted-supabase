#!/usr/bin/env bash
# safe-recreate.sh: recreate ONE container of a Coolify-managed Docker Compose service from the host, without
# losing the networks Coolify attached to it.
#
# Why: Coolify connects service containers to its shared `coolify` network (with an alias) during its own
# deploys, outside the compose file on disk. A host-side `docker compose up -d --force-recreate <svc>` builds
# the container from the compose file only, so the new container is missing that network. Anything that
# reaches the service over `coolify` (another app on the same server, for example) breaks, while public
# checks through the proxy can stay green.
#
# What it does:
#   1. records the container's networks and aliases (run dir, 0700);
#   2. refuses if the compose file names a different image than the running one (unless --expect-image);
#   3. compose --dry-run gate: exactly one "Container <name> Recreate" line for that container, and no
#      other container, network or volume in the plan;
#   4. with --apply: up -d --no-deps --force-recreate <svc>, waits for healthy;
#   5. reconnects every recorded network that is missing, with the recorded aliases;
#   6. checks that every bind-mounted file is readable inside the container (best effort);
#   7. optional: polls --probe-url until it answers 2xx, so you test the path your app really uses.
# It never prints `docker compose config` output or .env content (both hold secrets).
#
# Usage (as root on the host):
#   bash safe-recreate.sh --uuid <service-uuid> --service <compose-service> [--dir <stack dir>]
#        [--expect-image <image ref>] [--probe-url <url>] [--wait <seconds>] [--apply]
#   Without --apply it is a dry run. --dir defaults to /data/coolify/services/<service-uuid>.
#
# Before you use it: record the same change in Coolify's stored compose (see docs/08-coolify.md in the handbook), or the
# next Coolify deploy reverts your edit. Keep your own rollback copy of the compose, .env and bind files.
#
# Exit codes: 0 ok (or dry run passed), 1 refused before any change, 2 recreated but a check failed
# (the printed commands show how to inspect or roll back), 3 usage error.

set -euo pipefail
umask 077

UUID="" SERVICE="" DIR="" EXPECT_IMAGE="" PROBE_URL="" WAIT_S=120 APPLY=false
while [ $# -gt 0 ]; do
  case "$1" in
    --uuid) UUID=${2:?}; shift 2 ;;
    --service) SERVICE=${2:?}; shift 2 ;;
    --dir) DIR=${2:?}; shift 2 ;;
    --expect-image) EXPECT_IMAGE=${2:?}; shift 2 ;;
    --probe-url) PROBE_URL=${2:?}; shift 2 ;;
    --wait) WAIT_S=${2:?}; shift 2 ;;
    --apply) APPLY=true; shift ;;
    -h|--help) sed -n '2,32p' "$0"; exit 0 ;;
    *) echo "unknown argument: $1" >&2; exit 3 ;;
  esac
done
[ -n "$UUID" ] && [ -n "$SERVICE" ] || { echo "--uuid and --service are required" >&2; exit 3; }
[[ "$UUID" =~ ^[a-z0-9]+$ ]] || { echo "--uuid must be lowercase letters and digits" >&2; exit 3; }
[[ "$WAIT_S" =~ ^[0-9]+$ ]] || { echo "--wait must be a number of seconds" >&2; exit 3; }
DIR=${DIR:-/data/coolify/services/$UUID}
[ -f "$DIR/docker-compose.yml" ] || { echo "no $DIR/docker-compose.yml" >&2; exit 3; }

log() { printf '%s %s\n' "$(date -u +%H:%M:%SZ)" "$*"; }
refuse() { log "REFUSED: $*"; exit 1; }
C=(docker compose --project-directory "$DIR" -p "$UUID" -f "$DIR/docker-compose.yml")

if [ -z "${SAFE_RECREATE_ROOT:-}" ] && [ "$(id -u)" -ne 0 ]; then
  echo "run as root (the run records go to /root/safe-recreate), or set SAFE_RECREATE_ROOT to a writable directory" >&2
  exit 3
fi
RUN_DIR="${SAFE_RECREATE_ROOT:-/root/safe-recreate}/$(date -u +%Y%m%dT%H%M%SZ)-$SERVICE"
mkdir -p "$RUN_DIR"
log "run dir: $RUN_DIR"

# --- 1. find the container and record its networks ------------------------------------------------------
cid=$("${C[@]}" ps -q "$SERVICE" 2>/dev/null | head -n 1)
[ -n "$cid" ] || refuse "no running container for service '$SERVICE' in project $UUID"
cname=$(docker inspect -f '{{.Name}}' "$cid" | sed 's#^/##')
old_short=${cid:0:12}
log "container: $cname ($old_short)"

docker inspect -f '{{range $n, $v := .NetworkSettings.Networks}}{{$n}}{{"\t"}}{{join $v.Aliases ","}}{{"\n"}}{{end}}' "$cid" \
  | sed '/^$/d' >"$RUN_DIR/networks.tsv"
log "networks before:"
sed 's/^/    /' "$RUN_DIR/networks.tsv"
grep -q '^coolify	' "$RUN_DIR/networks.tsv" || log "note: the container is not on 'coolify' now (drift, or not needed by this service)"
proxy_net=$(docker inspect -f '{{index .Config.Labels "traefik.docker.network"}}' "$cid" 2>/dev/null || true)
[ -z "$proxy_net" ] || log "traefik.docker.network label: $proxy_net"

# --- 2. image drift --------------------------------------------------------------------------------------
running_image=$(docker inspect -f '{{.Config.Image}}' "$cid")
file_image=$("${C[@]}" config --images "$SERVICE" 2>/dev/null | head -n 1)
log "image running: $running_image"
log "image in file: $file_image"
if [ "$file_image" != "$running_image" ]; then
  if [ -z "$EXPECT_IMAGE" ] || [ "$file_image" != "$EXPECT_IMAGE" ]; then
    refuse "the compose file names a different image; pass --expect-image '$file_image' if that change is intended"
  fi
  log "image change expected: $running_image -> $file_image"
fi

# --- 3. dry-run gate -------------------------------------------------------------------------------------
"${C[@]}" --dry-run up -d --no-deps --force-recreate "$SERVICE" >"$RUN_DIR/dry-run.txt" 2>&1 \
  || refuse "compose --dry-run failed: see $RUN_DIR/dry-run.txt"
# Lines look like: "DRY-RUN MODE -  Container <name>  Recreate". Count the exact Recreate line for this
# container, and any Container/Network/Volume line about something else (Compose also names the old
# container "<short id>_<name>" while it swaps them; that counts as this container).
recreates=$(awk -v c="$cname" '{for (i = 1; i < NF; i++) if ($i == "Container" && $(i+1) == c && $NF == "Recreate" && i + 2 == NF) n++} END {print n + 0}' "$RUN_DIR/dry-run.txt")
others=$(awk -v c="$cname" '{
  for (i = 1; i < NF; i++) if ($i == "Container" || $i == "Network" || $i == "Volume") {
    o = $(i+1); self = ($i == "Container") && (o == c || (length(o) > length(c) && substr(o, length(o) - length(c)) == "_" c))
    if (!self) n++
    break
  }
} END {print n + 0}' "$RUN_DIR/dry-run.txt")
[ "$recreates" -eq 1 ] && [ "$others" -eq 0 ] \
  || refuse "the dry run touches more than '$cname' (or nothing): see $RUN_DIR/dry-run.txt"
log "dry run: only $cname is recreated"

if [ "$APPLY" != true ]; then
  log "DRY RUN OK. Re-run with --apply to recreate."
  exit 0
fi

# --- 4. recreate -----------------------------------------------------------------------------------------
log "recreating $SERVICE"
"${C[@]}" up -d --no-deps --force-recreate "$SERVICE" >"$RUN_DIR/up.txt" 2>&1 || {
  log "compose up failed: see $RUN_DIR/up.txt"; exit 2; }
new_cid=$("${C[@]}" ps -q "$SERVICE" | head -n 1)
[ -n "$new_cid" ] || { log "no container after up"; exit 2; }

has_health=$(docker inspect -f '{{if .State.Health}}yes{{end}}' "$new_cid")
if [ "$has_health" = yes ]; then
  deadline=$((SECONDS + WAIT_S))
  while :; do
    st=$(docker inspect -f '{{.State.Health.Status}}' "$new_cid")
    [ "$st" = healthy ] && break
    [ $SECONDS -lt $deadline ] || { log "not healthy after ${WAIT_S}s (status $st)"; break; }
    sleep 3
  done
  log "health: $(docker inspect -f '{{.State.Health.Status}}' "$new_cid")"
fi

# --- 5. reattach missing networks ------------------------------------------------------------------------
fail=0
while IFS=$'\t' read -r net aliases; do
  [ -n "$net" ] || continue
  if docker inspect -f "{{if index .NetworkSettings.Networks \"$net\"}}yes{{end}}" "$new_cid" | grep -q yes; then
    log "network $net: kept"
    continue
  fi
  args=()
  IFS=',' read -r -a list <<<"$aliases"
  for a in "${list[@]+"${list[@]}"}"; do
    # Skip the old container's short id and the container name: Docker adds those itself.
    [[ "$a" == "$old_short" || "$a" == "$cname" || "$a" =~ ^[0-9a-f]{12}$ ]] && continue
    [ -n "$a" ] && args+=(--alias "$a")
  done
  log "network $net: MISSING, reconnecting with $(( ${#args[@]} / 2 )) alias(es)"
  if docker network connect "${args[@]+"${args[@]}"}" "$net" "$new_cid"; then
    log "network $net: reconnected"
  else
    log "network $net: reconnect FAILED"; fail=1
  fi
done <"$RUN_DIR/networks.tsv"

docker inspect -f '{{range $n, $v := .NetworkSettings.Networks}}{{$n}}{{"\t"}}{{join $v.Aliases ","}}{{"\n"}}{{end}}' "$new_cid" \
  | sed '/^$/d' >"$RUN_DIR/networks.after.tsv"
log "networks after:"
sed 's/^/    /' "$RUN_DIR/networks.after.tsv"

# --- 6. bind files readable inside the container (best effort) --------------------------------------------
while IFS= read -r dest; do
  [ -n "$dest" ] || continue
  if out=$(docker exec "$new_cid" sh -c 'test ! -f "$1" || test -r "$1"' sh "$dest" 2>&1); then
    log "bind $dest: readable"
  elif printf '%s' "$out" | grep -qiE 'executable file not found|no such file or directory'; then
    log "bind $dest: not checked (no shell in this image)"
  else
    log "bind $dest: NOT READABLE as the container user (check the host file's mode and owner)"; fail=1
  fi
done < <(docker inspect -f '{{range .Mounts}}{{if eq .Type "bind"}}{{.Destination}}{{"\n"}}{{end}}{{end}}' "$new_cid")

# --- 7. probe --------------------------------------------------------------------------------------------
if [ -n "$PROBE_URL" ]; then
  ok=false
  for _ in $(seq 1 20); do
    code=$(curl -s -o /dev/null -m 5 -w '%{http_code}' "$PROBE_URL" || true)
    case "$code" in 2??) ok=true; break ;; esac
    sleep 3
  done
  if [ "$ok" = true ]; then log "probe: $code"; else log "probe: FAILED (last status $code)"; fail=1; fi
fi

if [ "$fail" -ne 0 ]; then
  log "CHECKS FAILED. Inspect: docker logs --since 5m $new_cid; compare $RUN_DIR/networks.tsv and networks.after.tsv."
  log "Roll back by restoring your saved compose/.env/bind files and running this script again."
  exit 2
fi
log "DONE: $SERVICE recreated, networks match the record."
