#!/usr/bin/env bash
#
# lib.sh - functions shared by every chums-baibot script.
#
# Function definitions only, no top-level commands: run.sh prepends this file to
# a host-side script and streams both into `bash -s`, locally or over ssh, so the
# host needs neither a copy of the skill nor any extra tool. The local scripts
# (profile.sh, rotate-secret.sh) source it instead.
#
# Secrets: no function here prints the value of a variable read from an env
# file. The only things reported about such a variable are its name, its state
# (set / empty / commented / absent) and, for known formats, a format verdict.

# shellcheck disable=SC2034  # globals here are read by the scripts this file is prepended to
set -euo pipefail

CB_DRY_RUN=0
CB_ROOT=""
CB_INSTANCE=""
CB_DIR=""
CB_ARGS=()
CB_CHANGED=0

CB_DEFAULT_GIT_URL="https://github.com/Chums-Team/baibot.git"
CB_DEFAULT_GIT_REF="chums"

# ----- output -----------------------------------------------------------------

log()  { printf '%s\n' "$*"; }
info() { printf 'info  %s\n' "$*"; }
skip() { printf 'skip  %s\n' "$*"; }
warn() { printf 'warn  %s\n' "$*" >&2; }
die()  { printf 'error %s\n' "$*" >&2; exit 1; }

# run CMD...: execute CMD, or only print it under --dry-run. CMD must never carry
# a secret in its arguments (the line is printed and visible in `ps`).
run() {
  local shown="$*"
  case "${1:-}" in
    compose_bot)     shown="docker compose ${*:2}   [in $CB_DIR, project $CB_INSTANCE]" ;;
    compose_sidecar) shown="docker compose ${*:2}   [in $CB_DIR/x402-sidecar, project $CB_INSTANCE-x402]" ;;
  esac
  if [ "$CB_DRY_RUN" = 1 ]; then
    printf 'would %s\n' "$shown"
    return 0
  fi
  printf 'run   %s\n' "$shown"
  "$@"
}

require_tool() {
  command -v "$1" >/dev/null 2>&1 || die "required tool not found: $1"
}

# ----- arguments and instance -------------------------------------------------

cb_root() { printf '%s' "${CHUMS_BAIBOT_ROOT:-$HOME/chums-baibot}"; }

valid_name() { printf '%s' "$1" | grep -q -E '^[a-z0-9][a-z0-9-]{0,39}$'; }

# parse_common_args ARGS...: takes --instance NAME, --root DIR, --dry-run and
# --set KEY=VALUE (a non-secret instance.env value, used by dry-runs before the
# file is on the host) out of ARGS; whatever is left lands in CB_ARGS.
parse_common_args() {
  CB_ARGS=()
  while [ $# -gt 0 ]; do
    case "$1" in
      --instance) [ $# -ge 2 ] || die "--instance needs a value"; CB_INSTANCE="$2"; shift 2 ;;
      --root)     [ $# -ge 2 ] || die "--root needs a value"; CHUMS_BAIBOT_ROOT="$2"; shift 2 ;;
      --dry-run)  CB_DRY_RUN=1; shift ;;
      --set)
        [ $# -ge 2 ] || die "--set needs KEY=VALUE"
        printf '%s' "${2%%=*}" | grep -q -E '^[A-Z][A-Z0-9_]*$' || die "--set: bad key in $2"
        export "${2%%=*}=${2#*=}"
        shift 2 ;;
      *)          CB_ARGS+=("$1"); shift ;;
    esac
  done
  CB_ROOT="$(cb_root)"
  if [ -n "$CB_INSTANCE" ]; then
    valid_name "$CB_INSTANCE" || die "invalid instance name: $CB_INSTANCE (lowercase letters, digits, dashes)"
    CB_DIR="$CB_ROOT/$CB_INSTANCE"
  fi
  return 0
}

need_instance() {
  [ -n "$CB_INSTANCE" ] || die "--instance NAME is required"
}

# instance_defaults: the same defaults the compose files use.
instance_defaults() {
  : "${INSTANCE:=$CB_INSTANCE}"
  : "${CHUMS_NETWORK:=chums-shared}"
  : "${BOT_CONTAINER_NAME:=chums-bot}"
  : "${SIDECAR_CONTAINER_NAME:=chums-x402-sidecar}"
  : "${SIDECAR_HOST_PORT:=8402}"
  : "${BAIBOT_GIT_URL:=$CB_DEFAULT_GIT_URL}"
  : "${BAIBOT_GIT_REF:=$CB_DEFAULT_GIT_REF}"
  export CHUMS_NETWORK BOT_CONTAINER_NAME SIDECAR_CONTAINER_NAME SIDECAR_HOST_PORT
}

