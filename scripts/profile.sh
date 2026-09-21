#!/usr/bin/env bash
#
# profile.sh - manage instance profiles on the operator's machine.
#
# A profile describes the wanted state of one bot instance and is the source of
# everything that reaches the host. Layout (see references/profile.md):
#
#   $CHUMS_BAIBOT_PROFILES/<name>/      default ~/.config/chums-baibot/<name>, mode 700
#     instance.env    non-secret: names, port, git ref, target
#     bot.env         secrets of the bot          -> <instance>/.env on the host
#     sidecar.env     secrets of the sidecar      -> <instance>/x402-sidecar/.env
#     config.yml      non-secret bot configuration -> <instance>/config.yml
#
# Usage:
#   profile.sh init NAME --target local|user@host [--port N] [--ref REF]
#                        [--git-url URL] [--bot-image IMAGE] [--from BAIBOT_CHECKOUT]
#   profile.sh check NAME
#   profile.sh list
#   profile.sh path NAME
#
# init is idempotent: existing files are kept, only missing files and empty
# internal secrets are created. Secret values are never printed; the summary
# lists names and states only.

set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
SKILL_DIR=$(cd "$SCRIPT_DIR/.." && pwd)
# shellcheck source=lib.sh
. "$SCRIPT_DIR/lib.sh"

PROFILES=${CHUMS_BAIBOT_PROFILES:-$HOME/.config/chums-baibot}
TEMPLATES="$SKILL_DIR/references/templates"

