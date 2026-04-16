# Endpoints

Sublet exposes two sets of inference routes (CLI subprocess mode and opt-in direct mode) plus a handful of operational endpoints. All responses are JSON, and nothing is streamed.

## Inference (CLI Subprocess Mode)

### `POST /v1/messages` — Anthropic Messages API

Accepts the standard Anthropic request shape. Returns a single non-streaming message.

```bash
curl -s http://localhost:4001/v1/messages \
  -H 'content-type: application/json' \
  -d '{
    "model": "claude-haiku-4-5-20251001",
    "max_tokens": 256,
    "messages": [{"role": "user", "content": "Say hi in one word."}]
  }' | jq .
```

Notes:

- `system` may be a string or an array of text blocks. Blocks whose text contains `x-anthropic-billing-header` are dropped so billing metadata doesn't leak into the prompt.
- All `user`-role messages are concatenated and sent to the CLI as a single prompt.
- `assistant` messages in the request are ignored — the CLI is invoked fresh for each call.
- `tool_use` / tool-result blocks are not supported.
- The response is not streamed.

### `POST /v1/chat/completions` — OpenAI-Compatible

```bash
curl -s http://localhost:4001/v1/chat/completions \
  -H 'content-type: application/json' \
  -d '{
    "model": "claude-sonnet-4-6",
    "messages": [
      {"role": "system", "content": "Be terse."},
      {"role": "user", "content": "One-sentence summary of TCP."}
    ]
  }' | jq .
```

Same limitations as `/v1/messages`: non-streaming, no tools, single concatenated user prompt.

## Inference (Direct API Mode, Opt-In)

### `POST /direct/v1/messages` And `POST /direct/v1/chat/completions`

> [!WARNING]
> Available only when `ENABLE_DIRECT_API=true`. See the [Danger Zone](README.md#danger-zone-direct-api-access-with-your-oauth-token) section of the README for the full explanation of what you're signing up for before enabling.

The request and response shapes are **identical** to the CLI routes above — same headers, same body, same output — so any client configured for `/v1/messages` can point at `/direct/v1/messages` instead and just work.

When the flag is off (the default), both direct routes return:

```json
{"error":{"type":"not_found","message":"Direct API mode is disabled. Set ENABLE_DIRECT_API=true to opt in (see README — fragile)."}}
```

## Operational

### `GET /v1/models`

Returns a static list of the models this proxy advertises. Useful for client autodiscovery.

### `GET /health` And `HEAD /` / `GET /`

Liveness and token status. Safe to scrape; only returns a 16-character prefix of the access token, never the full value.

### `POST /refresh`

Force a token refresh. Returns before/after status. Useful if you want to rotate tokens manually or test that refresh works.
