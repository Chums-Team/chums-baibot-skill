# Giving the bot an LLM agent

The profile carries no LLM provider key: `config.yml` must stay free of
secrets and baibot has no environment override for a static agent's
`api_key`. So a freshly deployed bot answers only the billing commands until
an administrator creates an agent from the chat. The agent is stored
encrypted in the bot's account data (`BAIBOT_PERSISTENCE_CONFIG_ENCRYPTION_KEY`);
nothing lands in `config.yml` or in the profile.

Preconditions:

- the sender matches `access.admin_patterns` of `config.yml`
  (`commands_admin_only` is on in the template: other users' commands are
  ignored without a reply);
- an unencrypted room with the bot, or a room where the client already shares
  its keys with the bot's device (otherwise the bot logs `Failed to decrypt a
  room event` and stays silent);
- `!bai` is the `command_prefix` of `config.yml`.

## Steps, OpenRouter example

1. `!bai agent create-global openrouter main`
   The bot replies with a sample YAML for the provider. Send it back filled
   in, for example:

   ```yaml
   base_url: https://openrouter.ai/api/v1
   api_key: sk-or-v1-...
   text_generation:
     model_id: deepseek/deepseek-v4-flash-0731
     prompt: "You are a brief, but helpful bot called {{ baibot_name }} powered by the {{ baibot_model_id }} model. The date/time of this conversation's start is: {{ baibot_conversation_start_time_utc }}."
     temperature: 1.0
     max_response_tokens: 4096
     max_context_tokens: 128000
   ```

   These are the defaults baibot itself suggests for the provider.
   `model_id` is the identifier from OpenRouter's model list, verbatim; a
   wrong id fails at the first call, not at creation, so check the id against
   the list before sending the YAML. Keep
   `max_response_tokens` so that one reply costs less than
   `billing.reserve_amount_usd` (0.03 USD by default), or the reserve is not
   enough for the call. `max_context_tokens` follows the model's window.
2. `!bai config global set-handler catch-all global/main`
   The agent becomes the fallback handler for every room. Purpose-specific
   handlers (`text-generation`, `image-generation`, ...) can override it
   later, globally or per room (`docs/configuration/handlers.md` of baibot).
3. Check: `!bai agent details global/main`, then a message in a room whose
   balance is above the reserve gets an LLM reply.

Other providers: the identifiers and sample configurations are in
`docs/providers.md` of baibot (`openai`, `anthropic`, `together-ai`, `venice`,
`ollama`, ...); the commands are the same. With OpenRouter the bot bills the
real cost reported per call; with other providers it uses `billing.pricing`.

The user pastes the API key into the chat with the bot, not into the agent's
session: never ask for the key or offer to send the YAML on the user's behalf.
