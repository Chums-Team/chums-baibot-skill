# health.sh - health of one instance, level by level. Read-only.
#
# Levels (references/health-checklist.md):
#   1 containers   both running, RestartCount stable over 5 s
#   2 sidecar      /health: facilitator_mode live, facilitator_watch.ok true
#   3 bot          log since the last start: logged in / syncing, x402 enabled
#                  when configured, no panic, no rejected webhook
#   4 connectivity sidecar resolves `bot`, bot resolves `x402-sidecar`
#   5 ledger       no correlation_id with a row count outside {1, 3}
# Overall: fail when any of levels 1-3 fails (exit 1), else ok (exit 0).
#
# Usage (through run.sh): run.sh health --instance NAME [--target T] [--root DIR] [--quick]
# --quick skips the 5 s restart-count wait.

health_main() {
  parse_common_args "$@"
  need_instance
  load_instance
  local quick=0 a
  for a in "${CB_ARGS[@]+"${CB_ARGS[@]}"}"; do [ "$a" = --quick ] && quick=1; done
  local overall=ok rows=()
  row() { # STATUS LEVEL REASON
    rows+=("$(printf '%-5s %-13s %s' "$1" "$2" "$3")")
    if [ "$1" = fail ] && [ "$4" = core ]; then overall=fail; fi
  }

  # 1. containers
  local c st rc1 rc2 bad=0 reason=""
  for c in "$BOT_CONTAINER_NAME" "$SIDECAR_CONTAINER_NAME"; do
    st=$(container_state "$c")
    if [ "$st" != running ]; then bad=1; reason="$reason $c=$st"; fi
  done
  if [ "$bad" = 1 ]; then
    row fail containers "not running:$reason" core
  else
    rc1="$(container_field "$BOT_CONTAINER_NAME" '{{.RestartCount}}')/$(container_field "$SIDECAR_CONTAINER_NAME" '{{.RestartCount}}')"
    if [ "$quick" = 1 ]; then
      row ok containers "both running, restarts bot/sidecar=$rc1 (no wait)" core
    else
      sleep 5
      rc2="$(container_field "$BOT_CONTAINER_NAME" '{{.RestartCount}}')/$(container_field "$SIDECAR_CONTAINER_NAME" '{{.RestartCount}}')"
      if [ "$rc1" = "$rc2" ]; then
        row ok containers "both running, restarts bot/sidecar=$rc2 stable" core
      else
        row fail containers "restart count grows: $rc1 -> $rc2 (crash loop?)" core
      fi
    fi
  fi

  # 2. sidecar /health
  local body mode watch wreason
  if body=$(curl -fsS --max-time 8 "http://127.0.0.1:$SIDECAR_HOST_PORT/health" 2>/dev/null); then
    mode=$(printf '%s' "$body" | sed -n -E 's/.*"facilitator_mode": *"([^"]*)".*/\1/p')
    watch=$(printf '%s' "$body" | grep -o -E '"facilitator_watch": *\{[^}]*\}' || true)
    if [ "$mode" != live ]; then
      row fail sidecar "facilitator_mode=$mode (want live; X402_FACILITATOR_USE_STUB?)" core
    elif [ -z "$watch" ] || printf '%s' "$watch" | grep -q -E '"facilitator_watch": *null'; then
      row warn sidecar "live; facilitator_watch not probed yet (retry in a few seconds)" core
    elif printf '%s' "$watch" | grep -q -E '"ok": *true'; then
      row ok sidecar "live, facilitator_watch ok, network $(printf '%s' "$body" | sed -n -E 's/.*"network_name": *"([^"]*)".*/\1/p')" core
    else
      wreason=$(printf '%s' "$watch" | sed -n -E 's/.*"reason": *"([^"]*)".*/\1/p')
      row fail sidecar "facilitator_watch ok=false: ${wreason:-no reason given}" core
    fi
  else
    row fail sidecar "GET http://127.0.0.1:$SIDECAR_HOST_PORT/health failed" core
  fi

  # 3. bot log since the last start
  local started logs x402_on=0 problems="" good="" warnings="" utd
  if [ "$(container_state "$BOT_CONTAINER_NAME")" = running ]; then
    started=$(container_field "$BOT_CONTAINER_NAME" '{{.State.StartedAt}}')
    logs=$(docker logs --since "$started" "$BOT_CONTAINER_NAME" 2>&1 || true)
    [ "$(env_key_state "$CB_DIR/.env" BAIBOT_X402_INTERNAL_SECRET)" = set ] && x402_on=1
    grep -q -E '^x402:' "$CB_DIR/config.yml" 2>/dev/null && x402_on=1
    if printf '%s' "$logs" | grep -q -E 'Logged in through the TRON wallet|Found an existing session|Logged in as'; then good="login"; fi
    if printf '%s' "$logs" | grep -q -F 'Syncing..'; then good="${good:+$good,}sync"; fi
    if [ "$x402_on" = 1 ]; then
      if printf '%s' "$logs" | grep -q -F 'x402 top-ups enabled'; then good="${good:+$good,}x402"; else problems="${problems:+$problems; }x402 configured but 'x402 top-ups enabled' not logged"; fi
    fi
    if printf '%s' "$logs" | grep -q -E 'Recovery: '; then good="${good:+$good,}recovery"; fi
    printf '%s' "$logs" | grep -q -F 'Recovery failed' && problems="${problems:+$problems; }$(printf '%s' "$logs" | grep -F 'Recovery failed' | tail -n 1 | sed -E 's/.*(Recovery failed)/\1/' | cut -c1-200)"
    printf '%s' "$logs" | grep -q -E 'panicked at|thread .* panicked' && problems="${problems:+$problems; }panic in log"
    printf '%s' "$logs" | grep -q -F 'x402 webhook rejected' && problems="${problems:+$problems; }x402 webhook rejected (shared secret mismatch?)"
    utd=$(printf '%s' "$logs" | grep -c -F 'Failed to decrypt a room event' || true)
    [ "${utd:-0}" -gt 0 ] && warnings="${warnings:+$warnings; }$utd undecryptable event(s): a client did not share its room keys with the bot's device (see health-checklist.md)"
    printf '%s' "$logs" | grep -q -F 'no backup key was found' && warnings="${warnings:+$warnings; }SDK has no key for the account's room key backup (an older bot without recovery, or no passphrase)"
    if [ -n "$problems" ]; then
      row fail bot "$problems" core
    elif [ -z "$good" ]; then
      row warn bot "no login/sync marker since start yet (starting? logging level?)" core
    elif [ -n "$warnings" ]; then
      row warn bot "markers: $good; $warnings" core
    else
      row ok bot "markers: $good" core
    fi
  else
    row fail bot "container not running" core
  fi

  # 4. connectivity inside the instance network
  local r1=0 r2=0
  docker exec "$SIDECAR_CONTAINER_NAME" python3 -c 'import socket; socket.gethostbyname("bot")' >/dev/null 2>&1 && r1=1
  docker exec "$BOT_CONTAINER_NAME" getent hosts x402-sidecar >/dev/null 2>&1 && r2=1
  if [ "$r1" = 1 ] && [ "$r2" = 1 ]; then row ok connectivity "sidecar->bot and bot->sidecar resolve on $CHUMS_NETWORK" extra
  else row fail connectivity "sidecar->bot=$r1 bot->sidecar=$r2 (same network? container names?)" extra; fi

  # 5. ledger
  local out
  if docker exec "$BOT_CONTAINER_NAME" test -f /data/billing.db 2>/dev/null; then
    if out=$(docker exec "$BOT_CONTAINER_NAME" sqlite3 /data/billing.db "SELECT COUNT(*) FROM (SELECT correlation_id FROM billing_events WHERE correlation_id IS NOT NULL GROUP BY correlation_id HAVING COUNT(*) NOT IN (1, 3));" 2>&1); then
      if [ "$out" = 0 ]; then row ok ledger "no anomalous correlation groups" extra
      else row warn ledger "$out correlation group(s) with a row count outside {1,3}; see '!bai billing zombies'" extra; fi
    else
      row warn ledger "query failed: $(printf '%s' "$out" | head -n 1)" extra
    fi
  else
    row warn ledger "no /data/billing.db yet (no billed call so far, or billing off)" extra
  fi

  printf '%-5s %-13s %s\n' STATUS LEVEL DETAIL
  local r; for r in "${rows[@]}"; do printf '%s\n' "$r"; done
  log "overall: $overall"
  [ "$overall" = ok ]
}

health_main "$@"
