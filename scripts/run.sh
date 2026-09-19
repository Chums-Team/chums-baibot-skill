#!/usr/bin/env bash
#
# run.sh - the one entry point of the chums-baibot skill.
#
# Picks the target (local or user@host), streams lib.sh plus the operation's
# script into `bash -s` there, and, for deploy/apply/rotate-secret, uploads the
# profile files first. The host needs no copy of the skill.
#
# Usage:
#   run.sh <operation> [--profile NAME] [--instance NAME] [--target local|user@host]
#                      [--root DIR] [--dry-run] [operation arguments]
#
# Operations (details in SKILL.md and the scripts' headers):
#   profile init|check|list|path ...   local: manage profiles (profile.sh)
#   preflight                          host check, read-only
#   list                               instances on the host, read-only
#   inspect                            one instance, read-only (drift with --profile)
#   health [--quick]                   health levels, read-only
#   logs [--tail N] [--since X] [--payment-id ID] [--bot|--sidecar]
#   deploy --profile NAME [--dry-run]  new instance (or converge), then health
#   apply --profile NAME [--dry-run]   push profile files, restart what changed, then health
#   update [--ref REF] [--dry-run]     new ref and images, then health
#   start|stop|restart [--dry-run]     the pair of containers
#   backup [--stop] [--dry-run]        state copy on the host
#   rotate-secret --profile NAME [--dry-run]  new shared x402 secret, apply, health
#   remove [--dry-run]                 containers and network; directory kept
#
# Resolution: --instance defaults to the profile name; --target to TARGET of the
# profile's instance.env, then to `local`. --root is forwarded to the host as
# the instances root (default there: ~/chums-baibot of the ssh user).
# CHUMS_BAIBOT_PROFILES overrides ~/.config/chums-baibot.
#
# Secrets: this script never prints the content of an env file. Do not add
# `set -x`.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=${CHUMS_BAIBOT_PROFILES:-$HOME/.config/chums-baibot}
OP=""; PROFILE=""; INSTANCE=""; TARGET=""; ROOT="${CHUMS_BAIBOT_ROOT:-}"; DRY=0
OP_ARGS=()
SSH_OPTS=(-o BatchMode=yes -o ConnectTimeout=15)

usage() { sed -n '3,36p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }

parse_args() {
  [ $# -ge 1 ] || usage 1
  OP=$1; shift
  case "$OP" in -h|--help) usage 0 ;; esac
  while [ $# -gt 0 ]; do
    case "$1" in
      --profile)  PROFILE=$2; shift 2 ;;
      --instance) INSTANCE=$2; shift 2 ;;
      --target)   TARGET=$2; shift 2 ;;
      --root)     ROOT=$2; shift 2 ;;
      --dry-run)  DRY=1; shift ;;
      *)          OP_ARGS+=("$1"); shift ;;
    esac
  done
}

profile_dir() { printf '%s/%s' "$PROFILES" "$1"; }

resolve() {
  if [ -n "$PROFILE" ]; then
    local pd; pd=$(profile_dir "$PROFILE")
    [ -f "$pd/instance.env" ] || die "no such profile: $pd (profile init first)"
    [ -n "$INSTANCE" ] || INSTANCE=$(env_value "$pd/instance.env" INSTANCE)
    [ -n "$INSTANCE" ] || INSTANCE=$PROFILE
    [ -n "$TARGET" ] || TARGET=$(env_value "$pd/instance.env" TARGET)
  fi
  [ -n "$TARGET" ] || TARGET=local
  if [ "$TARGET" != local ]; then
    require_tool ssh
    ssh "${SSH_OPTS[@]}" "$TARGET" true 2>/dev/null \
      || die "ssh to $TARGET does not work non-interactively (key + BatchMode); fix the ssh access first"
  fi
}

# remote OP ARGS...: stream lib.sh + OP.sh into bash on the target.
remote() {
  local op=$1; shift
  local script="$SCRIPT_DIR/$op.sh"
  [ -f "$script" ] || die "no script for operation: $op"
  local common=()
  [ -n "$INSTANCE" ] && common+=(--instance "$INSTANCE")
  [ -n "$ROOT" ] && common+=(--root "$ROOT")
  [ "$DRY" = 1 ] && common+=(--dry-run)
  if [ "$TARGET" = local ]; then
    cat "$SCRIPT_DIR/lib.sh" "$script" | bash -s -- "${common[@]+"${common[@]}"}" "$@"
  else
    local quoted; quoted=$(printf '%q ' "${common[@]+"${common[@]}"}" "$@")
    cat "$SCRIPT_DIR/lib.sh" "$script" | ssh "${SSH_OPTS[@]}" "$TARGET" "bash -s -- $quoted"
  fi
}

remote_root() {
  if [ -n "$ROOT" ]; then printf '%s' "$ROOT"
  elif [ "$TARGET" = local ]; then cb_root
  else ssh "${SSH_OPTS[@]}" "$TARGET" 'printf "%s" "${CHUMS_BAIBOT_ROOT:-$HOME/chums-baibot}"'; fi
}

