# chums-baibot

An agent skill that installs, configures, updates and checks instances of
[Chums baibot](https://github.com/Chums-Team/baibot) (branch `chums`): the
Matrix LLM bot with billing and x402 top-ups, deployed as a bot container next
to its x402 payment sidecar with Docker Compose. Several instances live side by
side on one host. Install it in Claude Code, Codex or Cursor, or drop the
folder into any agent that reads `SKILL.md`.

## What it does

- **Profiles, not prompts.** An instance is described by a profile on the
  operator's machine (`~/.config/chums-baibot/<name>/`): `instance.env`
  (names, port, git ref, target), `bot.env` and `sidecar.env` (secrets),
  `config.yml` (bot configuration). The host is derived from the profile:
  `deploy` creates the instance, `apply` pushes changes, `inspect` reports
  drift by file hash.
- **Secrets the agent never sees.** Internal secrets are generated straight
  into the profile files; user secrets (wallet key, facilitator key) are
  filled in by hand. The scripts print names, states and format verdicts,
  never values, and the skill's rules (plus an optional Claude Code deny rule)
  keep the agent out of the files.
- **Local or ssh.** `run.sh <op> --target user@host` streams the scripts to
  the host over `ssh ... bash -s`; the host needs bash, docker with the
  compose plugin, curl, git and openssl, nothing else, no sudo.
- **Plan, then act.** Every changing operation has `--dry-run`; the skill's
  workflow is Decide, Analyze, Plan, Act, Verify, and Act waits for the user's
  confirmation.
- **Idempotent.** Every step is check-then-act: a second `deploy` changes
  nothing, `apply` restarts only the container whose files changed, `update`
  recreates only containers whose image changed.
- **Health, level by level.** Containers, sidecar `/health`, bot log markers,
  network connectivity, ledger consistency; one table, one overall verdict.

## Operations

| Operation | Purpose |
|---|---|
| `profile init/check/list` | create and validate a profile |
| `preflight`, `list`, `inspect`, `health`, `logs` | read-only views of a host and an instance |
| `deploy`, `apply` | create an instance from the profile; push profile changes to it |
| `update`, `start`/`stop`/`restart`, `backup`, `rotate-secret`, `remove` | day-to-day operations |

The full table with arguments is in [`SKILL.md`](SKILL.md); every script's
header documents its options.

## Layout

```
chums-baibot-skill/
├─ SKILL.md                    the skill: rules, workflow, operations
├─ scripts/
│  ├─ run.sh                   entry point: target, transport, profile upload
│  ├─ lib.sh                   shared functions (prepended to host-side scripts)
│  ├─ profile.sh               local: init, check, list, path
│  ├─ rotate-secret.sh         local: new shared secret in the profile
│  ├─ preflight.sh list.sh inspect.sh health.sh logs.sh          read-only, host-side
│  └─ deploy.sh apply.sh update.sh lifecycle.sh backup.sh remove.sh   changing, host-side
├─ references/
│  ├─ profile.md               profile layout, lifecycle, drift
│  ├─ instance-layout.md       host layout, instance.env, compose variables
│  ├─ secrets.md               secret classes, rules, Claude Code deny rule
│  ├─ health-checklist.md      the five levels and their statuses
│  ├─ runbook-digest.md        log markers, smoke test, ledger, day-to-day
│  └─ templates/               files `profile init` starts from
├─ .claude-plugin/ .codex-plugin/ .cursor-plugin/    agent manifests
├─ AGENTS.md  README.md  LICENSE
```

## Install

**Claude Code**, from the catalog:

```text
/plugin marketplace add Chums-Team/chums-skills
/plugin install chums-baibot@chums-skills
```

or from this repository alone (single-plugin marketplace), also from a local
checkout while developing:

```text
/plugin marketplace add Chums-Team/chums-baibot-skill
/plugin marketplace add /path/to/chums-baibot-skill
/plugin install chums-baibot@chums-baibot-skill
```

**Codex:** `codex plugin marketplace add Chums-Team/chums-skills`, then pick
the skill under `/plugins`.

**Cursor and any folder-based agent:** clone this repository into the agent's
skills root, e.g. `~/.agents/skills/chums-baibot/`, or run the catalog's
`install.sh`.

## Requirements

- Operator's machine: bash, openssl, ssh (for remote targets), coreutils.
- Host: bash, docker with the compose plugin (the user in the `docker`
  group), curl, git, openssl. Network access to `ghcr.io` and
  `github.com`. No sudo.
- baibot's compose files at or after the "Several bots on one host" change
  (variables `CHUMS_NETWORK`, `BOT_CONTAINER_NAME`, `SIDECAR_CONTAINER_NAME`,
  `SIDECAR_HOST_PORT`, `BOT_IMAGE`, `SIDECAR_IMAGE`).

## Usage

Ask the agent, for example:

- "Deploy a new chums bot instance `prod` on deploy@bots.example.org."
- "Change the bot's fallback language to Russian and apply it."
- "Is the bot healthy? Show me the logs of the last payment."
- "Update the bot to the latest `chums` and tell me what changed."
- "Add a second instance `test` next to the first one."

Or run the scripts directly:

```bash
bash scripts/run.sh profile init prod --target deploy@bots.example.org
bash scripts/run.sh profile check prod
bash scripts/run.sh deploy --profile prod --dry-run
bash scripts/run.sh deploy --profile prod
bash scripts/run.sh health --profile prod
```

## Safety

- The agent never reads `bot.env`, `sidecar.env` or the `.env` files on the
  host; `references/secrets.md` has the rules and a deny rule for Claude
  Code that enforces them in the harness.
- Nothing changes on the host before the user confirmed a `--dry-run` plan.
- `remove` keeps the instance directory; deleting data is always manual.

## License

MIT, see [LICENSE](LICENSE).
