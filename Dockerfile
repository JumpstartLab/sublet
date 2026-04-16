FROM node:22-slim

# Install Ruby for the Sinatra proxy server
RUN apt-get update && apt-get install -y --no-install-recommends \
    ruby ruby-dev build-essential ca-certificates \
    && rm -rf /var/lib/apt/lists/*

# Install bundler
RUN gem install bundler --no-document

# Install Claude CLI
RUN npm install -g @anthropic-ai/claude-code && npm cache clean --force

WORKDIR /app

# Install Ruby dependencies
COPY Gemfile ./
RUN bundle install --without development test

# Copy proxy app
COPY app.rb ./
COPY lib/ ./lib/

# Create empty working directory for CLI subprocesses
# (no CLAUDE.md, no .mcp.json, no plugins — minimal startup)
RUN mkdir -p /app/workdir

# Create data directory for token state persistence
RUN mkdir -p /data

EXPOSE 4001

ENV CLI_WORKDIR=/app/workdir
ENV TOKEN_STATE_FILE=/data/token_state.json

CMD ["bundle", "exec", "ruby", "app.rb", "-e", "production"]
