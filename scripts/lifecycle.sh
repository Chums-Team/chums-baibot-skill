# lifecycle.sh - start, stop or restart the pair of containers of an instance.
#
# Order: start brings up the sidecar, then the bot; stop takes down the bot,
# then the sidecar; restart is stop followed by start.
#
# Usage (through run.sh): run.sh start|stop|restart --instance NAME [--dry-run]

lifecycle_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  local action=${CB_ARGS[0]:-}
  case "$action" in
    start)
      run compose_sidecar start
      run compose_bot start ;;
    stop)
      run compose_bot stop
      run compose_sidecar stop ;;
    restart)
      run compose_bot stop
      run compose_sidecar stop
      run compose_sidecar start
      run compose_bot start ;;
    *) die "usage: lifecycle start|stop|restart" ;;
  esac
  log "$action $CB_INSTANCE: bot=$(container_state "$BOT_CONTAINER_NAME") sidecar=$(container_state "$SIDECAR_CONTAINER_NAME")"
}

lifecycle_main "$@"
