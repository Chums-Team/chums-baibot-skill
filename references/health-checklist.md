# Health checklist

`run.sh health --profile NAME` prints one row per level. Levels 1-3 decide
`overall`; 4 and 5 are diagnostics.

| # | Level | ok | warn | fail |
|---|---|---|---|---|
| 1 | containers | both `running`, RestartCount unchanged after 5 s | | a container missing or not running; RestartCount grows (crash loop: read `logs`) |
| 2 | sidecar | `GET 127.0.0.1:<port>/health`: `facilitator_mode: live`, `facilitator_watch.ok: true` | `facilitator_watch` not probed yet (a few seconds after a start) | request fails; mode `stub` (`X402_FACILITATOR_USE_STUB=true`); `ok: false` with the reason from the response (facilitator unreachable, wrong network, relayer out of resources, bad API key) |
| 3 | bot | since the last start: `Logged in through the TRON wallet` or `Found an existing session` or `Logged in as`, `Syncing..`, and `x402 top-ups enabled` when x402 is configured | no login/sync marker yet (still starting, or the log level hides info) | `panicked at`; `x402 webhook rejected` (shared secret differs between bot and sidecar); x402 configured but not enabled in the log |
| 4 | connectivity | sidecar resolves `bot`, bot resolves `x402-sidecar` | | one side does not resolve: the containers are not on the same `CHUMS_NETWORK`, or a container name clashes with another instance |
| 5 | ledger | no `correlation_id` with a row count outside {1, 3} | anomalies exist (`!bai billing zombies` in the chat lists them); no `billing.db` yet; query failed | |

What to do on fail:

- Level 1: `run.sh logs --profile NAME --tail 100`. A configuration error stops
  the bot before it logs in, with the reason (an `x402` section without
  `billing`, a non-loopback bind without the flag, an unknown locale, a
  missing credential).
- Level 2: fix the sidecar's `.env` in the profile (the user edits it),
  `apply`, then health again. A wrong network or wallet is a sidecar-side
  setting only.
- Level 3, `x402 webhook rejected`: the shared secret differs; `profile check`
  compares the pair; `rotate-secret` sets a fresh one in both.
- Level 4: `inspect` shows the network and the container names; with two
  instances, each needs its own `CHUMS_NETWORK`.

Beyond the script: the smoke test through Matrix in
`references/runbook-digest.md`, only on request and with a test wallet.