# load_instance: reads <instance>/instance.env (non-secret) into the environment
# so that `docker compose` interpolates the per-instance names.
load_instance() {
  need_instance
  [ -f "$CB_DIR/instance.env" ] || die "not an instance: $CB_DIR (no instance.env)"
  set -a
  # shellcheck disable=SC1091
  . "$CB_DIR/instance.env"
  set +a
  instance_defaults
}

# load_instance_env_file FILE: the same for a file that is not on the host yet
# (a staged one), without requiring the instance directory.
load_instance_env_file() {
  set -a
  # shellcheck disable=SC1090
  . "$1"
  set +a
  instance_defaults
}

compose_bot() {
  (cd "$CB_DIR" && COMPOSE_PROJECT_NAME="$CB_INSTANCE" docker compose "$@")
}

compose_sidecar() {
  (cd "$CB_DIR/x402-sidecar" && COMPOSE_PROJECT_NAME="$CB_INSTANCE-x402" docker compose "$@")
}

# ----- files ------------------------------------------------------------------

file_sha() { sha256sum "$1" | cut -c1-64; }

file_mode() { stat -c '%a' "$1" 2>/dev/null || true; }

file_owner() { stat -c '%u:%g' "$1" 2>/dev/null || true; }

# ----- env files (names and states only, never values) ------------------------

# env_key_state FILE KEY -> set | empty | commented | absent
env_key_state() {
  local file=$1 key=$2
  [ -f "$file" ] || { printf 'absent'; return 0; }
  if grep -q -E "^${key}=.+" "$file"; then
    printf 'set'
  elif grep -q -E "^${key}=$" "$file"; then
    printf 'empty'
  elif grep -q -E "^#[[:space:]]*${key}=" "$file"; then
    printf 'commented'
  else
    printf 'absent'
  fi
}

# env_key_format FILE KEY FORMAT -> ok | bad. FORMAT: hex64, tron, int, any.
# The value stays inside this process.
env_key_format() {
  local file=$1 key=$2 fmt=$3 re val
  case "$fmt" in
    hex64) re='^(0x)?[0-9a-fA-F]{64}$' ;;
    tron)  re='^T[1-9A-HJ-NP-Za-km-z]{33}$' ;;
    int)   re='^[0-9]+$' ;;
    *)     printf 'ok'; return 0 ;;
  esac
  val=$(sed -n -E "s/^${key}=//p" "$file" | head -n 1 | sed -E "s/^[\"']//; s/[\"']$//")
  if printf '%s' "$val" | grep -q -E "$re"; then printf 'ok'; else printf 'bad'; fi
}

# env_key_names FILE: the names of the variables set in FILE (uncommented).
env_key_names() {
  { grep -o -E '^[A-Za-z_][A-Za-z0-9_]*=' "$1" 2>/dev/null || true; } | tr -d '=' | sort -u
}

# env_template_names FILE: names of a template, commented placeholders included.
env_template_names() {
  { sed -n -E 's/^#?[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)=.*/\1/p' "$1" 2>/dev/null || true; } | sort -u
}

# env_value FILE KEY: the value of KEY. Only for NON-SECRET files (instance.env)
# or non-secret keys (UID, GID). Never call it on a secret key.
env_value() {
  sed -n -E "s/^${2}=//p" "$1" | head -n 1 | sed -E "s/^[\"']//; s/[\"']$//"
}

# env_values_equal FILE1 KEY1 FILE2 KEY2: compares two values by hash.
env_values_equal() {
  local h1 h2
  h1=$(sed -n -E "s/^${2}=//p" "$1" | head -n 1 | sha256sum)
  h2=$(sed -n -E "s/^${4}=//p" "$3" | head -n 1 | sha256sum)
  [ "$h1" = "$h2" ]
}

# report_key FILE KEY [FORMAT] [CLASS]: one line "KEY  state [format]" .
report_key() {
  local file=$1 key=$2 fmt=${3:-any} class=${4:-} state verdict=""
  state=$(env_key_state "$file" "$key")
  if [ "$state" = set ] && [ "$fmt" != any ]; then
    verdict=$(env_key_format "$file" "$key" "$fmt")
    verdict=" format:$verdict($fmt)"
  fi
  printf '  %-46s %-10s%s%s\n' "$key" "$state" "$verdict" "${class:+ [$class]}"
}

# ----- secrets: generation and placement, never through argv or stdout --------

# gen_secret_file OUT: 32 random bytes as hex, into OUT (mode 600).
gen_secret_file() {
  (umask 077; openssl rand -hex 32 > "$1")
}

