# sublet

A small HTTP proxy that exposes the Anthropic Messages API and OpenAI Chat Completions API, and fulfills requests by spawning `claude --print` subprocesses. It lets you point any Anthropic- or OpenAI-compatible client (LiteLLM, Aider, custom scripts, etc.) at a local endpoint backed by your Claude Code login.

Under the hood it:

- Accepts `POST /v1/messages` (Anthropic) and `POST /v1/chat/completions` (OpenAI-compatible)
- Extracts the system prompt and user messages
- Runs the Claude Code CLI with your OAuth token and the requested model
- Converts the CLI's JSON output back into the expected API response shape
- Refreshes the OAuth access token automatically before expiry
- Persists refreshed tokens to disk so the pair survives restarts
- Limits in-flight subprocesses and enforces a per-call timeout

---

## ⚠️ Read before using

**This is an unofficial tool and is not affiliated with or endorsed by Anthropic.** It uses a Claude Code OAuth token to drive the `claude` CLI on your behalf and returns the output over HTTP.

- Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms), [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), and [Usage Policy](https://www.anthropic.com/legal/aup) govern how you may use Claude and the Claude Code CLI. **Using a Claude Code subscription to serve automated API traffic may not be permitted** under those terms, and Anthropic may change its terms or technical behavior at any time in ways that break or disallow this pattern.
- **You are solely responsible** for determining whether your intended use is permitted and for the consequences of running this software. If you need programmatic access to Claude, the supported path is an Anthropic API key.
- **Do not expose this proxy to the public internet.** Anyone who can reach it can spend your subscription. Bind to `127.0.0.1`, put it on a private network (Tailscale, WireGuard, VPN), or front it with auth. The default bind is `0.0.0.0:4001` for container convenience — that is not a safe default for a public host.
- **Your OAuth token is a credential.** Treat the `.env` file, token state file, and logs with the same care you would an API key.

If any of that is not acceptable to you, do not use this project.

---

## Why it exists

The Claude Code CLI is an interactive tool. A handful of use cases — local agent frameworks, routing through LiteLLM, experimenting with the OpenAI chat-completions shape, using clients that expect one of these APIs — need an HTTP endpoint instead of a TTY. This proxy is the smallest wrapper I could write to bridge the two.

It is explicitly **not**:

- A replacement for the Anthropic API (use an API key for that)
- A streaming implementation (responses are returned whole)
- A tool-use / function-calling implementation (only text in, text out)
- A way to hide your subscription from Anthropic

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
