# remove.sh - stop and delete the containers and the network of an instance.
#
# The instance directory (checkout, data/, .env files, config.yml) is kept and
# its path is printed; deleting it is a manual decision.
#
# Usage (through run.sh): run.sh remove --instance NAME [--dry-run]

remove_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  log "remove $CB_INSTANCE: containers $BOT_CONTAINER_NAME, $SIDECAR_CONTAINER_NAME; network $CHUMS_NETWORK"
  if [ -f "$CB_DIR/.env" ] && [ -f "$CB_DIR/config.yml" ]; then
    run compose_bot down --remove-orphans
  elif [ "$(container_state "$BOT_CONTAINER_NAME")" != absent ]; then
    run docker rm -f "$BOT_CONTAINER_NAME"
  else
    skip "bot container absent"
  fi
  if [ -f "$CB_DIR/x402-sidecar/.env" ]; then
    run compose_sidecar down --remove-orphans
  elif [ "$(container_state "$SIDECAR_CONTAINER_NAME")" != absent ]; then
    run docker rm -f "$SIDECAR_CONTAINER_NAME"
  else
    skip "sidecar container absent"
  fi
  if docker network inspect "$CHUMS_NETWORK" >/dev/null 2>&1; then
    local n; n=$(docker network inspect -f '{{len .Containers}}' "$CHUMS_NETWORK")
    if [ "$n" = 0 ] || [ "$CB_DRY_RUN" = 1 ]; then
      run docker network rm "$CHUMS_NETWORK"
    else
      warn "network $CHUMS_NETWORK still has $n container(s); left in place"
    fi
  else
    skip "network $CHUMS_NETWORK absent"
  fi
  log "instance directory kept: $CB_DIR (data/, .env files, config.yml, checkout); delete it by hand if the instance is gone for good"
}

remove_main "$@"
