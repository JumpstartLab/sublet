# Sublet

**What if you could use your Claude subscription just like it was the API?**

Point any Anthropic- or OpenAI-compatible client (OpenClaw, LiteLLM, Aider, your own scripts) at a local endpoint, and Sublet answers the request by driving the Claude CLI on your behalf using your OAuth login.

### Contents

- [Quickstart](#quickstart)
- [Value: Use the Subscription Tokens You've Got](#value-use-the-subscription-tokens-youve-got)
- [Theory: Wrap Claude Code to Operate Like the API](#theory-wrap-claude-code-to-operate-like-the-api)
- [Strategies](#strategies)
  - [Invoke Claude Code, Once Per API Request](#invoke-claude-code-once-per-api-request)
  - [Danger Zone: Direct API Access With Your OAuth Token](#danger-zone-direct-api-access-with-your-oauth-token)
- [Getting Your Tokens](#getting-your-tokens)
- [Configuration](#configuration)
- [Endpoints](#endpoints)
- [Using With LiteLLM](#using-with-litellm)
- [Contributing](#contributing)
- [Warnings](#warnings)

---

## Quickstart

You need Docker, the `claude` CLI, and a Claude subscription. One line from there:

```bash
curl -fsSL https://raw.githubusercontent.com/JumpstartLab/sublet/master/bin/install | bash
```

That script clones the repo, runs `claude setup-token` to mint a long-lived OAuth token, writes `.env`, and starts the container on `:4001`. When it finishes, you'll have a running proxy.

When the installer reports healthy, confirm the proxy can see your token:

```bash
curl -s http://localhost:4001/health | jq .
```

You should see something like:

```json
{
  "status": "ok",
  "mode": "cli-subprocess",
  "token_prefix": "sk-ant-oat01-...",
  "has_refresh": false,
  "auto_refresh": true
}
```

A `token_prefix` that starts with `sk-ant-oat01-` means your token is loaded and you're ready to send real requests. See [Endpoints](#endpoints) for what to send next.

---

## Value: Use the Subscription Tokens You've Got

If you're building AI systems, you're paying two ways at once: a subscription plan with a generous pool of included tokens that often sits idle, and an API that bills per token and adds up fast — I've burned $25 or $50 in a day on a small prototype while my subscription did nothing.

Harnesses like OpenClaw and OpenCode used to bridge the gap by routing through your subscription; Anthropic shut that off in early April 2026.

For scrapers, background jobs, and overnight experiments where "slow" is fine, Sublet lets you spend the subscription tokens you're already paying for instead of doubling up on the API.

## Theory: Wrap Claude Code to Operate Like the API

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

## Strategies

There are two ways Sublet can dispatch a request. Pick one — or run both and route by model.

### Invoke Claude Code, Once Per API Request

🐢 *Slow-and-safe.*

This strategy appears to be *terms-of-service compliant*. It drives the real Claude CLI (which does its own per-request cryptographic signing) through your OAuth login. It's our version of following the rules.

**What you can expect:** each request takes about **three to five seconds** to come back. If you're scraping data or processing things in the background, that's great. For live chat it's a little slow. If you're firing a large burst of requests in a short window, they'll queue behind the subprocess pool and it's going to take a while. But it works, and it works pretty well.

This is the default. Every route under `/v1/*` uses it. Nothing extra to enable.

### Danger Zone: Direct API Access With Your OAuth Token

⚠️ *Fast-and-fragile.*

Claude Code signs every outgoing request with a short hash called `cch` on an `x-anthropic-billing-header` block. It's computed at send time by native Zig code inside Bun's HTTP stack — not something a non-CLI client can replicate. The mechanism was exposed by the March 2026 Claude Code source leak (coverage: [Alex Kim](https://alex000kim.com/posts/2026-03-31-claude-code-source-leak/), [Zscaler](https://www.zscaler.com/blogs/security-research/anthropic-claude-code-leak), [NodeSource](https://nodesource.com/blog/anthropic-claude-code-source-leak-bun-bug), [Engineers Codex](https://read.engineerscodex.com/p/diving-into-claude-codes-source-code), [Cybernews](https://cybernews.com/security/anthropic-claude-code-source-leak/)).

Right now Anthropic isn't enforcing the signature, so an OAuth token by itself still works — fast, and cheap relative to the API. But the mechanism wasn't built for nothing; enforcement is coming, and sampled request logs make it trivial to identify accounts that sent unsigned traffic. **Only use this with an account you're willing to lose.**

To opt in, set `ENABLE_DIRECT_API=true` and hit `/direct/*` — same request and response shapes as the CLI routes, different path prefix.

---

## Getting Your Tokens

Sublet authenticates to Anthropic using an OAuth token tied to your Claude subscription. There are two ways to get one.

### Option 1: Mint a long-lived token with `claude setup-token` (recommended)

This is what the [Quickstart](#quickstart) uses. Running `claude setup-token` opens a browser for authentication and then prints a long-lived OAuth token (valid for about a year) that's specifically designed for non-interactive use. No refresh token, no auto-refresh state to persist, no 8-hour expiry to worry about.

The installer handles the paste for you. Doing it by hand, open `.env` in your editor and add a single line `CLAUDE_OAUTH_TOKEN=<the printed value>` — editors let you see and fix any stray line breaks the terminal may have introduced when it wrapped the token on screen. Don't pipe the token through `echo` at a shell prompt; long tokens wrap in most terminals and can pick up embedded newlines on paste.

This is the right choice for servers, CI, or any deployment where you don't want to babysit the credential lifecycle.

### Option 2: Reuse the tokens from your `claude login` session

If you've already logged in with `claude` on this machine, the CLI has an access token (~8 hour lifespan) and a matching refresh token stashed in OS-specific credential storage. Sublet can use those directly — it ships with a `TokenManager` that refreshes the access token automatically before it expires and persists the refreshed pair to `TOKEN_STATE_FILE` so the next restart picks up where you left off.

**macOS** — tokens live in the Keychain under the service name `Claude Code-credentials`:

```bash
security find-generic-password -s "Claude Code-credentials" -w \
  | jq -r '.claudeAiOauth | "CLAUDE_OAUTH_TOKEN=\(.accessToken)\nCLAUDE_OAUTH_REFRESH_TOKEN=\(.refreshToken)"' \
  > .env
```

First run will prompt once for your login password so `security` can unlock the Keychain.

**Linux** — Claude Code writes credentials to `~/.claude/.credentials.json` with the same JSON shape:

```bash
jq -r '.claudeAiOauth | "CLAUDE_OAUTH_TOKEN=\(.accessToken)\nCLAUDE_OAUTH_REFRESH_TOKEN=\(.refreshToken)"' \
  ~/.claude/.credentials.json > .env
```

**Windows** — Claude Code uses the Windows Credential Manager. Open it from the Start menu, find the "Claude Code" entry, and copy `accessToken` and `refreshToken` into `.env` manually. (PR welcome for a PowerShell one-liner.)

### Starting the Server

Once `.env` has your token, bring Sublet up with Docker Compose:

```bash
docker compose up -d --build
```

(The [Quickstart](#quickstart) installer does this for you; this step is only needed if you wrote `.env` yourself.)

### Verifying Your Tokens Work

Once the container is up, confirm the tokens are live by hitting the health endpoint:

```bash
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

`has_refresh: false` is normal and fine if you minted a long-lived token with `claude setup-token` — that token doesn't need one.

## Configuration

Only one environment variable is actually required: `CLAUDE_OAUTH_TOKEN`. Everything else — concurrency limits, subprocess timeout, token storage path, direct-mode opt-in, and a couple of advanced knobs — is optional tuning with sensible defaults.

See **[CONFIGURATION.md](CONFIGURATION.md)** for the full variable reference.

## Endpoints

Sublet exposes Anthropic-compatible and OpenAI-compatible inference endpoints, plus operational routes for health checks and token management:

- `POST /v1/messages` — Anthropic Messages API (CLI subprocess mode)
- `POST /v1/chat/completions` — OpenAI-compatible
- `POST /direct/v1/messages`, `POST /direct/v1/chat/completions` — same request/response shapes, direct-to-Anthropic path (requires `ENABLE_DIRECT_API=true`; see [Danger Zone](#danger-zone-direct-api-access-with-your-oauth-token))
- `GET /health`, `GET /v1/models`, `POST /refresh` — liveness and token management

See **[ENDPOINTS.md](ENDPOINTS.md)** for full request/response examples and limitations.

## Using With LiteLLM

Sublet speaks both the Anthropic and OpenAI request shapes, so any LiteLLM model entry just needs its `api_base` pointed at `http://localhost:4001` (or `/direct` if you've enabled direct mode).

See **[LITELLM.md](LITELLM.md)** for a minimal `config.yaml` and a dual-strategy example.

## Contributing

PRs welcome. See **[CONTRIBUTING.md](CONTRIBUTING.md)** for local dev setup, the repo layout, and how to run the test suite — including running tests without a paid Claude subscription.

## Warnings

A few things that apply no matter which strategy you pick:

- This is an unofficial tool and is not affiliated with or endorsed by Anthropic. Anthropic's [Consumer Terms](https://www.anthropic.com/legal/consumer-terms), [Commercial Terms](https://www.anthropic.com/legal/commercial-terms), and [Usage Policy](https://www.anthropic.com/legal/aup) govern how you may use Claude. You are solely responsible for determining whether your use is permitted.
- Don't expose this proxy to the public internet. Anyone who can reach it can spend your subscription. Bind to `127.0.0.1`, put it on a private network (Tailscale, WireGuard, VPN), or front it with auth. The default bind is `0.0.0.0:4001` for container convenience — not a safe default for a public host.
- Your OAuth token is a credential. Treat the `.env` file, the token state file, and the logs with the same care you would an API key.
- Responses are not streamed. Tool use / function calling is not supported. Only text in, text out.

## License

[MIT](LICENSE)
