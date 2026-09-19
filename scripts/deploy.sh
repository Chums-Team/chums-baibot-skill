# deploy.sh - create (or converge) an instance on the host from a profile.
#
# run.sh runs `profile check` first, uploads the four profile files into
# $ROOT/.incoming/<instance>/ and then streams this script with the expected
# hashes. Every step is check-then-act, so a second deploy changes nothing.
#
# Steps: root dir, git clone at the wanted ref, instance.env, .env,
# x402-sidecar/.env, config.yml, data dirs, network, sidecar up, bot up.
# Health is a separate operation; run.sh runs it afterwards.
#
# Usage (through run.sh): run.sh deploy --profile NAME [--dry-run]

deploy_main() {
  parse_common_args "$@"
  parse_expect_args "${CB_ARGS[@]+"${CB_ARGS[@]}"}"
  need_instance
  require_tool docker; require_tool git
  local stage; stage=$(stage_dir)

  # The instance settings come from the staged instance.env (new instance) or
  # from the one already on the host.
  if [ -f "$CB_DIR/instance.env" ]; then
    load_instance
  elif [ -f "$stage/instance.env" ]; then
    load_instance_env_file "$stage/instance.env"
  elif [ "$CB_DRY_RUN" = 1 ]; then
    instance_defaults
    info "dry-run: instance settings taken from the profile (--set), nothing is on the host yet"
  else
    die "no instance.env on the host or in $stage"
  fi
  log "deploy $CB_INSTANCE -> $CB_DIR (ref $BAIBOT_GIT_REF, network $CHUMS_NETWORK)"

  # 1. root
  if [ -d "$CB_ROOT" ]; then skip "root $CB_ROOT exists"; else run mkdir -p "$CB_ROOT"; fi

  # 2. checkout
  if [ -d "$CB_DIR/.git" ]; then
    local head want
    head=$(git -C "$CB_DIR" rev-parse HEAD)
    if [ "$CB_DRY_RUN" = 0 ]; then git -C "$CB_DIR" fetch -q origin 2>/dev/null || warn "git fetch failed (offline?)"; fi
    want=$(git -C "$CB_DIR" rev-parse "origin/$BAIBOT_GIT_REF" 2>/dev/null || git -C "$CB_DIR" rev-parse "$BAIBOT_GIT_REF" 2>/dev/null || true)
    if [ -n "$want" ] && [ "$head" != "$want" ]; then
      warn "checkout is at ${head:0:7}, profile wants $BAIBOT_GIT_REF (${want:0:7}); deploy does not switch, run update"
    else
      skip "checkout at ${head:0:7} ($BAIBOT_GIT_REF)"
    fi
  elif [ -e "$CB_DIR" ] && [ -n "$(ls -A "$CB_DIR" 2>/dev/null)" ]; then
    die "$CB_DIR exists, is not empty and is not a git checkout; remove it or pick another name"
  else
    run git clone -q "$BAIBOT_GIT_URL" "$CB_DIR"
    if [ "$CB_DRY_RUN" = 0 ]; then
      git -C "$CB_DIR" checkout -q "$BAIBOT_GIT_REF" || die "ref not found in $BAIBOT_GIT_URL: $BAIBOT_GIT_REF"
      log "checked out $BAIBOT_GIT_REF at $(git -C "$CB_DIR" rev-parse --short HEAD)"
    else
      log "would check out $BAIBOT_GIT_REF"
    fi
  fi

  # 3. files from the profile
  local restart_bot=0 restart_side=0
  sync_staged instance.env "$CB_DIR/instance.env" 644 "$EXPECT_INSTANCE_ENV"
  [ "$CB_CHANGED" = 1 ] && { restart_bot=1; restart_side=1; }
  sync_staged bot.env "$CB_DIR/.env" 600 "$EXPECT_BOT_ENV"
  [ "$CB_CHANGED" = 1 ] && restart_bot=1
  sync_staged sidecar.env "$CB_DIR/x402-sidecar/.env" 600 "$EXPECT_SIDECAR_ENV"
  [ "$CB_CHANGED" = 1 ] && restart_side=1
  sync_staged config.yml "$CB_DIR/config.yml" 644 "$EXPECT_CONFIG_YML"
  [ "$CB_CHANGED" = 1 ] && restart_bot=1
  [ "$CB_DRY_RUN" = 1 ] || rmdir "$stage" 2>/dev/null || true

  # 4. data dirs, owned by the ssh user (UID/GID in the env files must match)
  local d
  for d in data x402-sidecar/data; do
    if [ -d "$CB_DIR/$d" ]; then skip "$d/ exists (owner $(file_owner "$CB_DIR/$d"))"; else run mkdir -p "$CB_DIR/$d"; fi
  done
  if [ -f "$CB_DIR/.env" ] && [ -d "$CB_DIR/data" ]; then
    local uid gid
    uid=$(env_value "$CB_DIR/.env" UID); gid=$(env_value "$CB_DIR/.env" GID)
    [ "$(file_owner "$CB_DIR/data")" = "$uid:$gid" ] || warn "data/ owner $(file_owner "$CB_DIR/data") is not UID:GID $uid:$gid of .env; the bot cannot write its store (fix ownership by hand)"
  fi

  # 5. network
  if docker network inspect "$CHUMS_NETWORK" >/dev/null 2>&1; then
    skip "network $CHUMS_NETWORK exists"
  else
    run docker network create "$CHUMS_NETWORK"
  fi

  # 6. containers
  if [ "$CB_DRY_RUN" = 1 ]; then
    log "would run: docker compose up -d --build (sidecar, project $CB_INSTANCE-x402)"
    log "would run: docker compose pull && docker compose up -d (bot, project $CB_INSTANCE; falls back to a local build when the pull fails)"
    [ "$restart_side" = 1 ] && log "sidecar container would be recreated (its .env changes)"
    [ "$restart_bot" = 1 ] && log "bot container would be recreated/restarted (its files change)"
    log "dry-run complete; nothing changed"
    return 0
  fi
  [ -f "$CB_DIR/x402-sidecar/.env" ] || die "x402-sidecar/.env missing on the host"
  if [ ! -f "$CB_DIR/.env" ] || [ ! -f "$CB_DIR/config.yml" ]; then die ".env or config.yml missing on the host"; fi
  run compose_sidecar up -d --build
  if ! compose_bot pull -q 2>/dev/null; then
    warn "pull of ${BOT_IMAGE:-the bot image} failed; building locally (a Rust release build, about ten minutes)"
    run compose_bot up -d --build
  else
    run compose_bot up -d
  fi
  # compose recreates on env_file changes but not on a bind-mounted config.yml change
  if [ "$restart_bot" = 1 ] && [ "$(container_state "$BOT_CONTAINER_NAME")" = running ]; then
    run compose_bot restart bot
  fi
  log "deploy $CB_INSTANCE: done; run health next"
}

deploy_main "$@"
