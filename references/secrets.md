# Secrets

## Classes

| Class | Variables | Who sets them |
|---|---|---|
| Internal, generated | bot: `BAIBOT_PERSISTENCE_SESSION_ENCRYPTION_KEY`, `BAIBOT_PERSISTENCE_CONFIG_ENCRYPTION_KEY`, `BAIBOT_X402_INTERNAL_SECRET`; sidecar: `X402_INTERNAL_SECRET` (same value as the bot's), `X402_FACILITATOR_WEBHOOK_SECRET` | `profile init`, into the profile, through a temp file; `rotate-secret` for the shared one |
| User | bot: exactly one of `BAIBOT_USER_TRON_PRIVATE_KEY`, `BAIBOT_USER_TRON_SEED_PHRASE`, `BAIBOT_USER_PASSWORD`, `BAIBOT_USER_ACCESS_TOKEN`; `BAIBOT_USER_ENCRYPTION_RECOVERY_PASSPHRASE` (recommended); sidecar: `X402_FACILITATOR_API_KEY`, `X402_AGENT_WALLET` | the user, by hand, in the profile |
| Non-secret in the same files | `UID`, `GID` (both), the sidecar's network and facilitator settings (`X402_NETWORK`, `X402_FACILITATOR_URL`, ...) | `profile init` writes UID/GID; the user edits the rest by hand |

LLM provider API keys are not part of the profile: `config.yml` must stay
free of secrets and there is no environment override for a static agent's
`api_key`. Agents are created from the chat by an administrator
(`!bai agent create-global <provider> <id>` and `!bai config global
set-handler catch-all global/<id>`); the bot stores them encrypted in account
data with `BAIBOT_PERSISTENCE_CONFIG_ENCRYPTION_KEY`.

## Rules for the agent

- Do not read `bot.env`, `sidecar.env`, `<instance>/.env`,
  `<instance>/x402-sidecar/.env` or a backup's `env/` directory: no Read tool,
  no `cat`, `head`, `tail`, `less`, `grep`, `sed`, `awk`, `strings`, `base64`,
  no editors, no "check the format" by hand, no ssh one-liners. The scripts
  report names, states and format verdicts; that is the whole interface.
- Do not run on the host: `docker compose config` (interpolates `.env`),
  `docker inspect` on a container without a `-f` that excludes `Config.Env`,
  `env`, `printenv`, `set -x`, `bash -x`.
- Do not pass a secret as a command-line argument anywhere; `ps` shows it.
- When a user secret is unset, say which variable and in which profile file,
  and stop. Never ask the user to paste a secret into the chat.
- `config.yml` is not a secret. `profile check` and `apply` refuse it when one
  of `password`, `access_token`, `private_key`, `seed_phrase`,
  `recovery_passphrase`, `session_encryption_key`, `config_encryption_key`,
  `internal_secret`, `api_key` carries a value.

## Formats the scripts verify

| Variable | Format |
|---|---|
| `*_ENCRYPTION_KEY`, `*_INTERNAL_SECRET`, `X402_FACILITATOR_WEBHOOK_SECRET`, `BAIBOT_USER_TRON_PRIVATE_KEY` | 64 hex characters (optional `0x`) |
| `X402_AGENT_WALLET` | TRON Base58 address: `T` plus 33 Base58 characters |
| `UID`, `GID` | integers |

## Deny rule for Claude Code

The instruction above is one layer; the harness can enforce a second one.
Add to `~/.claude/settings.json` (or the project's `.claude/settings.json`):

```json
{
  "permissions": {
    "deny": [
      "Read(~/.config/chums-baibot/**)",
      "Edit(~/.config/chums-baibot/**/*.env)",
      "Write(~/.config/chums-baibot/**/*.env)",
      "Bash(cat ~/.config/chums-baibot:*)",
      "Bash(head ~/.config/chums-baibot:*)",
      "Bash(tail ~/.config/chums-baibot:*)",
      "Bash(less ~/.config/chums-baibot:*)"
    ]
  }
}
```

Bash rules match a command prefix, so they catch the direct forms only;
`grep pattern ~/.config/...`, `cd ~/.config/... && cat` or `$HOME` spellings
pass them. The rules are a safety net behind the instruction, not a sandbox.

The `Read` rule also blocks reading `config.yml` and `instance.env` of the
profiles through the Read tool; the scripts print what the agent needs from
them, and `config.yml` can still be edited through the Edit tool if you leave
it out of the `Edit` deny list, as above. Adjust the path when
`CHUMS_BAIBOT_PROFILES` points elsewhere. Codex and Cursor have no equivalent
setting; there the instruction is the only layer.

## Residual risk

Secrets sit in clear text on the operator's machine (mode 600 in a 700
directory) and on the host. Encrypting the profile (age, sops) is deferred so
that no extra tool is required; revisit when needed.

## Rotation

`rotate-secret --profile NAME` writes one fresh value to both profile files,
applies the profile (both `.env` files change, both containers are recreated,
sidecar first) and runs health. The sidecar does not retry a settlement
notification: one that arrives between the two restarts is answered 401,
logged as `bot notify failed` on the sidecar, and has to be credited by hand
(runbook digest, "Reconciling a top-up"). Rotate when no payment is in flight.
