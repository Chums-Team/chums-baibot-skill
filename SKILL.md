---
name: chums-baibot
version: 0.3.0
description: >
  Deploy and operate Chums baibot instances: the Matrix LLM bot with billing
  and x402 top-ups (bot container + payment sidecar) on a local or
  ssh-reachable Docker host. Use when the user asks to install, deploy,
  configure, update, restart, back up, inspect, health-check, read the logs
  of or remove a matrix bot, tron bot, chums bot or baibot.
metadata:
  author: Chums Team
  homepage: https://github.com/Chums-Team/chums-baibot-skill
  triggers: >
    matrix bot, tron bot, chums bot, chums baibot, tron baibot, matrix baibot,
    baibot, x402 sidecar, deploy matrix bot, deploy tron bot, deploy chums bot,
    deploy baibot, install matrix bot, install tron bot, install chums bot,
    install baibot, update matrix bot, update tron bot, update chums bot,
    update baibot, health matrix bot, health tron bot, health chums bot,
    health baibot, bot health check, bot logs, restart the bot, back up the bot,
    second bot instance, rotate the x402 secret
---

# chums-baibot

Manage instances of [Chums baibot](https://github.com/Chums-Team/baibot)
(branch `chums`): the bot container next to its x402 payment sidecar, on one
Docker host, several instances side by side. Everything goes through
`scripts/run.sh`; the host needs only bash, docker with the compose plugin,
curl, git and openssl, and receives the scripts over stdin, so nothing is
installed there.

The source of truth for an instance is a **profile** on the operator's machine
(`~/.config/chums-baibot/<name>/`): `instance.env` (names, port, git ref,
target), `bot.env` and `sidecar.env` (secrets), `config.yml` (bot
configuration, no secrets). The host is derived from the profile: `deploy`
creates an instance from it, `apply` pushes changes to it. There is no separate
"configure" step. Details: `references/profile.md`, `references/instance-layout.md`.

## Hard rules

1. **Never read a secret file.** Not `bot.env`, not `sidecar.env`, not
   `<instance>/.env`, not `<instance>/x402-sidecar/.env`: not with the Read
   tool, not with `cat`, `head`, `grep`, `sed`, `less`, not "just the first
   line", not over ssh. The only knowledge about a secret you may have is what
   the scripts print: its **name**, its **state** (set / empty / commented /
   absent) and a **format verdict**. Ask the user to fill secrets in by hand and
   tell them which names are still unset. `references/secrets.md` lists the
   variables and the deny rule for Claude Code that backs this up.
2. **Never put a secret on a command line** (visible in `ps`) and never run
   `docker compose config` without `--no-interpolate`, `env`, `printenv`,
   `docker inspect` of a container's `Config.Env`, or `set -x` on the host.
3. **Only `scripts/run.sh` touches the host.** No ad-hoc ssh commands that
   change state. Read-only ad-hoc commands (`docker ps`, `docker logs`) are
   fine when the scripts do not cover the question.
4. **Act only after the user confirmed the plan.** Every changing operation has
   `--dry-run`; show its output and wait for a "yes" before running without it.
5. `config.yml` in the profile is not a secret: you may read and edit it. Keep
   secrets out of it (`profile check` refuses them).

## Workflow: Decide, Analyze, Plan, Act, Verify

1. **Decide.** Which operation (table below), which target (`local` or
   `user@host`), which profile or instance name. Ask for what is not given.
   The target defaults to `TARGET` of the profile's `instance.env`. For a
   first deploy, ask the questions of "What to ask for a new instance" below,
   in that wording.
2. **Analyze** (read-only). For profile operations: `run.sh profile check
   NAME`. Then `run.sh preflight --target T`, and `run.sh list` or
   `run.sh inspect --profile NAME` (with `--profile` it also reports drift
   between the profile and the host by file hash). Read the output, not the
   files.
3. **Plan.** Run the operation with `--dry-run`, show the plan to the user and
   wait for confirmation. `deploy --dry-run` shows what would be cloned,
   created, replaced and started; `apply --dry-run` which files differ and
   which container would restart; `update --dry-run` the commit range and the
   top of the changelog.
4. **Act.** The same command without `--dry-run`. Do not add steps that the
   plan did not show.
5. **Verify.** `run.sh health --profile NAME` (deploy, apply, update and
   rotate-secret run it by themselves). Report the table as is; `overall: ok`
   means the instance works. On `fail` see `references/health-checklist.md`
   and the runbook digest before proposing a fix.

Report to the user with the scripts' output summarized, naming files by path
and variables by name only.

## Operations

All commands are `bash scripts/run.sh <op> ...` from the skill directory.
Common options: `--profile NAME`, `--instance NAME` (defaults to the profile
name), `--target local|user@host`, `--root DIR` (instances root on the host,
default `~/chums-baibot` of the ssh user), `--dry-run`.

| Operation | Changes the host | What it does |
|---|---|---|
| `profile init NAME --target T [--port N] [--ref REF]` | no (writes the profile) | Creates the profile from the templates, writes UID/GID of the target, generates the internal secrets, prints the names of the user secrets still unset. |
| `profile check NAME` | no | Permissions, completeness, formats, no secrets in `config.yml`, no placeholders left. Names and states only. |
| `profile list` / `profile path NAME` | no | Profiles on this machine. |
| `preflight` | no | Tools, docker daemon and compose, ghcr.io and GitHub reachability, instances root, non-interactive ssh. |
| `list` | no | Instances on the host with ref and container states. |
| `inspect` | no | One instance: ref, images, containers, network, file modes and owners, variable states, keys new in the templates, drift versus the profile. |
| `health [--quick]` | no | Five levels: containers, sidecar `/health`, bot log markers, connectivity, ledger. Exit 1 when levels 1-3 fail. |
| `logs [--tail N] [--since X] [--payment-id ID] [--bot\|--sidecar]` | no | Tail of both logs; a payment id filters both. |
| `deploy --profile NAME` | yes | `profile check`, clone at the ref, profile files, `data/` dirs, network, sidecar `up -d --build`, bot `pull` + `up -d`, then health. Idempotent: a second run changes nothing. |
| `apply --profile NAME` | yes | Pushes the profile files that differ (by hash), restarts only the affected container(s), then health. This is "configure". |
| `update [--ref REF]` | yes | Fetch, show commits and changelog, checkout, pull/rebuild images, `up -d` (containers with an unchanged image are not recreated), health. |
| `start` / `stop` / `restart` | yes | The pair, sidecar first on start, bot first on stop. |
| `backup [--stop]` | no (writes on the host) | `billing.db` and `sidecar.db` via SQLite backup, `data/`, both `.env`, `config.yml`, `instance.env` into `<root>/backups/<instance>-<timestamp>/`. |
| `rotate-secret --profile NAME` | yes | New shared x402 secret into both profile files (never printed), apply, both containers recreated, health. Warn about in-flight payments first. |
| `remove` | yes | Containers and network down; the instance directory is kept and its path printed. |

A bot deployed by hand from the runbook, without a profile, is reachable with
`--instance NAME --target T` for `inspect`, `health`, `logs` and the lifecycle
operations as long as its directory holds an `instance.env`; `deploy` and
`apply` need a profile.

## What to ask for a new instance

Before `profile init` and the `config.yml` edit that follows it, ask for these
and nothing else. Ask in the user's language, one short question per line, with
the default in brackets; accept a bare "defaults are fine". Name the thing, not
the YAML path: a user should never have to guess what `mxid_localpart` or
`homeserver.url` means, and never see a `__PLACEHOLDER__` token. None of this
is a secret, so it can be typed straight into the chat.

| Ask it like this | Default | Fills |
|---|---|---|
| The bot's name, in latin letters without spaces. It names the instance directory, the containers and the network. | - | profile and instance name |
| The homeserver domain. | `tron.mx` | `homeserver.server_name`; `homeserver.url` becomes `https://<domain>` |
| The bot's login: the part before the colon in its address. It will be `@<login>:<domain>`. | - | `user.mxid_localpart` |
| The bot's display name: what users see in the chat. | - | `user.name` |
| The bot's administrator: the full address, for example `@admin:tron.mx`. | - | `access.admin_patterns`, `billing.admin_mxids` |
| The language of the replies to users whose client did not ask for one. | `en` | `i18n.fallback_locale` |
| The prefix of the bot's chat commands. | `!bai` | `command_prefix` |
| The bot's avatar: keep whatever the account has now, or upload baibot's default picture. | keep | `user.avatar` (`"keep"` or `null`) |
| The TRON network for payments. | `nile` (testnet) | `X402_NETWORK` in `sidecar.env`, the user edits it |
| The host port of the sidecar. Ask only for a second instance on the same host. | `8402` | `--port` of `profile init` |

Ask about `homeserver.url` separately only when the user says the domain
delegates the client-server API elsewhere (`.well-known` points at another
host). The billing limits of the template (markup, caps, top-up bounds) are
sane defaults: state them in one line and change them only if asked.

The bot's credential (the wallet key or the password), the facilitator key and
the agent wallet are secrets: never ask for them in the chat. After
`profile init`, name the variables that are still unset and let the user fill
them in an editor.

## Typical sessions

New instance on a server:

```bash
bash scripts/run.sh profile init prod --target deploy@bots.example.org --port 8402
# user fills the login credential, the facilitator key and the wallet in the profile
# by hand; agent edits config.yml (homeserver, mxid, admins) in the profile
bash scripts/run.sh profile check prod
bash scripts/run.sh preflight --profile prod
bash scripts/run.sh deploy --profile prod --dry-run    # show, confirm
bash scripts/run.sh deploy --profile prod              # ends with health
```

After the first deploy the bot has no LLM agent: the profile carries no
provider key (`references/secrets.md`). Tell the user to create one from the
chat as an administrator and point the catch-all handler at it; the exact
commands and an OpenRouter example are in `references/agent-setup.md`.
Encrypted rooms work from the first start as long as the bot imported its
secrets from secret storage (health level 3 reports `Recovery:`); when that
import failed, the bot logs `Failed to decrypt a room event` and stays silent,
and an unencrypted room is the way to talk to it meanwhile. Commands are also
silent for users outside `access.admin_patterns` (`commands_admin_only` is on
in the template).

Change the configuration: edit `config.yml` in the profile, then
`apply --dry-run`, confirm, `apply`. Only the bot restarts.

Second instance on the same host: a second profile with another name and
another `--port`; everything else is derived (network, container names).

Upgrade: `update --dry-run` shows the commits; `update` moves the checkout and
the images and recreates only what changed.

## Reading the results

- `profile check`: `FAIL` lines block deploy/apply. "user secret, fill it in"
  means the user must edit the profile file; do not offer to do it.
- `health`: levels 1-3 decide `overall`. A `warn` on the sidecar right after a
  start is normal for a few seconds (the facilitator probe has not run).
- `inspect` drift `DIFFERS from profile`: the profile is primary; propose
  `apply`, or, if the host was edited on purpose, ask the user to update the
  profile by hand.
- Smoke test through Matrix (invite the bot, pay, ask): not automated. Walk
  the user through the table in `references/runbook-digest.md`.

## Files

- `scripts/run.sh` entry point; `scripts/lib.sh` shared functions; one script
  per operation (their headers document the arguments).
- `references/profile.md` profile layout and lifecycle, drift.
- `references/instance-layout.md` host layout, `instance.env`, compose variables.
- `references/secrets.md` secret classes, variables, rules, Claude Code deny rule.
- `references/health-checklist.md` the five levels and what each status means.
- `references/runbook-digest.md` what the logs must show, start order, smoke test, ledger.
- `references/agent-setup.md` creating the LLM agent from the chat after deploy, OpenRouter example.
- `references/templates/` the files `profile init` starts from.
