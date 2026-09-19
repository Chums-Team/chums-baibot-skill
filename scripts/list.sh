# list.sh - instances on the host, with their ref and container states.
# Read-only. Usage (through run.sh): run.sh list [--target T] [--root DIR]

list_main() {
  parse_common_args "$@"
  [ -d "$CB_ROOT" ] || { log "no instances root at $CB_ROOT"; return 0; }
  local f d name ref bot side
  printf '%-16s %-12s %-16s %-16s %-6s %s\n' INSTANCE REF BOT SIDECAR PORT NETWORK
  for f in "$CB_ROOT"/*/instance.env; do
    [ -f "$f" ] || continue
    d=$(dirname "$f"); name=$(basename "$d")
    (
      CB_INSTANCE=$name; CB_DIR=$d
      load_instance
      ref=$(git -C "$d" rev-parse --short HEAD 2>/dev/null || printf 'no-git')
      bot=$(container_state "$BOT_CONTAINER_NAME")
      side=$(container_state "$SIDECAR_CONTAINER_NAME")
      printf '%-16s %-12s %-16s %-16s %-6s %s\n' "$name" "$ref" "$bot" "$side" "$SIDECAR_HOST_PORT" "$CHUMS_NETWORK"
    )
  done
  return 0
}

list_main "$@"