# push_file SRC DEST: copies a profile file to the target, mode 600, without
# printing its content. Over ssh the content travels on stdin of `cat`.
push_file() {
  local src=$1 dest=$2
  if [ "$TARGET" = local ]; then
    (umask 077; mkdir -p "$(dirname "$dest")")
    install -m 600 "$src" "$dest"
  else
    ssh "${SSH_OPTS[@]}" "$TARGET" "umask 077; mkdir -p \"\$(dirname $(printf '%q' "$dest"))\" && cat > $(printf '%q' "$dest")" < "$src"
  fi
}

# set_args: the non-secret instance.env of the profile as --set KEY=VALUE, so a
# dry-run before the first deploy plans with the right names.
set_args() {
  local pd; pd=$(profile_dir "$PROFILE")
  local k
  for k in INSTANCE TARGET BAIBOT_GIT_URL BAIBOT_GIT_REF CHUMS_NETWORK BOT_IMAGE BOT_CONTAINER_NAME SIDECAR_IMAGE SIDECAR_CONTAINER_NAME SIDECAR_HOST_PORT; do
    local v; v=$(env_value "$pd/instance.env" "$k")
    [ -n "$v" ] && printf -- '--set %s=%s ' "$k" "$v"
  done
  return 0
}

# expect_args: --expect NAME=SHA for the four profile files.
expect_args() {
  local pd; pd=$(profile_dir "$PROFILE")
  local f
  for f in instance.env bot.env sidecar.env config.yml; do
    [ -f "$pd/$f" ] && printf -- '--expect %s=%s ' "$f" "$(file_sha "$pd/$f")"
  done
}

stage_profile() {
  local pd root stage f
  pd=$(profile_dir "$PROFILE")
  root=$(remote_root)
  stage="$root/.incoming/$INSTANCE"
  for f in instance.env bot.env sidecar.env config.yml; do
    [ -f "$pd/$f" ] || continue
    push_file "$pd/$f" "$stage/$f"
  done
  log "profile files staged on $TARGET at $stage (hashes verified by the host script)"
}

need_profile() { [ -n "$PROFILE" ] || die "$OP needs --profile NAME"; }

profile_check_or_die() {
  bash "$SCRIPT_DIR/profile.sh" check "$PROFILE" || die "profile check failed; fix the profile before $OP"
}

main() {
  # `profile` has its own options (--target, --port, ...); hand them over untouched.
  if [ "${1:-}" = profile ]; then
    shift
    exec bash "$SCRIPT_DIR/profile.sh" "$@"
  fi
  parse_args "$@"
  case "$OP" in
    preflight|list)
      resolve
      remote "$OP" "${OP_ARGS[@]+"${OP_ARGS[@]}"}" ;;
    inspect)
      resolve
      [ -n "$INSTANCE" ] || die "inspect needs --instance NAME or --profile NAME"
      local extra=()
      if [ -n "$PROFILE" ]; then read -r -a extra <<< "$(expect_args)"; fi
      remote inspect "${extra[@]+"${extra[@]}"}" "${OP_ARGS[@]+"${OP_ARGS[@]}"}" ;;
    health|logs|update|backup|remove)
      resolve
      [ -n "$INSTANCE" ] || die "$OP needs --instance NAME or --profile NAME"
      remote "$OP" "${OP_ARGS[@]+"${OP_ARGS[@]}"}"
      if [ "$OP" = update ] && [ "$DRY" = 0 ]; then remote health; fi ;;
    start|stop|restart)
      resolve
      [ -n "$INSTANCE" ] || die "$OP needs --instance NAME or --profile NAME"
      remote lifecycle "$OP" "${OP_ARGS[@]+"${OP_ARGS[@]}"}" ;;
    deploy|apply)
      need_profile
      resolve
      profile_check_or_die
      local extra=()
      read -r -a extra <<< "$(expect_args) $(set_args)"
      if [ "$DRY" = 0 ]; then stage_profile; fi
      remote "$OP" "${extra[@]+"${extra[@]}"}" "${OP_ARGS[@]+"${OP_ARGS[@]}"}"
      if [ "$DRY" = 0 ]; then remote health; fi ;;
    rotate-secret)
      need_profile
      resolve
      if [ "$DRY" = 1 ]; then
        bash "$SCRIPT_DIR/rotate-secret.sh" "$PROFILE" --dry-run
        log "would then apply the profile and recreate both containers; a settlement arriving in between is answered 401 and must be credited by hand (runbook, 'Rotating the shared secret')"
        return 0
      fi
      bash "$SCRIPT_DIR/rotate-secret.sh" "$PROFILE"
      profile_check_or_die
      local extra=()
      read -r -a extra <<< "$(expect_args)"
      stage_profile
      remote apply "${extra[@]+"${extra[@]}"}"
      remote health ;;
    *) die "unknown operation: $OP (see --help)" ;;
  esac
}

main "$@"
