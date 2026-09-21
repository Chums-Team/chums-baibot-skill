# Runbook digest

Distilled from `docs/runbook.md` of baibot (branch `chums`). The runbook is
the authority; this is what the skill relies on.

## The stack

Two containers on one Docker network per instance:

- the **bot** (`ghcr.io/chums-team/baibot:chums`, or built from the checkout),
  Matrix + LLM + ledger; listens for settlement notifications on
  `http://bot:9000/internal/x402-settled` (HMAC with the shared secret, not
  published on the host);
- the **x402 sidecar** (built from `x402-sidecar/` of the checkout), fronts the
  x402 facilitator; the bot reaches it at `http://x402-sidecar:8402`;
  `/health` is published on the host's loopback (`SIDECAR_HOST_PORT`).

The bot's `config.yml` for this layout: `x402.sidecar_url:
http://x402-sidecar:8402`, `internal_bind: 0.0.0.0`, `internal_port: 9000`,
`allow_non_loopback_bind: true`, plus a `billing` section. The shared secret is
`BAIBOT_X402_INTERNAL_SECRET` (bot) = `X402_INTERNAL_SECRET` (sidecar).

## Start order and log markers

Sidecar first, then the bot. Expected in the bot log at start-up:

- `x402 webhook server listening` with the bind address,
- `x402 top-ups enabled` with the sidecar URL,
- with the TRON wallet login: `logging in through the TRON wallet` then
  `Logged in through the TRON wallet` on the first start, `Found an existing
  session` on later starts (the saved session in `data/` is reused); with a
  password or token: `Logged in as`,
- `Recovery passphrase taken from the TRON wallet key` (or `from the
  configuration`), then `Recovery: secrets imported from secret storage` on a
  normal start or `Recovery: secret storage created` on the account's first
  start with recovery; `No recovery passphrase` means the keys stay on the
  device only (no passphrase and no wallet, or a bot older than 2026-09-21),
- `Syncing..` once the Matrix sync runs.

A configuration error stops the bot before login, with the reason.
`/health` of the sidecar must show `"facilitator_mode": "live"` and, after the
first probe, `"facilitator_watch": {"ok": true, ...}`; `ok: false` names the
reason and the client hides the payment button until it is fixed.

## Smoke test (manual, Chums client, test wallet)

| # | Step | Expected |
|---|---|---|
| 1 | Invite the bot to a direct chat | joins, sends the introduction in the client's language |
| 2 | Send any message | "balance too low" reply plus a payment widget (`cc.chums.x402_request`, `facilitator_ok: true`); no LLM call, no ledger rows |
| 3 | Pay through the widget (or after `!bai topup 0.10`) | within a minute: sidecar logs the settlement, bot logs `x402 topup credited` with the `payment_id`, room shows the confirmation with the tx hash |
| 4 | Send a message, then `!bai balance` | LLM answers; balance dropped; `reserve`, `charge`, `release` with one `correlation_id` |
| 5 | Group room: message without mention, then with | silence, then a reply; rows belong to the group room |
| 6 | Admin: `billing.daily_cap_usd` below today's spend, restart, message | "paused until the next UTC day", `cc.chums.cap_hit`; restore and restart |
| 7 | Break the provider (bad API key), message | usual error reply; a `reserve` without `charge`/`release`; `!bai billing zombies 0` lists it; `!bai billing manual-release <event_id> "reason"` |
| 8 | Switch the client's language | user-facing replies follow; admin commands stay English |

Step 3 is the whole payment path. If the widget appears but the payment never
confirms: sidecar log (`/verify`, `/settle`, then `bot notify ok` or `bot
notify failed`), then `BOT_X402_NOTIFY_URL` and the shared secret (the bot
answers 401 and logs `x402 webhook rejected`), then the bot log. `run.sh logs
--payment-id <id>` follows one payment through both logs.

## Ledger

`data/billing.db`, SQLite, append-only; the bot image ships `sqlite3`.

```sh
docker exec <bot> sqlite3 /data/billing.db \
  "SELECT type, COUNT(*), ROUND(SUM(amount_usd), 6) FROM billing_events GROUP BY type;"
docker exec <bot> sqlite3 /data/billing.db \
  "SELECT correlation_id, COUNT(*) FROM billing_events WHERE correlation_id IS NOT NULL GROUP BY correlation_id HAVING COUNT(*) NOT IN (1, 3);"
```

The second query is level 5 of health and should return no rows. Corrections
are new rows (`manual-release`, `manual-refund`) with the administrator's id
and a reason.

## Day-to-day (what the operations implement)

- **Backup**: `data/` and both `.env` files; `billing.db` through `sqlite3
  .backup` (a plain copy of a live SQLite file can be inconsistent).
- **Upgrade**: `git pull`, `docker compose pull && up -d` for the bot,
  `up -d --build` for the sidecar; read the top of `CHANGELOG.md` first. The
  ledger schema is applied idempotently.
- **Rotating the shared secret**: both `.env` files, both containers
  restarted together; the sidecar does not retry a notification.
- **Changing the facilitator or the network**: sidecar `.env` only, restart
  the sidecar.
- **Reconciling a top-up that was paid but never credited**: find the
  `payment_id` in the sidecar log (`bot notify failed`) and credit the room
  with `!bai billing manual-refund <room_id> <amount_usd> "<tx hash>"`.
