# backup.sh - consistent copy of an instance's state into a directory on the host.
#
# Writes $ROOT/backups/<instance>-<UTC timestamp>/ (mode 700) with:
#   billing.db          via `sqlite3 .backup` inside the bot container
#   sidecar.db          via Python's sqlite3 backup inside the sidecar container
#   data/               the bot's session and crypto store (cp -a; consistent
#                       only with --stop, which stops the bot for the copy)
#   env/.env, env/sidecar.env, config.yml, instance.env
# The path is printed at the end; the archive stays on the host.
#
# Usage (through run.sh): run.sh backup --instance NAME [--stop] [--dry-run]

backup_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  local stop=0 a
  for a in "${CB_ARGS[@]+"${CB_ARGS[@]}"}"; do
    case "$a" in --stop) stop=1 ;; *) die "unknown argument: $a" ;; esac
  done
  local ts dest
  ts=$(date -u +%Y%m%dT%H%M%SZ)
  dest="$CB_ROOT/backups/$CB_INSTANCE-$ts"
  log "backup $CB_INSTANCE -> $dest"
  if [ "$CB_DRY_RUN" = 1 ]; then
    local how="cp -a while the bot runs"; [ "$stop" = 1 ] && how="cp -a with the bot stopped"
    log "would create $dest with billing.db (sqlite backup), sidecar.db (sqlite backup), data/ ($how), both .env files, config.yml, instance.env"
    log "dry-run complete; nothing changed"
    return 0
  fi
  (umask 077; mkdir -p "$dest/env")
  chmod 700 "$dest"

  if [ "$(container_state "$BOT_CONTAINER_NAME")" = running ]; then
    if docker exec "$BOT_CONTAINER_NAME" test -f /data/billing.db 2>/dev/null; then
      if docker exec "$BOT_CONTAINER_NAME" sqlite3 /data/billing.db ".backup /tmp/billing.db" \
        && docker cp -q "$BOT_CONTAINER_NAME:/tmp/billing.db" "$dest/billing.db" \
        && docker exec "$BOT_CONTAINER_NAME" rm -f /tmp/billing.db; then
        log "billing.db: sqlite backup"
      else
        warn "billing.db: backup failed"
      fi
    else
      log "billing.db: none yet"
    fi
  else
    [ -f "$CB_DIR/data/billing.db" ] && cp -a "$CB_DIR/data/billing.db" "$dest/billing.db" && log "billing.db: plain copy (bot not running)"
  fi
  if [ "$(container_state "$SIDECAR_CONTAINER_NAME")" = running ]; then
    if docker exec "$SIDECAR_CONTAINER_NAME" python3 -c 'import sqlite3; s=sqlite3.connect("/app/data/sidecar.db"); d=sqlite3.connect("/tmp/sidecar.db"); s.backup(d); d.close(); s.close()' 2>/dev/null \
      && docker cp -q "$SIDECAR_CONTAINER_NAME:/tmp/sidecar.db" "$dest/sidecar.db" \
      && docker exec "$SIDECAR_CONTAINER_NAME" rm -f /tmp/sidecar.db; then
      log "sidecar.db: sqlite backup"
    else
      warn "sidecar.db: backup failed (no database yet?)"
    fi
  else
    [ -f "$CB_DIR/x402-sidecar/data/sidecar.db" ] && cp -a "$CB_DIR/x402-sidecar/data/sidecar.db" "$dest/sidecar.db" && log "sidecar.db: plain copy (sidecar not running)"
  fi

  if [ "$stop" = 1 ]; then
    run compose_bot stop
  else
    warn "data/ copied while the bot runs: the session store may be inconsistent; use --stop for a clean copy"
  fi
  cp -a "$CB_DIR/data" "$dest/data" && log "data/: copied"
  [ "$stop" = 1 ] && run compose_bot start

  local f
  for f in .env x402-sidecar/.env config.yml instance.env; do
    [ -f "$CB_DIR/$f" ] || continue
    case "$f" in
      .env) install -m 600 "$CB_DIR/$f" "$dest/env/.env" ;;
      x402-sidecar/.env) install -m 600 "$CB_DIR/$f" "$dest/env/sidecar.env" ;;
      *) install -m 600 "$CB_DIR/$f" "$dest/$f" ;;
    esac
  done
  chmod -R go-rwx "$dest"
  log "backup written: $dest"
  du -sh "$dest" 2>/dev/null | awk '{print "info  size: " $1}'
}

backup_main "$@"
