# Using With LiteLLM

[LiteLLM](https://docs.litellm.ai/) is a popular multi-provider router. Pointing it at Sublet is a matter of setting `api_base` on the relevant model entries.

## Minimal Config

```yaml
model_list:
  - model_name: claude-haiku
    litellm_params:
      model: anthropic/claude-haiku-4-5-20251001
      api_base: http://localhost:4001
      api_key: not-used-but-required
  - model_name: claude-sonnet
    litellm_params:
      model: anthropic/claude-sonnet-4-6
      api_base: http://localhost:4001
      api_key: not-used-but-required
```

LiteLLM requires an API key string; Sublet does not check it (it uses the OAuth token baked into the container).

## Routing Some Models Through Direct Mode

If you've enabled direct mode (`ENABLE_DIRECT_API=true`) and want LiteLLM to send some models through it, register a second entry whose `api_base` points at `/direct`:

```yaml
model_list:
  # Safe default: CLI subprocess mode.
  - model_name: claude-haiku
    litellm_params:
      model: anthropic/claude-haiku-4-5-20251001
      api_base: http://localhost:4001
      api_key: not-used-but-required

  # Faster but fragile — see README. Only the api_base differs.
  - model_name: claude-haiku-direct
    litellm_params:
      model: anthropic/claude-haiku-4-5-20251001
      api_base: http://localhost:4001/direct
      api_key: not-used-but-required
```

LiteLLM dispatches to each strategy as a distinct provider by model name, and the fragile path is explicit in your config.
