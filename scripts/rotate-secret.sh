#!/usr/bin/env bash
#
# rotate-secret.sh - new shared x402 secret in a profile (local step).
#
# Writes one fresh `openssl rand -hex 32` value to both BAIBOT_X402_INTERNAL_SECRET
# (bot.env) and X402_INTERNAL_SECRET (sidecar.env) of the profile, without
# printing it. run.sh then applies the profile to the host and restarts the
# pair; see run.sh rotate-secret.
#
# Usage:
#   rotate-secret.sh NAME [--dry-run]

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=${CHUMS_BAIBOT_PROFILES:-$HOME/.config/chums-baibot}

main() {
  local name=${1:-} dry=0
  [ -n "$name" ] || die "usage: rotate-secret.sh NAME [--dry-run]"
  shift
  [ "${1:-}" = "--dry-run" ] && dry=1
  local dir="$PROFILES/$name"
  if [ ! -f "$dir/bot.env" ] || [ ! -f "$dir/sidecar.env" ]; then die "no such profile or incomplete: $dir"; fi
  require_tool openssl
  if [ "$dry" = 1 ]; then
    log "would write a new shared secret to $dir/bot.env (BAIBOT_X402_INTERNAL_SECRET) and $dir/sidecar.env (X402_INTERNAL_SECRET)"
    return 0
  fi
  local tmp
  tmp=$(umask 077; mktemp)
  gen_secret_file "$tmp"
  env_set_from_file "$dir/bot.env" BAIBOT_X402_INTERNAL_SECRET "$tmp" replace
  env_set_from_file "$dir/sidecar.env" X402_INTERNAL_SECRET "$tmp" replace
  rm -f "$tmp"
  log "profile $name: shared x402 secret rotated in bot.env and sidecar.env (apply it to the host next)"
}

main "$@"
