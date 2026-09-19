# inspect.sh - full state of one instance on the host. Read-only.
#
# Usage (through run.sh): run.sh inspect --instance NAME [--target T] [--root DIR]
# With --profile, run.sh adds --expect FILE=SHA for the four profile files and
# this script reports the drift between the profile and the host by hash.

inspect_main() {
  parse_common_args "$@"
  parse_expect_args "${CB_ARGS[@]+"${CB_ARGS[@]}"}"
  need_instance
  if [ ! -f "$CB_DIR/instance.env" ]; then
    log "instance $CB_INSTANCE: not deployed ($CB_DIR has no instance.env)"
    return 0
  fi
  load_instance
  log "instance $CB_INSTANCE at $CB_DIR (target: ${TARGET:-?})"

  log "source:"
  if [ -d "$CB_DIR/.git" ]; then
    local head branch url
    head=$(git -C "$CB_DIR" rev-parse --short HEAD 2>/dev/null)
    branch=$(git -C "$CB_DIR" rev-parse --abbrev-ref HEAD 2>/dev/null)
    url=$(git -C "$CB_DIR" remote get-url origin 2>/dev/null || true)
    printf '  HEAD %s (%s), wanted ref %s, origin %s\n' "$head" "$branch" "$BAIBOT_GIT_REF" "$url"
    local dirty; dirty=$(git -C "$CB_DIR" status --porcelain 2>/dev/null | wc -l)
    if [ "$dirty" = 0 ]; then log "  working tree clean"; else warn "working tree has $dirty modified or untracked entries"; fi
  else
    log "  no git checkout"
  fi

  log "containers:"
  local c st rc started img
  for c in "$BOT_CONTAINER_NAME" "$SIDECAR_CONTAINER_NAME"; do
    st=$(container_state "$c")
    if [ "$st" = absent ]; then printf '  %-28s absent\n' "$c"; continue; fi
    rc=$(container_field "$c" '{{.RestartCount}}')
    started=$(container_field "$c" '{{.State.StartedAt}}')
    img=$(container_field "$c" '{{.Config.Image}}')
    printf '  %-28s %-10s restarts=%-3s started=%s image=%s\n' "$c" "$st" "$rc" "$started" "$img"
  done
  log "images:"
  local i digest
  for i in "${BOT_IMAGE:-ghcr.io/chums-team/baibot:chums}" "${SIDECAR_IMAGE:-chums-x402-sidecar:0.2.0}"; do
    digest=$(docker image inspect -f '{{if .RepoDigests}}{{index .RepoDigests 0}}{{else}}{{.Id}}{{end}}' "$i" 2>/dev/null || printf 'not pulled/built')
    printf '  %-40s %s\n' "$i" "$digest"
  done
  log "network: $CHUMS_NETWORK $(docker network inspect -f 'exists, {{len .Containers}} container(s)' "$CHUMS_NETWORK" 2>/dev/null || printf 'missing')"
  log "sidecar /health port: 127.0.0.1:$SIDECAR_HOST_PORT"

  log "files:"
  local f
  for f in instance.env .env x402-sidecar/.env config.yml; do
    if [ -f "$CB_DIR/$f" ]; then
      printf '  %-22s mode=%s owner=%s\n' "$f" "$(file_mode "$CB_DIR/$f")" "$(file_owner "$CB_DIR/$f")"
    else
      printf '  %-22s missing\n' "$f"
    fi
  done
  for f in .env x402-sidecar/.env; do
    [ -f "$CB_DIR/$f" ] && [ "$(file_mode "$CB_DIR/$f")" != 600 ] && warn "$f mode is $(file_mode "$CB_DIR/$f"), want 600"
  done
  local uid gid
  for f in data x402-sidecar/data; do
    if [ -d "$CB_DIR/$f" ]; then
      printf '  %-22s owner=%s\n' "$f/" "$(file_owner "$CB_DIR/$f")"
    else
      printf '  %-22s missing\n' "$f/"
    fi
  done
  if [ -f "$CB_DIR/.env" ] && [ -d "$CB_DIR/data" ]; then
    uid=$(env_value "$CB_DIR/.env" UID); gid=$(env_value "$CB_DIR/.env" GID)
    [ "$(file_owner "$CB_DIR/data")" = "${uid:-1000}:${gid:-1000}" ] || warn "data/ owner $(file_owner "$CB_DIR/data") differs from UID:GID ${uid:-1000}:${gid:-1000} in .env"
  fi
  if [ -f "$CB_DIR/x402-sidecar/.env" ] && [ -d "$CB_DIR/x402-sidecar/data" ]; then
    uid=$(env_value "$CB_DIR/x402-sidecar/.env" UID); gid=$(env_value "$CB_DIR/x402-sidecar/.env" GID)
    [ "$(file_owner "$CB_DIR/x402-sidecar/data")" = "${uid:-1001}:${gid:-1001}" ] || warn "x402-sidecar/data/ owner $(file_owner "$CB_DIR/x402-sidecar/data") differs from UID:GID ${uid:-1001}:${gid:-1001} in x402-sidecar/.env"
  fi

  log "variables (names and states only):"
  report_env_file bot "bot .env" "$CB_DIR/.env"
  report_env_file sidecar "sidecar .env" "$CB_DIR/x402-sidecar/.env"

  log "keys the checked-out templates know and the host files do not:"
  local missing
  if [ -f "$CB_DIR/.env.example" ] && [ -f "$CB_DIR/.env" ]; then
    missing=$(comm -23 <(env_template_names "$CB_DIR/.env.example") <(env_template_names "$CB_DIR/.env"))
    if [ -z "$missing" ]; then log "  .env: none"; else log "  .env lacks: $(printf '%s' "$missing" | tr '\n' ' ')"; fi
  fi
  if [ -f "$CB_DIR/x402-sidecar/.env.example" ] && [ -f "$CB_DIR/x402-sidecar/.env" ]; then
    missing=$(comm -23 <(env_template_names "$CB_DIR/x402-sidecar/.env.example") <(env_template_names "$CB_DIR/x402-sidecar/.env"))
    if [ -z "$missing" ]; then log "  x402-sidecar/.env: none"; else log "  x402-sidecar/.env lacks: $(printf '%s' "$missing" | tr '\n' ' ')"; fi
  fi

  if [ -f "$CB_DIR/config.yml" ]; then
    local viol; viol=$(config_secret_violations "$CB_DIR/config.yml")
    if [ -z "$viol" ]; then log "config.yml: no secret values"; else warn "config.yml carries secret values at line:key $(printf '%s' "$viol" | tr '\n' ' ')"; fi
  fi

  if [ -n "$EXPECT_INSTANCE_ENV$EXPECT_BOT_ENV$EXPECT_SIDECAR_ENV$EXPECT_CONFIG_YML" ]; then
    log "drift (profile is the source of truth; apply pushes it, or update the profile by hand):"
    drift_line instance.env "$CB_DIR/instance.env" "$EXPECT_INSTANCE_ENV"
    drift_line bot.env "$CB_DIR/.env" "$EXPECT_BOT_ENV"
    drift_line sidecar.env "$CB_DIR/x402-sidecar/.env" "$EXPECT_SIDECAR_ENV"
    drift_line config.yml "$CB_DIR/config.yml" "$EXPECT_CONFIG_YML"
  fi
  return 0
}

inspect_main "$@"