# env_set_from_file FILE KEY VALFILE MODE: writes KEY=<content of VALFILE> into
# FILE. MODE fill: replaces an empty or commented placeholder, or appends.
# MODE replace: also replaces a set value. The value travels through awk's
# getline, not through the command line.
env_set_from_file() {
  local file=$1 key=$2 vfile=$3 mode=${4:-fill} tmp
  tmp=$(umask 077; mktemp "${file}.XXXXXX") || die "mktemp failed next to $file"
  awk -v key="$key" -v vfile="$vfile" -v mode="$mode" '
    BEGIN {
      if ((getline v < vfile) <= 0) v = ""
      close(vfile)
      sub(/[ \t\r\n]+$/, "", v)
      done = 0
    }
    {
      line = $0
      if (!done) {
        if (line == key "=" || line ~ ("^#[ \t]*" key "=")) { print key "=" v; done = 1; next }
        if (mode == "replace" && index(line, key "=") == 1) { print key "=" v; done = 1; next }
      }
      print line
    }
    END { if (!done) print key "=" v }
  ' "$file" > "$tmp" && mv -f "$tmp" "$file" && chmod 600 "$file"
}

# env_copy_key SRC SRCKEY DST DSTKEY MODE: copies a value between env files.
env_copy_key() {
  local tmp
  tmp=$(umask 077; mktemp) || die "mktemp failed"
  sed -n -E "s/^${2}=//p" "$1" | head -n 1 > "$tmp"
  env_set_from_file "$3" "$4" "$tmp" "${5:-fill}"
  rm -f "$tmp"
}

# env_set_plain FILE KEY VALUE: for NON-SECRET values only (UID, GID, names).
env_set_plain() {
  local tmp
  tmp=$(umask 077; mktemp) || die "mktemp failed"
  printf '%s\n' "$3" > "$tmp"
  env_set_from_file "$1" "$2" "$tmp" replace
  rm -f "$tmp"
}

# ----- known variables --------------------------------------------------------
# NAME:FORMAT pairs. Internal secrets are generated by `profile init`; user
# secrets are filled in by the user; the login group needs exactly one of them.

BOT_INTERNAL_KEYS="BAIBOT_PERSISTENCE_SESSION_ENCRYPTION_KEY:hex64 BAIBOT_PERSISTENCE_CONFIG_ENCRYPTION_KEY:hex64 BAIBOT_X402_INTERNAL_SECRET:hex64"
BOT_LOGIN_KEYS="BAIBOT_USER_PASSWORD:any BAIBOT_USER_ACCESS_TOKEN:any BAIBOT_USER_TRON_PRIVATE_KEY:hex64 BAIBOT_USER_TRON_SEED_PHRASE:any"
BOT_USER_KEYS="BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE:any"
BOT_NONSECRET_KEYS="UID:int GID:int"
SIDECAR_INTERNAL_KEYS="X402_INTERNAL_SECRET:hex64 X402_FACILITATOR_WEBHOOK_SECRET:hex64"
SIDECAR_USER_KEYS="X402_FACILITATOR_API_KEY:any X402_AGENT_WALLET:tron"
SIDECAR_NONSECRET_KEYS="UID:int GID:int"

# report_keys FILE CLASS "NAME:FORMAT ..."
report_keys() {
  local file=$1 class=$2 pair
  for pair in $3; do
    report_key "$file" "${pair%%:*}" "${pair##*:}" "$class"
  done
}

# report_env_file KIND LABEL FILE: every known key of a bot or sidecar env file.
# KIND is bot or sidecar.
report_env_file() {
  local kind=$1 label=$2 file=$3
  log "$label ($file):"
  if [ ! -f "$file" ]; then log "  missing"; return 0; fi
  if [ "$kind" = bot ]; then
    report_keys "$file" nonsecret "$BOT_NONSECRET_KEYS"
    report_keys "$file" internal "$BOT_INTERNAL_KEYS"
    report_keys "$file" login "$BOT_LOGIN_KEYS"
    report_keys "$file" user "$BOT_USER_KEYS"
  else
    report_keys "$file" nonsecret "$SIDECAR_NONSECRET_KEYS"
    report_keys "$file" internal "$SIDECAR_INTERNAL_KEYS"
    report_keys "$file" user "$SIDECAR_USER_KEYS"
  fi
}

# ----- config.yml checks ------------------------------------------------------

