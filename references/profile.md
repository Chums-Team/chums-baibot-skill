# Profiles

A profile is the wanted state of one instance, kept on the operator's machine.
The host is derived from it: `deploy` creates the instance from the profile,
`apply` pushes later changes. Editing files on the host by hand creates drift
that `inspect` reports.

## Layout

```
$CHUMS_BAIBOT_PROFILES/          default ~/.config/chums-baibot, mode 700
└─ <name>/                       mode 700; the instance name by default
   ├─ instance.env               non-secret; -> <instance>/instance.env
   ├─ bot.env                    mode 600; -> <instance>/.env
   ├─ sidecar.env                mode 600; -> <instance>/x402-sidecar/.env
   └─ config.yml                 non-secret; -> <instance>/config.yml
```

`profile check` refuses a profile whose directory or env files are readable by
others.

## instance.env

| Key | Meaning |
|---|---|
| `INSTANCE` | Instance name: directory under the root on the host, compose project name (`<name>` for the bot, `<name>-x402` for the sidecar). |
| `TARGET` | `local` or `user@host`; the default target of every operation. The host does not read it. |
| `BAIBOT_GIT_URL`, `BAIBOT_GIT_REF` | Where the checkout comes from and which branch, tag or commit it follows. |
| `CHUMS_NETWORK` | Docker network of the instance. One per instance: the sidecar finds the bot by the service name `bot`. |
| `BOT_IMAGE`, `BOT_CONTAINER_NAME` | Bot image (published by baibot's CI as `ghcr.io/chums-team/baibot:<ref>`) and container name. |
| `SIDECAR_IMAGE`, `SIDECAR_CONTAINER_NAME` | Sidecar image tag (built on the host) and container name. |
| `SIDECAR_HOST_PORT` | Loopback port of the sidecar's `/health` on the host. Unique per instance. |

## Lifecycle

1. `profile init NAME --target T [--port N] [--ref REF] [--git-url URL] [--bot-image IMAGE] [--from BAIBOT_CHECKOUT]`
   creates the directory from `references/templates/`, runs `id -u`/`id -g`
   on the target and writes `UID`/`GID` into both env files, generates the
   internal secrets (`openssl rand -hex 32`, written through a file, never
   printed) and lists the user secrets that are still unset. Re-running it
   keeps every existing file and every set value. `--from` takes the two
   `.env.example` files from a baibot checkout instead of the bundled copies;
   `config.yml` always comes from the skill's template.
2. The user fills in the user secrets (`references/secrets.md`). The agent
   fills in `config.yml`: homeserver, mxid, bot name, admin ids, and whatever
   else the user wants; the file is not a secret.
3. `profile check NAME` until it says `OK`.
4. `deploy` (new instance) or `apply` (existing one).

## Drift

After deploy there are two copies of every file. `inspect --profile NAME`
hashes both sides and prints per file `matches profile`, `DIFFERS from
profile` or `missing on host`; content is never shown. The profile is primary:
`apply` overwrites the host. If the host was changed on purpose, the user
updates the profile by hand first.

## Several profiles, several hosts

A profile names one instance on one target. The same instance name on two
hosts is two profiles with different names (`bot-prod`, `bot-test`) and
`INSTANCE` set by hand in `instance.env`, or `--instance` on the command line.
