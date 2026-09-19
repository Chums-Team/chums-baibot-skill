# Instance layout on the host

```
$CHUMS_BAIBOT_ROOT/                 default ~/chums-baibot of the ssh user
├─ .incoming/<instance>/            staging of profile files during deploy/apply (700, emptied afterwards)
├─ backups/<instance>-<timestamp>/  written by backup (700)
└─ <instance>/                      git clone of baibot at BAIBOT_GIT_REF
   ├─ instance.env                  non-secret names (see references/profile.md)
   ├─ .env                          bot secrets, 600 (bot.env of the profile)
   ├─ config.yml                    bot configuration (config.yml of the profile)
   ├─ data/                         Matrix session and crypto store, dynamic config, billing.db
   ├─ docker-compose.yml            from the checkout
   └─ x402-sidecar/
      ├─ .env                       sidecar secrets, 600 (sidecar.env of the profile)
      ├─ data/                      sidecar.db
      └─ docker-compose.yml         from the checkout
```

An instance is anything under the root with an `instance.env`. `--root DIR`
or `CHUMS_BAIBOT_ROOT` on the host move the root; no sudo is needed anywhere.

## Compose variables

The scripts export `instance.env` before every `docker compose` call, so the
compose files of baibot interpolate the per-instance names; without them the
files fall back to the single-bot defaults (`chums-bot`, `chums-x402-sidecar`,
`chums-shared`, port `8402`). Runbook section "Several bots on one host".

| Variable | Compose file | Default |
|---|---|---|
| `CHUMS_NETWORK` | both, `networks.chums-shared.name` | `chums-shared` |
| `BOT_IMAGE` | bot | `ghcr.io/chums-team/baibot:chums` |
| `BOT_CONTAINER_NAME` | bot | `chums-bot` |
| `SIDECAR_IMAGE` | sidecar | `chums-x402-sidecar:0.2.0` |
| `SIDECAR_CONTAINER_NAME` | sidecar | `chums-x402-sidecar` |
| `SIDECAR_HOST_PORT` | sidecar, `127.0.0.1:<port>:8402` | `8402` |

The compose project names are `<instance>` (bot) and `<instance>-x402`
(sidecar), so `docker compose ps` and orphan detection stay per instance.

## Ownership

Both containers run as the `UID`/`GID` of their `.env` and must own their
`data/` directory. `profile init` writes the ids of the ssh user, and `deploy`
creates the directories as that user, so nothing needs `chown`. `inspect` warns
when the owner and the ids disagree; fixing that is a manual step.

## Transport

`run.sh` streams `lib.sh` plus the operation's script into `bash -s` on the
target: locally through a pipe, remotely through `ssh -o BatchMode=yes`. Profile
files reach the host through `cat > file` behind `umask 077` (ssh) or
`install -m 600` (local), into `.incoming/<instance>/`; the host script checks
their SHA-256 against the profile's before moving them into place.
