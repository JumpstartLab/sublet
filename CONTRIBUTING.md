# Contributing

PRs welcome. This doc covers local development, layout, and the test suite.

## Layout

```
app.rb                       Sinatra app + endpoints
bin/install                  One-shot installer (clone, setup-token, compose up)
lib/prompt_extractor.rb      Anthropic/OpenAI request → (prompt, system) extraction
lib/token_manager.rb         OAuth access + refresh token lifecycle
lib/cli_dispatcher.rb        Subprocess spawn, concurrency limiter, timeout
lib/direct_dispatcher.rb     Opt-in direct API client (experimental)
test/                        Minitest suite (see Testing)
Dockerfile                   node:22-slim + Ruby + Claude Code CLI + Bundler
docker-compose.yml           ./data volume for token state
```

## Running Locally (Without Docker)

Requires Ruby 3.1+ and the `claude` CLI on `PATH`:

```bash
bundle install
CLAUDE_OAUTH_TOKEN=... \
CLAUDE_OAUTH_REFRESH_TOKEN=... \
TOKEN_STATE_FILE=./token_state.json \
CLI_WORKDIR=./workdir \
bundle exec ruby app.rb
```

See [CONFIGURATION.md](CONFIGURATION.md) for all available variables.

## Testing

```bash
bundle install
bin/test                         # full suite (~2s)
bin/test test/endpoints_test.rb  # one file
SKIP_INTEGRATION=1 bin/test      # skip anything that spawns the real Claude CLI
```

The suite has two kinds of tests:

- **Unit** — `prompt_extractor_test.rb`, `token_manager_test.rb`, `cli_dispatcher_test.rb`, `endpoints_test.rb`. Pure Ruby. No subprocess, no network. The endpoint tests stub `$dispatcher.call` with canned responses.
- **Integration** — `integration_test.rb`. Starts a `MockAnthropic` WEBrick server on a random port, exports `ANTHROPIC_BASE_URL` to point at it, and makes real HTTP requests through Sinatra. The `claude --print` subprocess actually spawns and talks to the mock — so the whole pipeline (HTTP in → prompt extraction → subprocess → response reshape → HTTP out) is exercised without credentials or network.

## Contributing Without A Paid Claude Subscription

You can run the full test suite without a Claude subscription or login. You need the `claude` CLI installed (free download from Anthropic), but no account is required to run `bin/test` — the integration tests talk to a local mock server instead of the real Anthropic API. This is deliberate: the mock exists partly for test determinism and partly to lower the barrier to contribution.
