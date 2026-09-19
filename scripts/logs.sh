# logs.sh - tail of both containers' logs, optionally filtered by a payment id.
#
# Usage (through run.sh):
#   run.sh logs --instance NAME [--tail N] [--since DURATION|TIMESTAMP] [--payment-id ID] [--bot|--sidecar]
# Defaults: --tail 200, both containers. No follow mode (the call must end).

logs_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  local tail=200 since="" pid="" which=both i=0
  while [ $i -lt ${#CB_ARGS[@]} ]; do
    case "${CB_ARGS[$i]}" in
      --tail)       i=$((i + 1)); tail=${CB_ARGS[$i]} ;;
      --since)      i=$((i + 1)); since=${CB_ARGS[$i]} ;;
      --payment-id) i=$((i + 1)); pid=${CB_ARGS[$i]} ;;
      --bot)        which=bot ;;
      --sidecar)    which=sidecar ;;
      *) die "unknown argument: ${CB_ARGS[$i]}" ;;
    esac
    i=$((i + 1))
  done
  local c
  for c in "$SIDECAR_CONTAINER_NAME" "$BOT_CONTAINER_NAME"; do
    [ "$which" = bot ] && [ "$c" = "$SIDECAR_CONTAINER_NAME" ] && continue
    [ "$which" = sidecar ] && [ "$c" = "$BOT_CONTAINER_NAME" ] && continue
    log "===== $c ($(container_state "$c")) ====="
    if [ -n "$pid" ]; then
      docker logs ${since:+--since "$since"} "$c" 2>&1 | grep -F -- "$pid" | tail -n "$tail" || true
    else
      docker logs --tail "$tail" ${since:+--since "$since"} "$c" 2>&1 || true
    fi
  done
  return 0
}

logs_main "$@"
