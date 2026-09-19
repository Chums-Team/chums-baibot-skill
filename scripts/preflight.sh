# preflight.sh - read-only check of a host before any other operation.
#
# Streamed to the host by run.sh after lib.sh. Checks the tools, the docker
# daemon and its compose plugin, the reachability of the image registry and of
# the baibot repository, and the instances root. Changes nothing.
#
# Usage (through run.sh): run.sh preflight [--target T] [--root DIR]

preflight_main() {
  parse_common_args "$@"
  local fails=0
  ok()   { printf 'PASS  %s\n' "$*"; }
  bad()  { printf 'FAIL  %s\n' "$*"; fails=$((fails + 1)); }
  note() { printf 'WARN  %s\n' "$*"; }

  log "host: $(hostname) user: $(id -un) uid: $(id -u)"
  log "tools:"
  local t
  for t in bash docker curl git openssl sha256sum awk sed install mktemp; do
    if command -v "$t" >/dev/null 2>&1; then ok "$t"; else bad "$t not found"; fi
  done
  ok "bash ${BASH_VERSION%%(*}"
  if command -v sqlite3 >/dev/null 2>&1; then ok "sqlite3 on the host (optional)"; else note "sqlite3 not on the host (fine: the bot image ships it)"; fi

  log "docker:"
  local v
  if v=$(docker info --format '{{.ServerVersion}}' 2>/dev/null); then
    ok "docker daemon reachable, server $v"
  else
    bad "docker daemon not reachable as $(id -un) (docker group membership?)"
  fi
  if v=$(docker compose version --short 2>/dev/null); then
    ok "docker compose plugin $v"
  else
    bad "docker compose plugin missing"
  fi

  log "network:"
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 https://ghcr.io/v2/ || true)
  if [ "$code" != "000" ] && [ -n "$code" ]; then ok "ghcr.io reachable (HTTP $code)"; else bad "ghcr.io not reachable"; fi
  if git ls-remote --heads "$CB_DEFAULT_GIT_URL" "$CB_DEFAULT_GIT_REF" >/dev/null 2>&1; then
    ok "$CB_DEFAULT_GIT_URL reachable"
  else
    bad "$CB_DEFAULT_GIT_URL not reachable with git"
  fi

  log "instances root: $CB_ROOT"
  if [ -d "$CB_ROOT" ]; then
    if [ -w "$CB_ROOT" ]; then ok "exists and writable"; else bad "exists but not writable"; fi
    local n; n=$(find "$CB_ROOT" -mindepth 2 -maxdepth 2 -name instance.env 2>/dev/null | wc -l)
    ok "$n instance(s) found"
  else
    local parent; parent=$(dirname "$CB_ROOT")
    if [ -w "$parent" ]; then ok "missing; deploy creates it under $parent"; else bad "missing and $parent not writable"; fi
  fi
  local probe=$CB_ROOT
  [ -d "$probe" ] || probe=$(dirname "$CB_ROOT")
  { df -h "$probe" 2>/dev/null || true; } | tail -n 1 | awk 'NF >= 6 {print "info  disk: " $4 " free on " $6}'

  if [ "$fails" = 0 ]; then log "preflight: OK"; return 0; fi
  log "preflight: $fails problem(s)"
  return 1
}

preflight_main "$@"
