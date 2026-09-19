# apply.sh - push the profile to an existing instance and restart what changed.
#
# This is the "configure" operation: config.yml, .env and the sidecar's .env
# are edited in the profile and land on the host here. Files whose hash equals
# the profile's are skipped. The sidecar is recreated when its .env changed;
# the bot when .env or config.yml changed; both when instance.env changed.
#
# Usage (through run.sh): run.sh apply --profile NAME [--dry-run]

apply_main() {
  parse_common_args "$@"
  parse_expect_args "${CB_ARGS[@]+"${CB_ARGS[@]}"}"
  need_instance
  require_tool docker
  [ -f "$CB_DIR/instance.env" ] || die "instance $CB_INSTANCE is not deployed ($CB_DIR); run deploy"
  load_instance
  log "apply profile -> $CB_INSTANCE at $CB_DIR"
  local stage; stage=$(stage_dir)

  local restart_bot=0 restart_side=0 names_changed=0
  local old_bot=$BOT_CONTAINER_NAME old_side=$SIDECAR_CONTAINER_NAME old_net=$CHUMS_NETWORK
  sync_staged instance.env "$CB_DIR/instance.env" 644 "$EXPECT_INSTANCE_ENV"
  if [ "$CB_CHANGED" = 1 ]; then
    restart_bot=1; restart_side=1
    if [ "$CB_DRY_RUN" = 0 ]; then
      load_instance
      [ "$old_bot" != "$BOT_CONTAINER_NAME" ] || [ "$old_side" != "$SIDECAR_CONTAINER_NAME" ] || [ "$old_net" != "$CHUMS_NETWORK" ] && names_changed=1
    fi
  fi
  sync_staged bot.env "$CB_DIR/.env" 600 "$EXPECT_BOT_ENV"
  [ "$CB_CHANGED" = 1 ] && restart_bot=1
  sync_staged sidecar.env "$CB_DIR/x402-sidecar/.env" 600 "$EXPECT_SIDECAR_ENV"
  [ "$CB_CHANGED" = 1 ] && restart_side=1
  sync_staged config.yml "$CB_DIR/config.yml" 644 "$EXPECT_CONFIG_YML"
  [ "$CB_CHANGED" = 1 ] && restart_bot=1
  [ "$CB_DRY_RUN" = 1 ] || rmdir "$stage" 2>/dev/null || true

  if [ "$restart_bot" = 0 ] && [ "$restart_side" = 0 ]; then
    log "nothing to apply: host matches the profile"
    return 0
  fi
  if [ "$CB_DRY_RUN" = 1 ]; then
    [ "$restart_side" = 1 ] && log "would recreate the sidecar (docker compose up -d)"
    [ "$restart_bot" = 1 ] && log "would recreate/restart the bot (docker compose up -d; restart when only config.yml changed)"
    log "dry-run complete; nothing changed"
    return 0
  fi
  if [ "$names_changed" = 1 ]; then
    warn "instance.env changed container or network names; compose recreates the containers under the new names"
    docker network inspect "$CHUMS_NETWORK" >/dev/null 2>&1 || run docker network create "$CHUMS_NETWORK"
  fi
  # Order: sidecar first, then the bot, as in the runbook.
  if [ "$restart_side" = 1 ]; then
    run compose_sidecar up -d
  fi
  if [ "$restart_bot" = 1 ]; then
    run compose_bot up -d
    # `up -d` is a no-op when only the bind-mounted config.yml changed
    run compose_bot restart bot
  fi
  log "apply $CB_INSTANCE: done; run health next"
}

apply_main "$@"
