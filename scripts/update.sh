# update.sh - move an instance to the ref of its instance.env and refresh the images.
#
# Shows the commit range and the top of CHANGELOG.md first (that is the whole
# dry-run), then: git checkout, `docker compose pull` for the bot (a local build
# when the pull fails), `up -d --build` for the sidecar, `up -d` for the bot.
# Containers whose image did not change are not recreated by compose.
#
# Usage (through run.sh): run.sh update --instance NAME [--ref REF] [--dry-run]
# --ref overrides BAIBOT_GIT_REF of instance.env for this run (and is written
# back to instance.env on the host so inspect stays truthful).

update_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  require_tool git; require_tool docker
  local ref=$BAIBOT_GIT_REF i=0
  while [ $i -lt ${#CB_ARGS[@]} ]; do
    case "${CB_ARGS[$i]}" in
      --ref) i=$((i + 1)); ref=${CB_ARGS[$i]} ;;
      *) die "unknown argument: ${CB_ARGS[$i]}" ;;
    esac
    i=$((i + 1))
  done
  [ -d "$CB_DIR/.git" ] || die "$CB_DIR is not a git checkout"

  log "update $CB_INSTANCE: $(git -C "$CB_DIR" rev-parse --short HEAD) -> $ref"
  git -C "$CB_DIR" fetch -q origin || die "git fetch failed"
  local target
  target=$(git -C "$CB_DIR" rev-parse "origin/$ref" 2>/dev/null || git -C "$CB_DIR" rev-parse "$ref^{commit}" 2>/dev/null) || die "unknown ref: $ref"
  local head; head=$(git -C "$CB_DIR" rev-parse HEAD)
  if [ "$head" = "$target" ]; then
    log "checkout already at ${target:0:7}"
  else
    log "commits to apply:"
    { git -C "$CB_DIR" log --oneline "$head..$target" 2>/dev/null || true; } | sed 's/^/  /'
    log "top of CHANGELOG.md at $ref:"
    { git -C "$CB_DIR" show "$target:CHANGELOG.md" 2>/dev/null || true; } | head -n 12 | sed 's/^/  | /' || true
  fi

  local before_bot before_side
  before_bot=$(container_field "$BOT_CONTAINER_NAME" '{{.Id}}')
  before_side=$(container_field "$SIDECAR_CONTAINER_NAME" '{{.Id}}')
  if [ "$CB_DRY_RUN" = 1 ]; then
    log "would check out ${target:0:7}, pull ${BOT_IMAGE:-the bot image}, rebuild the sidecar, and up -d both (recreated only if their image changed)"
    log "dry-run complete; nothing changed"
    return 0
  fi

  if [ "$head" != "$target" ]; then
    local dirty; dirty=$(git -C "$CB_DIR" status --porcelain --untracked-files=no | wc -l)
    [ "$dirty" = 0 ] || die "tracked files modified in $CB_DIR; refusing to move the checkout"
    if git -C "$CB_DIR" show-ref --verify -q "refs/remotes/origin/$ref"; then
      run git -C "$CB_DIR" checkout -q -B "$ref" "origin/$ref"
    else
      run git -C "$CB_DIR" checkout -q "$target"
    fi
    if [ "$ref" != "$BAIBOT_GIT_REF" ]; then
      env_set_plain "$CB_DIR/instance.env" BAIBOT_GIT_REF "$ref"
      chmod 644 "$CB_DIR/instance.env"
      info "instance.env on the host now says BAIBOT_GIT_REF=$ref; mirror it in the profile"
    fi
  fi

  # new template keys the host files do not know
  local missing
  missing=$(comm -23 <(env_template_names "$CB_DIR/.env.example") <(env_template_names "$CB_DIR/.env"))
  [ -z "$missing" ] || warn ".env lacks keys of the new .env.example: $(printf '%s' "$missing" | tr '\n' ' ')"
  missing=$(comm -23 <(env_template_names "$CB_DIR/x402-sidecar/.env.example") <(env_template_names "$CB_DIR/x402-sidecar/.env"))
  [ -z "$missing" ] || warn "x402-sidecar/.env lacks keys of the new template: $(printf '%s' "$missing" | tr '\n' ' ')"

  run compose_sidecar up -d --build
  if compose_bot pull -q 2>/dev/null; then
    run compose_bot up -d
  else
    warn "pull failed; building the bot image locally"
    run compose_bot up -d --build
  fi

  local after_bot after_side
  after_bot=$(container_field "$BOT_CONTAINER_NAME" '{{.Id}}')
  after_side=$(container_field "$SIDECAR_CONTAINER_NAME" '{{.Id}}')
  if [ "$before_bot" = "$after_bot" ]; then log "bot container unchanged"; else log "bot container recreated"; fi
  if [ "$before_side" = "$after_side" ]; then log "sidecar container unchanged"; else log "sidecar container recreated"; fi
  log "update $CB_INSTANCE: done at $(git -C "$CB_DIR" rev-parse --short HEAD)"
}

update_main "$@"
