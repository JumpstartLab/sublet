# sublet

## The pitch

A lot of us are building AI systems right now, and there's a split in how you pay for the tokens.

On one side, subscription plans — Claude Pro, Max, the $100 and $200 tiers — come with a generous pool of included tokens. I routinely have days where I don't come close to using my full quota.

On the other side, the API bills per token. I've burned $25 or $50 in a single day on a small prototype while my subscription plan sat mostly idle.

Harnesses like OpenClaw and OpenCode used to bridge this gap — you could route traffic from a harness through your Claude subscription. In early April 2026, Anthropic shut that off.

If you need fast processing, you still have to pay the API. But there's a whole class of work — scrapers, background processors, overnight jobs, experiments — where "slow" is perfectly fine.

## The theory

What if we could use our Claude subscription as though it were an API?

What's the minimal wrapper that can ingest an API request, run it through an interactive Claude session, generate a response, and send it back out through the API?

That's the question this project is trying to answer.

## Strategies

There are two ways sublet can dispatch a request. Pick one — or run both and route by model.

### 1. Invoke Claude Code, once per API request

This strategy appears to be terms-of-service compliant. It drives the real Claude CLI (which does its own per-request cryptographic signing) through your OAuth login. It's our version of following the rules.

**What you can expect:** each request takes about three to five seconds to come back. If you're scraping data or processing things in the background, that's great. For live chat it's a little slow. If you're firing a large burst of requests in a short window, they'll queue behind the subprocess pool and it's going to take a while. But it works, and it works pretty well.

This is the default. Every route under `/v1/*` uses it. Nothing extra to enable.

### 2. Danger zone — direct API access with your OAuth token

Part of Anthropic's strategy in cutting off third-party harnesses was to introduce per-request signing inside the Claude CLI itself.

It works like this: when the CLI makes an outgoing request, it attaches a short hash called `cch` (Claude Code Hash) to an `x-anthropic-billing-header` block. That value is computed and inserted at send time by native Zig code inside Bun's HTTP stack — it is not produced by the JavaScript part of the CLI, and it is not something a non-CLI client can easily replicate. This mechanism was exposed by the Claude Code source code leak in March 2026:

- [Alex Kim — Claude Code source code leak walkthrough](https://alex000kim.com/posts/2026-03-31-claude-code-source-leak/)
- [Zscaler — Anthropic Claude Code leak analysis](https://www.zscaler.com/blogs/security-research/anthropic-claude-code-leak)
- [NodeSource — the Bun bug inside the Claude Code leak](https://nodesource.com/blog/anthropic-claude-code-source-leak-bun-bug)
- [Engineers Codex — Diving into Claude Code's source](https://read.engineerscodex.com/p/diving-into-claude-codes-source-code)
- [Cybernews coverage](https://cybernews.com/security/anthropic-claude-code-source-leak/)

As of mid-April 2026, Anthropic is not enforcing this signature. You can leave it blank and use your OAuth token to submit and retrieve requests through the API directly. It's fast and it works great.

**This is probably not a wise idea.**

Anthropic can flip enforcement on at any time. My guess is that the delay is a scalability issue on their end — they're clearly struggling with demand, and running signature verification on every request adds real load. But they didn't introduce the signing mechanism for no reason. Enforcement is coming.

Second, if they're logging requests (or even sampling them), it becomes trivial for historical analysis to identify which accounts are violating the terms of service. Those are the accounts that get warned or banned.

My recommendation: if you want to use this approach, **do it only with an account you're willing to lose.** Given how favorable the pricing is compared to direct API access, it may genuinely be worth setting up a $100 Max plan, running the direct strategy for a while, and streaming thousands of dollars worth of tokens through it. But when it stops working, don't be surprised.

To opt in, set `ENABLE_DIRECT_API=true` and use the `/direct/*` routes. The request and response shapes are identical to the CLI routes — only the path prefix differs — so a LiteLLM config can route some models to CLI and others to direct.

---

## Before you run it

A few housekeeping notes that don't change depending on which strategy you pick:

- This is an unofficial tool and is not affiliated with or endorsed by Anthropic. Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms), [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), and [Usage Policy](https://www.anthropic.com/legal/aup) govern how you may use Claude. You are solely responsible for determining whether your use is permitted.
- Don't expose this proxy to the public internet. Anyone who can reach it can spend your subscription. Bind to `127.0.0.1`, put it on a private network (Tailscale, WireGuard, VPN), or front it with auth. The default bind is `0.0.0.0:4001` for container convenience — not a safe default for a public host.
- Your OAuth token is a credential. Treat the `.env` file, the token state file, and the logs with the same care you would an API key.
- Responses are not streamed. Tool use / function calling is not supported. Only text in, text out.

## Quickstart

### Prerequisites

- Docker + Docker Compose
- A Claude Code login. After `claude login`, the CLI stores an OAuth access token and refresh token. The storage location varies by OS and CLI version — check your Claude Code installation's credentials (for example `~/.claude/.credentials.json`, or the macOS Keychain under "Claude Code") to retrieve `access_token` and `refresh_token`.

### Run it

```bash
git clone <this-repo>
cd sublet

cp .env.example .env
# Edit .env and set CLAUDE_OAUTH_TOKEN and CLAUDE_OAUTH_REFRESH_TOKEN

docker compose up -d --build

curl -s http://localhost:4001/health | jq .
```

You should see something like:

```json
{
  "status": "ok",
  "mode": "cli-subprocess",
  "cli_version": "2.1.109",
  "max_concurrent": 5,
  "active_requests": 0,
  "subprocess_timeout": 120,
  "token_prefix": "sk-ant-oat01-...",
  "has_refresh": true,
  "expires_in": 28245,
  "expires_at": "2026-04-16T20:00:00Z",
  "auto_refresh": true
}
```

## Configuration

All configuration is via environment variables. Only the first is required.

| Variable | Default | Purpose |
| --- | --- | --- |
| `CLAUDE_OAUTH_TOKEN` *(or `CLAUDE_CODE_OAUTH_TOKEN`)* | — | **Required.** OAuth access token from your Claude Code login. |
| `CLAUDE_OAUTH_REFRESH_TOKEN` *(or `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`)* | — | Refresh token. Strongly recommended — without it the proxy stops working when the access token expires (typically every 8 hours). |
| `MAX_CONCURRENT_REQUESTS` | `5` | Maximum CLI subprocesses running at once. Excess requests queue. |
| `SUBPROCESS_TIMEOUT` | `120` | Per-request timeout in seconds. The subprocess is sent `SIGTERM` then `SIGKILL`. |
| `CLAUDE_CLI_VERSION` | `2.1.109` | Advertised version in the token-refresh `User-Agent` header. |
| `CLAUDE_OAUTH_CLIENT_ID` | public Claude Code client ID | OAuth client ID used when refreshing tokens. |
| `CLI_WORKDIR` | `/app/workdir` | Working directory for the `claude` subprocess. Kept empty in the image so there is no project `CLAUDE.md`, `.mcp.json`, or plugin config. |
| `TOKEN_STATE_FILE` | `/data/token_state.json` | Where refreshed tokens are persisted. Mount a volume here so refreshes survive restarts. |
| `ENABLE_DIRECT_API` | `false` | Opt in to the experimental `/direct/*` routes that call the Anthropic API directly (read the Direct API mode section before enabling). |
| `DIRECT_API_ENDPOINT` | `https://api.anthropic.com/v1/messages` | Override for pointing direct mode at a mock server. |
| `DIRECT_API_MAX_TOKENS` | `4096` | Default `max_tokens` for direct-mode requests. |

## Endpoints

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

### `POST /v1/chat/completions` — OpenAI-compatible

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

### `GET /v1/models`

Returns a static list of the models this proxy advertises. Useful for client autodiscovery.

### `GET /health` and `HEAD /` / `GET /`

Liveness and token status. Safe to scrape; only returns a 16-character prefix of the access token, never the full value.

### `POST /refresh`

Force a token refresh. Returns before/after status. Useful if you want to rotate tokens manually or test that refresh works.

### `POST /direct/v1/messages` and `POST /direct/v1/chat/completions` — direct API mode (opt-in)

Available only when `ENABLE_DIRECT_API=true`. The request and response shapes are identical to the CLI routes above — same headers, same body, same output — so any client configured for `/v1/messages` can point at `/direct/v1/messages` instead and just work. See the [Danger zone](#2-danger-zone--direct-api-access-with-your-oauth-token) section above for the full explanation of what you're signing up for.

When the flag is off (the default), both direct routes return:

```json
{"error":{"type":"not_found","message":"Direct API mode is disabled. Set ENABLE_DIRECT_API=true to opt in (see README — fragile)."}}
```

## Using with LiteLLM

Minimal `config.yaml`:

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

LiteLLM requires an API key string; the proxy does not check it (it uses the OAuth token baked into the container).

If you have enabled direct mode and want LiteLLM to route some models through it, register a second entry whose `api_base` points at `/direct`:

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

This way LiteLLM dispatches to each strategy as a distinct provider by model name, and the fragile path is explicit in your config.

## How it works

```
┌────────────┐    HTTP     ┌───────────────┐   stdin/stdout   ┌───────────┐
│  client    │ ──────────▶ │  Sinatra app  │ ───────────────▶ │ claude    │
│ (LiteLLM,  │             │  (app.rb)     │                  │  --print  │
│  curl, …)  │ ◀────────── │               │ ◀─────────────── │           │
└────────────┘             └───────────────┘                  └───────────┘
                                  │
                                  │ refresh when token
                                  ▼ near expiry
                           ┌──────────────────┐
                           │ Anthropic OAuth  │
                           │ /v1/oauth/token  │
                           └──────────────────┘
```

- Each request spawns a fresh `claude --print` process with the access token in `CLAUDE_CODE_OAUTH_TOKEN`, runs in an empty working directory, and reads the prompt from stdin.
- `--strict-mcp-config` and the empty workdir ensure no project-level `CLAUDE.md`, MCP servers, or plugins are loaded.
- JSON output is parsed and mapped back to the requested API shape. Usage numbers come from the CLI's `usage` block.
- Token refresh happens inside the process, protected by a mutex, five minutes before expiry. Refreshed tokens are written atomically to `TOKEN_STATE_FILE` (tmp-write + rename) so a kill mid-write cannot corrupt the file.
- If the env-var token prefix differs from the on-disk token prefix on startup, the proxy prefers the env var — so rotating credentials by editing `.env` and restarting always wins over the saved state.

## Development

Layout:

```
app.rb                       Sinatra app + endpoints
lib/prompt_extractor.rb      Anthropic/OpenAI request → (prompt, system) extraction
lib/token_manager.rb         OAuth access + refresh token lifecycle
lib/cli_dispatcher.rb        Subprocess spawn, concurrency limiter, timeout
lib/direct_dispatcher.rb     Opt-in direct API client (experimental)
test/                        Minitest suite (see Testing)
Dockerfile                   node:22-slim + Ruby + Claude Code CLI + Bundler
docker-compose.yml           ./data volume for token state
```

Run locally without Docker (requires Ruby 3.1+ and `claude` on `PATH`):

```bash
bundle install
CLAUDE_OAUTH_TOKEN=... \
CLAUDE_OAUTH_REFRESH_TOKEN=... \
TOKEN_STATE_FILE=./token_state.json \
CLI_WORKDIR=./workdir \
bundle exec ruby app.rb
```

## Testing

```bash
bundle install
bin/test                     # full suite (~2s)
bin/test test/endpoints_test.rb  # one file
SKIP_INTEGRATION=1 bin/test  # skip anything that spawns the real Claude CLI
```

The suite has two kinds of tests:

- **Unit** — `prompt_extractor_test.rb`, `token_manager_test.rb`, `cli_dispatcher_test.rb`, `endpoints_test.rb`. Pure Ruby. No subprocess, no network. The endpoint tests stub `$dispatcher.call` with canned responses.
- **Integration** — `integration_test.rb`. Starts a `MockAnthropic` WEBrick server on a random port, exports `ANTHROPIC_BASE_URL` to point at it, and makes real HTTP requests through Sinatra. The `claude --print` subprocess actually spawns and talks to the mock — so the whole pipeline (HTTP in → prompt extraction → subprocess → response reshape → HTTP out) is exercised without credentials or network.

**Contributing without a Claude Code subscription** is possible: the full test suite runs against the mock server. You need the `claude` CLI installed (free download from Anthropic), but no login or paid subscription is required to run `bin/test`. This is deliberate — the mock server exists partly for test determinism and partly to lower the barrier to contribution.

## License

[MIT](LICENSE)
