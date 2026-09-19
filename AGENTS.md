# Authoring & maintaining the `chums-baibot` skill

Agent guide for working **inside this skill repository**. Read it before
editing `SKILL.md`, the scripts, the references, the templates or a manifest.

## Layout

The layout is flat: `SKILL.md` sits at the repository root and the plugin
manifests point their skill source at `./`. There is no `skills/<name>/`
directory. See `README.md` for the file map.

## Editing rules

- **`SKILL.md` stays thin.** It holds the hard rules, the workflow, the
  operations table and how to read the results. Depth goes into
  `references/`. Everything is in English.
- **Secrets discipline is not negotiable.** No script may print, log, echo or
  pass on a command line the value of a variable read from an env file. The
  interface for secrets is `env_key_state`, `env_key_format`, `report_key`
  in `scripts/lib.sh`: name, state, format verdict. Values move only through
  `env_set_from_file`, `env_copy_key` (a temp file with mode 600 and awk's
  `getline`). `run` prints the command line it executes, so never put a
  value into a command's arguments.
- **One file per operation, functions only in host-side scripts.** `run.sh`
  streams `lib.sh` plus the operation's script into `bash -s` on the target,
  so a host-side script must define functions and end with a single
  `<op>_main "$@"` call, must not depend on other files, and must not read
  from stdin (the script itself is on stdin). Local scripts (`profile.sh`,
  `rotate-secret.sh`) source `lib.sh` by path.
- **Idempotent, check-then-act, `--dry-run`.** Every step that changes the
  host checks first (`skip`) and acts through `run`, which prints instead of
  executing under `--dry-run`. A second run of any operation must be a no-op.
- **Portable shell.** bash 4+, coreutils, awk (mawk-compatible: no
  three-argument `match`), sed, grep, curl, git, openssl, docker. No jq, no
  python on the host (python is used only inside the sidecar container).
- **`set -euo pipefail` is on** in `lib.sh` and the local scripts. Any command
  that may legitimately fail inside `$(...)` or a pipeline gets `|| true`.
- **Templates follow baibot.** `references/templates/bot.env.example` and
  `sidecar.env.example` are copies of baibot's `.env.example` files;
  `config.yml.template` is derived from `etc/app/config.yml.dist` with the
  secrets removed and the billing/x402 sections enabled for the compose
  layout. When baibot changes them, refresh the copies (and
  `references/runbook-digest.md` from `docs/runbook.md`) in one commit.

## Verify before committing

```bash
for f in scripts/*.sh; do bash -n "$f" || echo "syntax: $f"; done
shellcheck scripts/run.sh scripts/lib.sh scripts/profile.sh scripts/rotate-secret.sh
for op in preflight list inspect health deploy apply update lifecycle logs backup remove; do
  cat scripts/lib.sh "scripts/$op.sh" > "/tmp/cb-$op.sh" && shellcheck -s bash "/tmp/cb-$op.sh"
done
for m in .claude-plugin/plugin.json .claude-plugin/marketplace.json .codex-plugin/plugin.json .cursor-plugin/plugin.json; do
  python3 -m json.tool "$m" >/dev/null && echo "ok $m"
done
# a throw-away profile, then every operation with --dry-run against it:
export CHUMS_BAIBOT_PROFILES=$(mktemp -d) CHUMS_BAIBOT_ROOT=$(mktemp -d)
bash scripts/run.sh profile init demo --target local
bash scripts/run.sh deploy --profile demo --dry-run   # after filling the fake secrets and placeholders
```

The live tests (a real host, a real bot) are done by the owner; the order is
`preflight`, `list`, `inspect`, `health`, `logs`, then `profile init`,
`deploy`, a second `deploy` (no change), `apply` after editing `config.yml`
(only the bot restarts), `update`, `backup`, `rotate-secret`, the lifecycle
operations, `remove`, and a second instance next to the first.

## Keeping metadata in sync

When the description or the version changes, update all of:

- `SKILL.md` frontmatter (`version`, `description`)
- `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json` (plugin
  `version` and top-level `metadata.version`)
- `.codex-plugin/plugin.json` (top-level and the `interface` block)
- `.cursor-plugin/plugin.json`
- `README.md`

Keep `name` identical everywhere: `chums-baibot`.

## Publishing: mirror every release into the `chums-skills` catalog

This skill is published through the
[chums-skills](https://github.com/Chums-Team/chums-skills) marketplace, which
keeps its own copy of the `version` and `description`. The catalog follows,
never leads: release here first, then in the catalog:

1. `.claude-plugin/marketplace.json` of the catalog: the `chums-baibot` entry's
   `version` and, if changed, `description`.
2. `.agents/plugins/marketplace.json` of the catalog: `description` if changed;
   the entry points at `ref: main`, so the version follows by itself.
3. Top-level `metadata.version` of both catalog manifests: patch bump, kept
   identical.
4. The catalog's `README.md` Skills row, when the purpose changed.

## What this skill does not do

- It does not install docker, git or anything else on the host.
- It does not run the Matrix smoke test; it guides the user through it.
- It does not encrypt profiles; secrets are clear text with restrictive modes.
- It does not adopt a hand-made deployment into a profile (`adopt` is
  deferred); such a bot is reachable for `inspect`, `health`, `logs` and the
  lifecycle operations only.
