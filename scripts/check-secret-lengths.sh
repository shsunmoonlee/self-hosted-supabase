#!/usr/bin/env bash
# check-secret-lengths.sh: print the NAME and LENGTH of every variable in a compose .env file, and flag the
# ones that are empty or too short for what the compose file feeds them into. Values are never printed.
#
# Usage:
#   bash check-secret-lengths.sh <path/to/.env> [path/to/docker-compose.yml] [NAME=MIN ...]
#
# Examples:
#   bash check-secret-lengths.sh /data/coolify/services/<service-uuid>/.env \
#        /data/coolify/services/<service-uuid>/docker-compose.yml
#   bash check-secret-lengths.sh ./.env ./docker-compose.yml SERVICE_PASSWORD_JWT=32
#
# Built-in rules:
#   - any variable whose name contains PASSWORD, SECRET, KEY or TOKEN must not be empty;
#   - SERVICE_PASSWORD_64_* must be at least 64 characters;
#   - with a compose file: every variable interpolated into SECRET_KEY_BASE (Realtime, Supavisor) must be at
#     least 64 characters (Phoenix refuses a shorter cookie secret), and every variable the compose file
#     references must exist in the .env.
# Extra NAME=MIN arguments add minimum lengths.
#
# Exit codes: 0 all checks pass, 1 at least one FAIL, 2 usage error.
# The script also warns when the .env has no trailing newline (a later `>>` append would glue two lines).

set -euo pipefail
[ "${BASH_VERSINFO[0]}" -ge 4 ] || { echo "needs bash 4 or newer (associative arrays)" >&2; exit 2; }

[ $# -ge 1 ] || { sed -n '2,22p' "$0"; exit 2; }
ENV_FILE=$1; shift
COMPOSE_FILE=""
if [ $# -ge 1 ] && [[ "$1" != *=* ]]; then COMPOSE_FILE=$1; shift; fi
[ -r "$ENV_FILE" ] || { echo "cannot read $ENV_FILE" >&2; exit 2; }
[ -z "$COMPOSE_FILE" ] || [ -r "$COMPOSE_FILE" ] || { echo "cannot read $COMPOSE_FILE" >&2; exit 2; }

declare -A LEN=()
declare -A MIN=()
declare -A WHY=()
ORDER=()

add_min() {
  local name=$1 min=$2 why=$3
  if [ -z "${MIN[$name]:-}" ] || [ "$min" -gt "${MIN[$name]}" ]; then
    MIN[$name]=$min
    WHY[$name]=$why
  fi
}

# Parse NAME=value lines. Values are only measured, never echoed. Surrounding single or double quotes are
# not counted. The last line is read even without a trailing newline.
while IFS= read -r line || [ -n "$line" ]; do
  line=${line%$'\r'}
  case "$line" in ''|'#'*) continue ;; esac
  [[ "$line" == *=* ]] || continue
  name=${line%%=*}
  name=${name#export }
  name=${name//[[:space:]]/}
  [[ "$name" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
  value=${line#*=}
  if [[ ${#value} -ge 2 && ( "$value" == \"*\" || "$value" == \'*\' ) ]]; then
    value=${value:1:${#value}-2}
  fi
  [ -n "${LEN[$name]+x}" ] || ORDER+=("$name")
  LEN[$name]=${#value}
  unset value
done <"$ENV_FILE"

if [ -s "$ENV_FILE" ] && [ "$(tail -c 1 "$ENV_FILE" | od -An -c | tr -d ' ')" != '\n' ]; then
  printf '%s\n' "WARN  $ENV_FILE has no trailing newline: start any append with a newline (printf '\\nNAME=...')."
fi

for name in "${ORDER[@]}"; do
  case "$name" in
    SERVICE_PASSWORD_64_*) add_min "$name" 64 "SERVICE_PASSWORD_64_* is meant to be 64 characters" ;;
    *PASSWORD*|*SECRET*|*KEY*|*TOKEN*) add_min "$name" 1 "secret-like name" ;;
  esac
done

for arg in "$@"; do
  [[ "$arg" =~ ^([A-Za-z_][A-Za-z0-9_]*)=([0-9]+)$ ]] || { echo "bad rule: $arg (expected NAME=MIN)" >&2; exit 2; }
  add_min "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "rule given on the command line"
done

MISSING=()
if [ -n "$COMPOSE_FILE" ]; then
  # SECRET_KEY_BASE=${VAR} / SECRET_KEY_BASE: ${VAR} / with or without quotes and a :-default.
  while IFS= read -r var; do
    [ -n "$var" ] && add_min "$var" 64 "interpolated into SECRET_KEY_BASE in $(basename "$COMPOSE_FILE")"
  done < <(grep -oE 'SECRET_KEY_BASE[[:space:]]*[:=][[:space:]]*["'\'']?\$\{[A-Za-z_][A-Za-z0-9_]*' "$COMPOSE_FILE" \
             | sed -E 's/.*\$\{//' | sort -u)
  while IFS= read -r var; do
    [ -n "$var" ] || continue
    [ -n "${LEN[$var]+x}" ] || MISSING+=("$var")
  done < <(grep -oE '\$\{[A-Za-z_][A-Za-z0-9_]*' "$COMPOSE_FILE" | sed 's/^\${//' | sort -u)
fi

fail=0
printf '%-6s %-44s %6s %6s  %s\n' STATUS NAME LENGTH MIN WHY
for name in "${ORDER[@]}"; do
  len=${LEN[$name]}
  min=${MIN[$name]:-0}
  status=ok
  if [ "$len" -lt "$min" ]; then status=FAIL; fail=1; fi
  printf '%-6s %-44s %6s %6s  %s\n' "$status" "$name" "$len" "$min" "${WHY[$name]:-}"
done
for name in "${!MIN[@]}"; do
  if [ -z "${LEN[$name]+x}" ]; then
    printf '%-6s %-44s %6s %6s  %s\n' FAIL "$name" absent "${MIN[$name]}" "${WHY[$name]}"
    fail=1
  fi
done
for name in "${MISSING[@]+"${MISSING[@]}"}"; do
  [ -n "${MIN[$name]+x}" ] && continue
  printf '%-6s %-44s %6s %6s  %s\n' WARN "$name" absent - "referenced in the compose file, not in the .env (fine if it has a :-default)"
done

exit "$fail"