usage() {
  sed -n '3,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

profile_dir() { printf '%s/%s' "$PROFILES" "$1"; }

# ----- init -------------------------------------------------------------------

target_id() {
  # prints "uid gid" of the target user
  local t=$1
  if [ "$t" = local ]; then
    printf '%s %s' "$(id -u)" "$(id -g)"
  else
    ssh -o BatchMode=yes -o ConnectTimeout=10 "$t" 'printf "%s %s" "$(id -u)" "$(id -g)"' \
      || die "ssh to $t failed (needs key-based, non-interactive access)"
  fi
}

# fill_internal FILE "KEY:FMT ...": generates every internal secret that is
# empty, commented or absent. Reports names only.
fill_internal() {
  local file=$1 pair key state tmp
  for pair in $2; do
    key=${pair%%:*}
    state=$(env_key_state "$file" "$key")
    if [ "$state" = set ]; then
      log "  $key: kept"
      continue
    fi
    tmp=$(umask 077; mktemp)
    gen_secret_file "$tmp"
    env_set_from_file "$file" "$key" "$tmp" fill
    rm -f "$tmp"
    log "  $key: generated"
  done
}

# pair_secret: BAIBOT_X402_INTERNAL_SECRET (bot) must equal X402_INTERNAL_SECRET (sidecar).
pair_secret() {
  local bot=$1 side=$2 bs ss tmp
  bs=$(env_key_state "$bot" BAIBOT_X402_INTERNAL_SECRET)
  ss=$(env_key_state "$side" X402_INTERNAL_SECRET)
  if [ "$bs" = set ] && [ "$ss" = set ]; then
    if env_values_equal "$bot" BAIBOT_X402_INTERNAL_SECRET "$side" X402_INTERNAL_SECRET; then
      log "  shared x402 secret: kept (pair matches)"
    else
      warn "shared x402 secret: bot.env and sidecar.env differ; fix with rotate-secret"
    fi
  elif [ "$bs" = set ]; then
    env_copy_key "$bot" BAIBOT_X402_INTERNAL_SECRET "$side" X402_INTERNAL_SECRET fill
    log "  X402_INTERNAL_SECRET: copied from bot.env"
  elif [ "$ss" = set ]; then
    env_copy_key "$side" X402_INTERNAL_SECRET "$bot" BAIBOT_X402_INTERNAL_SECRET fill
    log "  BAIBOT_X402_INTERNAL_SECRET: copied from sidecar.env"
  else
    tmp=$(umask 077; mktemp)
    gen_secret_file "$tmp"
    env_set_from_file "$bot" BAIBOT_X402_INTERNAL_SECRET "$tmp" fill
    env_set_from_file "$side" X402_INTERNAL_SECRET "$tmp" fill
    rm -f "$tmp"
    log "  shared x402 secret: generated into both files"
  fi
}

cmd_init() {
  local name="" target="" port=8402 ref=$CB_DEFAULT_GIT_REF url=$CB_DEFAULT_GIT_URL from="" bot_image=""
  [ $# -ge 1 ] || usage 1
  name=$1; shift
  while [ $# -gt 0 ]; do
    case "$1" in
      --target)    target=$2; shift 2 ;;
      --port)      port=$2; shift 2 ;;
      --ref)       ref=$2; shift 2 ;;
      --git-url)   url=$2; shift 2 ;;
      --bot-image) bot_image=$2; shift 2 ;;
      --from)      from=$2; shift 2 ;;
      -h|--help)   usage 0 ;;
      *) die "unknown option: $1" ;;
    esac
  done
  valid_name "$name" || die "invalid profile name: $name (lowercase letters, digits, dashes)"
  [ -n "$target" ] || die "--target local|user@host is required"
  printf '%s' "$port" | grep -q -E '^[0-9]+$' || die "--port must be a number"
  require_tool openssl; require_tool awk; require_tool sed
  [ "$target" = local ] || require_tool ssh
  [ -z "$bot_image" ] && bot_image="ghcr.io/chums-team/baibot:$ref"

  local bot_tpl="$TEMPLATES/bot.env.example" side_tpl="$TEMPLATES/sidecar.env.example"
  if [ -n "$from" ]; then
    if [ ! -f "$from/.env.example" ] || [ ! -f "$from/x402-sidecar/.env.example" ]; then
      die "--from must be a baibot checkout (no .env.example there): $from"
    fi
    bot_tpl="$from/.env.example"; side_tpl="$from/x402-sidecar/.env.example"
    info "env templates taken from $from; config.yml still from the skill template"
  fi

  local dir; dir=$(profile_dir "$name")
  umask 077
  mkdir -p "$PROFILES" "$dir"
  chmod 700 "$PROFILES" "$dir"
  log "profile $name: $dir"

  local f
  for f in instance.env bot.env sidecar.env config.yml; do
    if [ -f "$dir/$f" ]; then log "  $f: kept"; continue; fi
    case "$f" in
      instance.env)
        sed -e "s|__INSTANCE__|$name|g" -e "s|__TARGET__|$target|g" -e "s|__GIT_URL__|$url|g" \
            -e "s|__GIT_REF__|$ref|g" -e "s|__PORT__|$port|g" -e "s|__BOT_IMAGE__|$bot_image|g" \
            "$TEMPLATES/instance.env.template" > "$dir/$f"; chmod 644 "$dir/$f" ;;
      bot.env)     install -m 600 "$bot_tpl" "$dir/$f" ;;
      sidecar.env) install -m 600 "$side_tpl" "$dir/$f" ;;
      config.yml)  install -m 600 "$TEMPLATES/config.yml.template" "$dir/$f" ;;
    esac
    log "  $f: created"
  done

  local ids uid gid
  ids=$(target_id "$target"); uid=${ids%% *}; gid=${ids##* }
  env_set_plain "$dir/bot.env" UID "$uid"
  env_set_plain "$dir/bot.env" GID "$gid"
  env_set_plain "$dir/sidecar.env" UID "$uid"
  env_set_plain "$dir/sidecar.env" GID "$gid"
  log "  UID/GID of $target: $uid:$gid (written to bot.env and sidecar.env)"

  log "internal secrets:"
  fill_internal "$dir/bot.env" "BAIBOT_PERSISTENCE_SESSION_ENCRYPTION_KEY:hex64 BAIBOT_PERSISTENCE_CONFIG_ENCRYPTION_KEY:hex64"
  fill_internal "$dir/sidecar.env" "X402_FACILITATOR_WEBHOOK_SECRET:hex64"
  pair_secret "$dir/bot.env" "$dir/sidecar.env"

  log ""
  log "Fill in by hand (never through the agent), then run: profile.sh check $name"
  cmd_check "$name" || true
}

# ----- check ------------------------------------------------------------------

FAILS=0
fail() { printf 'FAIL  %s\n' "$*"; FAILS=$((FAILS + 1)); }
pass() { printf 'PASS  %s\n' "$*"; }
note() { printf 'WARN  %s\n' "$*"; }

