# Configuration

Sublet is configured entirely through environment variables. Only one value is actually required to run — `CLAUDE_OAUTH_TOKEN`. Everything else is optional tuning with reasonable defaults.

In Docker, set these in `.env` (read automatically by `docker-compose.yml`). Running locally, export them in your shell or pass them inline.

## Required

| Variable | Purpose | Default |
| --- | --- | --- |
| `CLAUDE_OAUTH_TOKEN` *(or `CLAUDE_CODE_OAUTH_TOKEN`)* | OAuth access token from your Claude Code login. | — |

See [Getting Your Tokens](README.md#getting-your-tokens) in the README for how to obtain one.

## Recommended

| Variable | Purpose | Default |
| --- | --- | --- |
| `CLAUDE_OAUTH_REFRESH_TOKEN` *(or `CLAUDE_CODE_OAUTH_REFRESH_TOKEN`)* | Refresh token. Without it the proxy stops working when the access token expires (typically every 8 hours). Not needed if you used `claude setup-token`, which mints a long-lived access token. | — |

## Tuning

| Variable | Purpose | Default |
| --- | --- | --- |
| `MAX_CONCURRENT_REQUESTS` | Maximum CLI subprocesses running at once. Excess requests queue. | `5` |
| `SUBPROCESS_TIMEOUT` | Per-request timeout in seconds. The subprocess is sent `SIGTERM` then `SIGKILL`. | `120` |
| `CLI_WORKDIR` | Working directory for the `claude` subprocess. Kept empty in the image so there is no project `CLAUDE.md`, `.mcp.json`, or plugin config. | `/app/workdir` |
| `TOKEN_STATE_FILE` | Where refreshed tokens are persisted. Mount a volume here so refreshes survive restarts. | `/data/token_state.json` |

## Direct API Mode

These only apply when you opt in to the experimental `/direct/*` routes. Read the [Danger Zone](README.md#danger-zone-direct-api-access-with-your-oauth-token) section of the README before enabling.

| Variable | Purpose | Default |
| --- | --- | --- |
| `ENABLE_DIRECT_API` | Opt in to the `/direct/*` routes that call the Anthropic API directly. | `false` |
| `DIRECT_API_ENDPOINT` | Override the target URL (useful for pointing at a mock server in tests). | `https://api.anthropic.com/v1/messages` |
| `DIRECT_API_MAX_TOKENS` | Default `max_tokens` for direct-mode requests. | `4096` |

## Advanced / Rarely Changed

| Variable | Purpose | Default |
| --- | --- | --- |
| `CLAUDE_CLI_VERSION` | Advertised version in the token-refresh `User-Agent` header. Bump if Anthropic rejects old User-Agents during refresh. | `2.1.109` |
| `CLAUDE_OAUTH_CLIENT_ID` | OAuth client ID used when refreshing tokens. The default is the public Claude Code client ID; you should not need to change this. | public Claude Code client ID |