# config_secret_violations FILE: prints "line:key" for every uncommented secret
# key of config.yml that carries a value. Secrets belong to bot.env.
config_secret_violations() {
  awk -v sq="'" '
    /^[[:space:]]*#/ { next }
    {
      if (match($0, /^[[:space:]]*(password|access_token|private_key|seed_phrase|recovery_passphrase|session_encryption_key|config_encryption_key|internal_secret|api_key)[[:space:]]*:/)) {
        key = substr($0, RSTART, RLENGTH)
        gsub(/[[:space:]:]/, "", key)
        v = substr($0, RSTART + RLENGTH)
        sub(/[[:space:]]+#.*$/, "", v)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
        if (v != "" && v != "null" && v != "~" && v != "\"\"" && v != sq sq) print NR ":" key
      }
    }
  ' "$1"
}

# config_placeholders FILE: the __PLACEHOLDER__ tokens still in config.yml.
config_placeholders() {
  { grep -o -E '__[A-Z][A-Z0-9_]*__' "$1" 2>/dev/null || true; } | sort -u
}

# ----- staged files (deploy / apply) ------------------------------------------

# stage_dir: where run.sh uploads profile files before deploy/apply.
stage_dir() { printf '%s' "$CB_ROOT/.incoming/$CB_INSTANCE"; }

# sync_staged NAME DEST MODE EXPECTED_SHA: puts the staged file NAME in place
# when DEST is missing or differs from the profile (by hash). Sets CB_CHANGED=1
# when DEST was (or would be) replaced. The staged copy is removed afterwards.
sync_staged() {
  local name=$1 dest=$2 mode=$3 expected=$4 staged have=""
  staged="$(stage_dir)/$name"
  CB_CHANGED=0
  [ -n "$expected" ] || { skip "$name: not in the profile"; return 0; }
  [ -f "$dest" ] && have=$(file_sha "$dest")
  if [ "$have" = "$expected" ]; then
    skip "$dest matches the profile"
    return 0
  fi
  CB_CHANGED=1
  if [ "$CB_DRY_RUN" = 1 ]; then
    if [ -n "$have" ]; then log "would replace $dest from the profile ($name)"; else log "would create $dest from the profile ($name)"; fi
    return 0
  fi
  [ -f "$staged" ] || die "staged file missing: $staged (run.sh uploads it before this step)"
  [ "$(file_sha "$staged")" = "$expected" ] || die "staged file $staged does not match the profile hash"
  run install -m "$mode" "$staged" "$dest"
  rm -f "$staged"
}

# parse_expect_args ARGS...: takes --expect NAME=SHA out of ARGS into EXPECT_<NAME>;
# the rest lands in CB_ARGS.
parse_expect_args() {
  EXPECT_INSTANCE_ENV=""; EXPECT_BOT_ENV=""; EXPECT_SIDECAR_ENV=""; EXPECT_CONFIG_YML=""
  local rest=() pair
  while [ $# -gt 0 ]; do
    case "$1" in
      --expect)
        [ $# -ge 2 ] || die "--expect needs NAME=SHA"
        pair=$2
        case "${pair%%=*}" in
          instance.env) EXPECT_INSTANCE_ENV=${pair#*=} ;;
          bot.env)      EXPECT_BOT_ENV=${pair#*=} ;;
          sidecar.env)  EXPECT_SIDECAR_ENV=${pair#*=} ;;
          config.yml)   EXPECT_CONFIG_YML=${pair#*=} ;;
          *) die "unknown --expect file: ${pair%%=*}" ;;
        esac
        shift 2 ;;
      *) rest+=("$1"); shift ;;
    esac
  done
  CB_ARGS=("${rest[@]+"${rest[@]}"}")
}

# ----- docker helpers ---------------------------------------------------------

# docker inspect prints an empty line on stdout when the container is missing,
# so both helpers capture the output and test it.
container_state() {
  local s
  if s=$(docker inspect -f '{{.State.Status}}' "$1" 2>/dev/null) && [ -n "$s" ]; then printf '%s' "$s"; else printf 'absent'; fi
}

container_field() {
  local s
  s=$(docker inspect -f "$2" "$1" 2>/dev/null) || s=""
  printf '%s' "$s"
}

# drift_line NAME DEST EXPECTED: one line of the profile-vs-host comparison.
drift_line() {
  local name=$1 dest=$2 expected=$3 have="-" verdict
  if [ -z "$expected" ]; then verdict="no profile hash"
  elif [ ! -f "$dest" ]; then verdict="missing on host"
  else
    have=$(file_sha "$dest")
    if [ "$have" = "$expected" ]; then verdict="matches profile"; else verdict="DIFFERS from profile"; fi
  fi
  printf '  %-14s %-34s %s\n' "$name" "$dest" "$verdict"
}