check_mode() { # PATH WANTED LABEL
  local mode; mode=$(file_mode "$1")
  if [ "$mode" = "$2" ]; then pass "$3 mode $mode"; else fail "$3 mode is $mode, want $2 (chmod $2 $1)"; fi
}

check_keys() { # FILE CLASS "KEY:FMT ..." -> fails on unset/bad for internal, reports for user
  local file=$1 class=$2 pair key fmt state verdict
  for pair in $3; do
    key=${pair%%:*}; fmt=${pair##*:}
    state=$(env_key_state "$file" "$key")
    case "$state" in
      set)
        verdict=$(env_key_format "$file" "$key" "$fmt")
        if [ "$verdict" = ok ]; then pass "$key set${fmt:+ ($fmt)}"; else fail "$key set but not a valid $fmt"; fi ;;
      empty)
        if [ "$class" = user ]; then
          fail "$key unset (user secret, fill it in)"
        else
          fail "$key is empty and uncommented (an empty BAIBOT_* value unsets the key of config.yml; comment it out or fill it)"
        fi ;;
      *)
        if [ "$class" = user ]; then fail "$key unset (user secret, fill it in)"; else fail "$key unset"; fi ;;
    esac
  done
}

cmd_check() {
  local name=${1:-}; [ -n "$name" ] || usage 1
  local dir; dir=$(profile_dir "$name")
  [ -d "$dir" ] || die "no such profile: $dir"
  FAILS=0
  log "checking profile $name ($dir)"

  check_mode "$PROFILES" 700 "profiles root"
  check_mode "$dir" 700 "profile dir"
  local f
  for f in bot.env sidecar.env; do
    [ -f "$dir/$f" ] || { fail "$f missing"; continue; }
    check_mode "$dir/$f" 600 "$f"
  done
  for f in instance.env config.yml; do
    [ -f "$dir/$f" ] || fail "$f missing"
  done
  [ "$FAILS" = 0 ] || { log "$FAILS problem(s); fix the layout first"; return 1; }

  log "instance.env:"
  local k v
  for k in INSTANCE TARGET BAIBOT_GIT_URL BAIBOT_GIT_REF CHUMS_NETWORK BOT_IMAGE BOT_CONTAINER_NAME SIDECAR_IMAGE SIDECAR_CONTAINER_NAME SIDECAR_HOST_PORT; do
    v=$(env_value "$dir/instance.env" "$k")
    if [ -n "$v" ]; then pass "$k=$v"; else fail "$k unset in instance.env"; fi
  done

  log "bot.env:"
  check_keys "$dir/bot.env" nonsecret "$BOT_NONSECRET_KEYS"
  check_keys "$dir/bot.env" internal "$BOT_INTERNAL_KEYS"
  local pair key n=0 state tron=0
  for pair in $BOT_LOGIN_KEYS; do
    key=${pair%%:*}
    state=$(env_key_state "$dir/bot.env" "$key")
    [ "$state" = set ] && n=$((n + 1))
    if [ "$state" = set ]; then case "$key" in BAIBOT_USER_TRON_*) tron=1 ;; esac; fi
    [ "$state" = empty ] && fail "$key is empty and uncommented"
    if [ "$state" = set ] && [ "$key" = BAIBOT_USER_TRON_PRIVATE_KEY ]; then
      [ "$(env_key_format "$dir/bot.env" "$key" hex64)" = ok ] || fail "$key set but not 64 hex characters"
    fi
  done
  case "$n" in
    1) pass "login credential: exactly one of BAIBOT_USER_PASSWORD / _ACCESS_TOKEN / _TRON_PRIVATE_KEY / _TRON_SEED_PHRASE is set" ;;
    0) fail "login credential: none of BAIBOT_USER_PASSWORD / _ACCESS_TOKEN / _TRON_PRIVATE_KEY / _TRON_SEED_PHRASE is set (user secret)" ;;
    *) fail "login credential: $n of the login variables are set, want exactly one" ;;
  esac
  state=$(env_key_state "$dir/bot.env" BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE)
  case "$state" in
    set)   pass "BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE set (takes precedence over the wallet-derived passphrase)" ;;
    empty) fail "BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE is empty and uncommented" ;;
    *)     if [ "$tron" = 1 ]; then
             pass "BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE unset: the bot derives it from the TRON wallet key (bots built before 2026-09-21 keep the keys on the device only)"
           else
             note "BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE unset: no recovery of encrypted-room history if data/ is lost"
           fi ;;
  esac

  log "sidecar.env:"
  check_keys "$dir/sidecar.env" nonsecret "$SIDECAR_NONSECRET_KEYS"
  check_keys "$dir/sidecar.env" internal "$SIDECAR_INTERNAL_KEYS"
  check_keys "$dir/sidecar.env" user "$SIDECAR_USER_KEYS"
  if [ "$(env_key_state "$dir/bot.env" BAIBOT_X402_INTERNAL_SECRET)" = set ] && [ "$(env_key_state "$dir/sidecar.env" X402_INTERNAL_SECRET)" = set ]; then
    if env_values_equal "$dir/bot.env" BAIBOT_X402_INTERNAL_SECRET "$dir/sidecar.env" X402_INTERNAL_SECRET; then
      pass "shared x402 secret: bot.env and sidecar.env match"
    else
      fail "shared x402 secret: bot.env and sidecar.env differ (run rotate-secret)"
    fi
  fi
  if [ "$(env_value "$dir/bot.env" UID)" != "$(env_value "$dir/sidecar.env" UID)" ]; then
    note "UID differs between bot.env and sidecar.env"
  fi

  log "config.yml:"
  local viol ph
  viol=$(config_secret_violations "$dir/config.yml")
  if [ -n "$viol" ]; then
    while IFS= read -r line; do fail "config.yml line ${line%%:*}: secret key '${line#*:}' has a value; move it to bot.env"; done <<< "$viol"
  else
    pass "no secret values in config.yml"
  fi
  ph=$(config_placeholders "$dir/config.yml")
  if [ -n "$ph" ]; then
    fail "config.yml still has placeholders: $(printf '%s' "$ph" | tr '\n' ' ')"
  else
    pass "no placeholders left in config.yml"
  fi
  if grep -q -E '^x402:' "$dir/config.yml"; then
    grep -q -E '^billing:' "$dir/config.yml" || fail "config.yml has an x402 section without a billing section"
    [ "$(env_key_state "$dir/bot.env" BAIBOT_X402_INTERNAL_SECRET)" = set ] || fail "x402 section present but BAIBOT_X402_INTERNAL_SECRET unset in bot.env"
  else
    note "config.yml has no x402 section: top-ups are off"
  fi

  log "template drift (keys the templates know and the profile does not):"
  local missing
  missing=$(comm -23 <(env_template_names "$TEMPLATES/bot.env.example") <(env_template_names "$dir/bot.env"))
  if [ -z "$missing" ]; then pass "bot.env knows every key of the template"; else note "bot.env lacks: $(printf '%s' "$missing" | tr '\n' ' ')"; fi
  missing=$(comm -23 <(env_template_names "$TEMPLATES/sidecar.env.example") <(env_template_names "$dir/sidecar.env"))
  if [ -z "$missing" ]; then pass "sidecar.env knows every key of the template"; else note "sidecar.env lacks: $(printf '%s' "$missing" | tr '\n' ' ')"; fi

  if [ "$FAILS" = 0 ]; then log "profile $name: OK"; return 0; fi
  log "profile $name: $FAILS problem(s)"
  return 1
}

# ----- list / path ------------------------------------------------------------

cmd_list() {
  [ -d "$PROFILES" ] || { log "no profiles under $PROFILES"; return 0; }
  local d
  for d in "$PROFILES"/*/; do
    [ -f "$d/instance.env" ] || continue
    printf '%-20s target=%-24s ref=%s\n' "$(basename "$d")" "$(env_value "$d/instance.env" TARGET)" "$(env_value "$d/instance.env" BAIBOT_GIT_REF)"
  done
}

cmd_path() {
  local name=${1:-}; [ -n "$name" ] || usage 1
  profile_dir "$name"
}

main() {
  [ $# -ge 1 ] || usage 1
  local cmd=$1; shift
  case "$cmd" in
    init)  cmd_init "$@" ;;
    check) cmd_check "$@" ;;
    list)  cmd_list "$@" ;;
    path)  cmd_path "$@" ;;
    -h|--help) usage 0 ;;
    *) die "unknown command: $cmd" ;;
  esac
}

main "$@"
