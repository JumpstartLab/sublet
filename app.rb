require "sinatra"
require "json"
require "net/http"
require "uri"
require "securerandom"
require "mutex_m"
require "open3"
require "timeout"

set :port, 4001
set :bind, "0.0.0.0"

TOKEN_ENDPOINT = "https://platform.claude.com/v1/oauth/token"
OAUTH_CLIENT_ID = ENV.fetch("CLAUDE_OAUTH_CLIENT_ID", "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
CLI_VERSION = ENV.fetch("CLAUDE_CLI_VERSION", "2.1.109")
CLI_WORKDIR = ENV.fetch("CLI_WORKDIR", "/app/workdir")
MAX_CONCURRENT = ENV.fetch("MAX_CONCURRENT_REQUESTS", "5").to_i
SUBPROCESS_TIMEOUT = ENV.fetch("SUBPROCESS_TIMEOUT", "120").to_i

initial_token = ENV["CLAUDE_OAUTH_TOKEN"] || ENV["CLAUDE_CODE_OAUTH_TOKEN"]
initial_refresh = ENV["CLAUDE_OAUTH_REFRESH_TOKEN"] || ENV["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"]
abort "Set CLAUDE_OAUTH_TOKEN or CLAUDE_CODE_OAUTH_TOKEN" unless initial_token

# ── Token manager (thread-safe) ──────────────────────────────────
# Handles automatic refresh when access tokens expire.
# Refresh tokens are single-use — each refresh yields a new pair.

class TokenManager
  include Mutex_m

  REFRESH_MARGIN = 300 # refresh 5 min before expiry

  def initialize(access_token, refresh_token, expires_in: nil)
    super() # init Mutex_m
    @access_token = access_token
    @refresh_token = refresh_token
    @initial_token_prefix = access_token[0..15]
    @expires_at = expires_in ? Time.now + expires_in : Time.now + 28800
    @token_file = ENV["TOKEN_STATE_FILE"] || "/app/token_state.json"
    load_state
  end

  def access_token
    synchronize do
      refresh! if @refresh_token && Time.now >= (@expires_at - REFRESH_MARGIN)
      @access_token
    end
  end

  def force_refresh!
    synchronize { refresh! }
  end

  def status
    synchronize do
      remaining = @expires_at - Time.now
      {
        token_prefix: @access_token[0..15],
        has_refresh: !@refresh_token.nil?,
        expires_in: remaining.to_i,
        expires_at: @expires_at.iso8601,
        auto_refresh: !@refresh_token.nil?,
      }
    end
  end

  private

  def refresh!
    $stderr.puts "[#{Time.now.strftime("%H:%M:%S")}] Refreshing OAuth token..."

    uri = URI(TOKEN_ENDPOINT)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = true
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/x-www-form-urlencoded"
    req["User-Agent"] = "claude-cli/#{CLI_VERSION} (external, sdk-cli)"
    req["X-Stainless-Arch"] = "arm64"
    req["X-Stainless-Lang"] = "js"
    req["X-Stainless-OS"] = "MacOS"
    req["X-Stainless-Runtime"] = "node"
    req["X-Stainless-Runtime-Version"] = "v24.3.0"

    params = {
      grant_type: "refresh_token",
      refresh_token: @refresh_token,
      client_id: OAUTH_CLIENT_ID,
    }
    req.body = URI.encode_www_form(params)

    resp = http.request(req)
    unless resp.code.to_i == 200
      $stderr.puts "  Token refresh failed: #{resp.code} #{resp.body[0..200]}"
      return
    end

    data = JSON.parse(resp.body)
    @access_token = data["access_token"]
    @refresh_token = data["refresh_token"]
    @expires_at = Time.now + (data["expires_in"] || 28800)

    $stderr.puts "  Token refreshed: #{@access_token[0..15]}... expires_in=#{data["expires_in"]}s"
    save_state
  rescue => e
    $stderr.puts "  Token refresh error: #{e.message}"
  end

  def save_state
    # Atomic write: write to temp file, then rename to prevent corruption
    # if the process is killed mid-write
    tmp_file = "#{@token_file}.tmp"
    File.write(tmp_file, JSON.generate(
      access_token: @access_token,
      refresh_token: @refresh_token,
      expires_at: @expires_at.to_f,
    ))
    File.rename(tmp_file, @token_file)
  rescue => e
    $stderr.puts "  Warning: could not save token state: #{e.message}"
  end

  def load_state
    return unless File.exist?(@token_file)
    data = JSON.parse(File.read(@token_file))
    saved_at = Time.at(data["expires_at"])

    # If the env var token prefix differs from what we saved, the operator
    # manually rotated tokens — prefer the fresh env var values
    saved_prefix = data["access_token"][0..15] rescue nil
    if saved_prefix && saved_prefix != @initial_token_prefix
      $stderr.puts "  Token state file has different token prefix (#{saved_prefix}), preferring env var token"
      return
    end

    if saved_at > Time.now
      @access_token = data["access_token"]
      @refresh_token = data["refresh_token"] if data["refresh_token"]
      @expires_at = saved_at
      $stderr.puts "  Loaded saved token state: #{@access_token[0..15]}... expires_in=#{(@expires_at - Time.now).to_i}s"
    end
  rescue => e
    $stderr.puts "  Warning: could not load token state: #{e.message}"
  end
end

$token_manager = TokenManager.new(initial_token, initial_refresh)

# ── Concurrency limiter ────────────────────────────────────────────
# Prevents too many CLI subprocesses from running simultaneously.

$semaphore = Mutex.new
$active_count = 0
$active_cv = ConditionVariable.new

def acquire_slot
  $semaphore.synchronize do
    while $active_count >= MAX_CONCURRENT
      $active_cv.wait($semaphore)
    end
    $active_count += 1
  end
end

def release_slot
  $semaphore.synchronize do
    $active_count -= 1
    $active_cv.signal
  end
end

# ── CLI subprocess dispatch ───────────────────────────────────────
# Pipes prompt through `claude --print` and returns the response.

def cli_call(prompt, model:, system_prompt: nil, json_output: false)
  cmd = ["claude", "--print", "--model", model, "--strict-mcp-config"]
  cmd += ["--output-format", "json"] if json_output
  cmd += ["--system-prompt", system_prompt] if system_prompt

  env = {
    "CLAUDE_CODE_OAUTH_TOKEN" => $token_manager.access_token,
    "HOME" => ENV["HOME"] || "/root",
  }

  acquire_slot
  begin
    pid = nil
    stdout, stderr, status = nil, nil, nil

    Timeout.timeout(SUBPROCESS_TIMEOUT) do
      stdin_r, stdin_w = IO.pipe
      stdout_r, stdout_w = IO.pipe
      stderr_r, stderr_w = IO.pipe

      pid = Process.spawn(env, *cmd, in: stdin_r, out: stdout_w, err: stderr_w, chdir: CLI_WORKDIR)
      stdin_r.close
      stdout_w.close
      stderr_w.close

      stdin_w.write(prompt)
      stdin_w.close

      stdout = stdout_r.read
      stderr = stderr_r.read
      stdout_r.close
      stderr_r.close

      _, status = Process.waitpid2(pid)
      pid = nil # successfully reaped
    end
  rescue Timeout::Error
    if pid
      Process.kill("TERM", pid) rescue nil
      sleep(0.5)
      Process.kill("KILL", pid) rescue nil
      Process.waitpid(pid) rescue nil
    end
    raise
  ensure
    release_slot
  end

  unless status&.success?
    exit_code = status&.exitstatus || -1
    $stderr.puts "  CLI error (exit #{exit_code}): #{stderr.to_s[0..500]}"
    raise CLIError.new(stderr.to_s, exit_code)
  end

  if json_output
    JSON.parse(stdout)
  else
    stdout.strip
  end
end

class CLIError < StandardError
  attr_reader :exit_code
  def initialize(message, exit_code)
    super(message)
    @exit_code = exit_code
  end
end

def log(method, path, model)
  $stderr.puts "[#{Time.now.strftime("%H:%M:%S")}] #{method} #{path} model=#{model}"
end

$stderr.puts "claude-proxy (CLI subprocess mode) starting on :4001"
$stderr.puts "  token: #{$token_manager.access_token[0..15]}..."
$stderr.puts "  auto-refresh: #{initial_refresh ? "enabled" : "disabled (no refresh token)"}"
$stderr.puts "  max concurrent: #{MAX_CONCURRENT}"
$stderr.puts "  workdir: #{CLI_WORKDIR}"

# ── Anthropic /v1/messages endpoint ────────────────────────────────
# Accepts Anthropic Messages API format from LiteLLM.
# Extracts prompt, calls CLI, reconstructs Anthropic response.

post "/v1/messages" do
  content_type :json
  body = JSON.parse(request.body.read)
  model = body["model"] || "haiku"
  messages = body["messages"] || []
  halt 400, {error: {type: "invalid_request_error", message: "messages required"}}.to_json if messages.empty?

  # Extract system prompt
  system_prompt = nil
  sys = body["system"]
  if sys.is_a?(String)
    system_prompt = sys
  elsif sys.is_a?(Array)
    # Filter out billing/metadata blocks, keep real system prompt text
    real_sys = sys.select { |b| b.is_a?(Hash) && b["type"] == "text" && !b["text"].to_s.include?("x-anthropic-billing-header") }
    system_prompt = real_sys.map { |b| b["text"] }.join("\n\n") if real_sys.any?
  end

  # Extract user prompt from messages (concatenate all user messages)
  prompt_parts = messages.select { |m| m["role"] == "user" }.map do |m|
    if m["content"].is_a?(Array)
      m["content"].select { |b| b["type"] == "text" }.map { |b| b["text"] }.join("\n")
    else
      m["content"].to_s
    end
  end
  prompt = prompt_parts.join("\n\n")
  halt 400, {error: {type: "invalid_request_error", message: "no user message content"}}.to_json if prompt.empty?

  log("POST", "/v1/messages", model)

  begin
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = cli_call(prompt, model: model, system_prompt: system_prompt, json_output: true)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

    usage = result["usage"] || {}
    $stderr.puts "  <- 200 in #{duration_ms}ms in=#{usage["input_tokens"]} out=#{usage["output_tokens"]}"

    # Reconstruct Anthropic Messages API response
    {
      id: "msg_#{SecureRandom.hex(12)}",
      type: "message",
      role: "assistant",
      content: [{type: "text", text: result["result"] || ""}],
      model: result.dig("modelUsage")&.keys&.first || model,
      stop_reason: result["stop_reason"] || "end_turn",
      usage: {
        input_tokens: usage["input_tokens"] || 0,
        output_tokens: usage["output_tokens"] || 0,
      },
    }.to_json
  rescue CLIError => e
    $stderr.puts "  CLI error: #{e.message[0..200]}"
    status 502
    {type: "error", error: {type: "api_error", message: "CLI subprocess failed: #{e.message[0..200]}"}}.to_json
  rescue JSON::ParserError => e
    $stderr.puts "  JSON parse error on CLI output"
    status 502
    {type: "error", error: {type: "api_error", message: "CLI returned non-JSON output"}}.to_json
  rescue Timeout::Error
    status 504
    {type: "error", error: {type: "timeout_error", message: "CLI subprocess timed out after #{SUBPROCESS_TIMEOUT}s"}}.to_json
  end
end

# ── OpenAI /v1/chat/completions endpoint ───────────────────────────
# Converts OpenAI format to CLI call, converts response back.

post "/v1/chat/completions" do
  content_type :json

  oai = JSON.parse(request.body.read)
  messages = oai["messages"] || []
  halt 400, {error: {message: "messages required"}}.to_json if messages.empty?

  model = oai["model"] || "haiku"

  # Split system from conversation messages
  system_parts = []
  user_parts = []
  messages.each do |m|
    if m["role"] == "system"
      system_parts << m["content"]
    elsif m["role"] == "user"
      user_parts << m["content"].to_s
    end
  end

  prompt = user_parts.join("\n\n")
  halt 400, {error: {message: "no user message content"}}.to_json if prompt.empty?

  system_prompt = system_parts.join("\n\n") if system_parts.any?

  log("POST", "/v1/chat/completions", model)

  begin
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = cli_call(prompt, model: model, system_prompt: system_prompt, json_output: true)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

    usage = result["usage"] || {}
    $stderr.puts "  <- 200 in #{duration_ms}ms in=#{usage["input_tokens"]} out=#{usage["output_tokens"]}"

    {
      id: "chatcmpl-#{SecureRandom.hex(12)}",
      object: "chat.completion",
      created: Time.now.to_i,
      model: result.dig("modelUsage")&.keys&.first || model,
      choices: [{index: 0, message: {role: "assistant", content: result["result"] || ""}, finish_reason: "stop"}],
      usage: {
        prompt_tokens: usage["input_tokens"] || 0,
        completion_tokens: usage["output_tokens"] || 0,
        total_tokens: (usage["input_tokens"] || 0) + (usage["output_tokens"] || 0),
      },
    }.to_json
  rescue CLIError => e
    $stderr.puts "  CLI error: #{e.message[0..200]}"
    status 502
    {error: {message: "CLI subprocess failed: #{e.message[0..200]}", type: "api_error"}}.to_json
  rescue JSON::ParserError
    status 502
    {error: {message: "CLI returned non-JSON output", type: "api_error"}}.to_json
  rescue Timeout::Error
    status 504
    {error: {message: "CLI subprocess timed out after #{SUBPROCESS_TIMEOUT}s", type: "timeout_error"}}.to_json
  end
end

# ── Health + discovery ─────────────────────────────────────────────

head("/") { 200 }
get("/") { content_type :json; {status: "ok"}.to_json }

get "/health" do
  content_type :json
  {
    status: "ok",
    mode: "cli-subprocess",
    cli_version: CLI_VERSION,
    max_concurrent: MAX_CONCURRENT,
    active_requests: $active_count,
    subprocess_timeout: SUBPROCESS_TIMEOUT,
  }.merge($token_manager.status).to_json
end

post "/refresh" do
  content_type :json
  before = $token_manager.status
  $token_manager.force_refresh!
  after = $token_manager.status
  {refreshed: before[:token_prefix] != after[:token_prefix], before: before, after: after}.to_json
end

get "/v1/models" do
  content_type :json
  models = %w[claude-opus-4-6 claude-sonnet-4-6 claude-haiku-4-5-20251001]
  {object: "list", data: models.map { |m| {id: m, object: "model", owned_by: "anthropic"} }}.to_json
end
