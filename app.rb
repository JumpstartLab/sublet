require "sinatra"
require "json"
require "securerandom"
require "timeout"

require_relative "lib/prompt_extractor"
require_relative "lib/token_manager"
require_relative "lib/cli_dispatcher"
require_relative "lib/direct_dispatcher"

set :port, 4001
set :bind, "0.0.0.0"

OAUTH_CLIENT_ID = ENV.fetch("CLAUDE_OAUTH_CLIENT_ID", "9d1c250a-e61b-44d9-88ed-5944d1962f5e")
CLI_VERSION = ENV.fetch("CLAUDE_CLI_VERSION", "2.1.109")
CLI_WORKDIR = ENV.fetch("CLI_WORKDIR", "/app/workdir")
MAX_CONCURRENT = ENV.fetch("MAX_CONCURRENT_REQUESTS", "5").to_i
SUBPROCESS_TIMEOUT = ENV.fetch("SUBPROCESS_TIMEOUT", "120").to_i
TOKEN_STATE_FILE = ENV["TOKEN_STATE_FILE"] || "/app/token_state.json"
ENABLE_DIRECT_API = %w[1 true yes on].include?(ENV["ENABLE_DIRECT_API"].to_s.downcase)
DIRECT_API_ENDPOINT = ENV.fetch("DIRECT_API_ENDPOINT", DirectDispatcher::DEFAULT_ENDPOINT)
DIRECT_API_MAX_TOKENS = ENV.fetch("DIRECT_API_MAX_TOKENS", "4096").to_i

initial_token = ENV["CLAUDE_OAUTH_TOKEN"] || ENV["CLAUDE_CODE_OAUTH_TOKEN"]
initial_refresh = ENV["CLAUDE_OAUTH_REFRESH_TOKEN"] || ENV["CLAUDE_CODE_OAUTH_REFRESH_TOKEN"]
abort "Set CLAUDE_OAUTH_TOKEN or CLAUDE_CODE_OAUTH_TOKEN" unless initial_token

$token_manager = TokenManager.new(
  initial_token, initial_refresh,
  oauth_client_id: OAUTH_CLIENT_ID,
  cli_version: CLI_VERSION,
  token_file: TOKEN_STATE_FILE,
)

$dispatcher = CliDispatcher.new(
  token_manager: $token_manager,
  workdir: CLI_WORKDIR,
  max_concurrent: MAX_CONCURRENT,
  timeout: SUBPROCESS_TIMEOUT,
  logger: $stderr,
)

$direct_dispatcher =
  if ENABLE_DIRECT_API
    DirectDispatcher.new(
      token_manager: $token_manager,
      endpoint: DIRECT_API_ENDPOINT,
      max_tokens: DIRECT_API_MAX_TOKENS,
      timeout: SUBPROCESS_TIMEOUT,
      logger: $stderr,
    )
  end

def log(method, path, model)
  $stderr.puts "[#{Time.now.strftime("%H:%M:%S")}] #{method} #{path} model=#{model}"
end

$stderr.puts "sublet (CLI subprocess mode) starting on :4001"
$stderr.puts "  token: #{$token_manager.access_token[0..15]}..."
$stderr.puts "  auto-refresh: #{initial_refresh ? "enabled" : "disabled (no refresh token)"}"
$stderr.puts "  max concurrent: #{MAX_CONCURRENT}"
$stderr.puts "  workdir: #{CLI_WORKDIR}"
$stderr.puts "  direct API mode: #{ENABLE_DIRECT_API ? "ENABLED — fragile, see README" : "disabled"}"

helpers do
  def select_dispatcher(direct:)
    return $dispatcher unless direct

    halt 404, {error: {type: "not_found", message: "Direct API mode is disabled. Set ENABLE_DIRECT_API=true to opt in (see README — fragile)."}}.to_json unless $direct_dispatcher
    $direct_dispatcher
  end

  def dispatch_and_time(dispatcher, extracted, model)
    start_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = dispatcher.call(extracted.prompt, model: model, system_prompt: extracted.system_prompt, json_output: true)
    duration_ms = ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - start_time) * 1000).round

    usage = result["usage"] || {}
    $stderr.puts "  <- 200 in #{duration_ms}ms in=#{usage["input_tokens"]} out=#{usage["output_tokens"]}"
    result
  end
end

# ── Anthropic /v1/messages endpoint (CLI + direct) ────────────────

post %r{/(?:direct/)?v1/messages} do
  content_type :json
  direct = request.path_info.start_with?("/direct/")
  body = JSON.parse(request.body.read)
  model = body["model"] || "haiku"

  extracted = PromptExtractor.from_anthropic(body)
  halt 400, {error: {type: "invalid_request_error", message: "messages required"}}.to_json if extracted.nil?
  halt 400, {error: {type: "invalid_request_error", message: "no user message content"}}.to_json unless extracted.valid?

  dispatcher = select_dispatcher(direct: direct)
  log("POST", request.path_info, model)

  begin
    result = dispatch_and_time(dispatcher, extracted, model)

    {
      id: "msg_#{SecureRandom.hex(12)}",
      type: "message",
      role: "assistant",
      content: [{type: "text", text: result["result"] || ""}],
      model: result.dig("modelUsage")&.keys&.first || model,
      stop_reason: result["stop_reason"] || "end_turn",
      usage: {
        input_tokens: result.dig("usage", "input_tokens") || 0,
        output_tokens: result.dig("usage", "output_tokens") || 0,
      },
    }.to_json
  rescue CliDispatcher::CLIError => e
    $stderr.puts "  CLI error: #{e.message[0..200]}"
    status 502
    {type: "error", error: {type: "api_error", message: "CLI subprocess failed: #{e.message[0..200]}"}}.to_json
  rescue DirectDispatcher::APIError => e
    $stderr.puts "  Direct API error #{e.status}: #{e.message[0..200]}"
    status((400..599).cover?(e.status) ? e.status : 502)
    {type: "error", error: {type: "api_error", message: "Direct API call failed (#{e.status}): #{e.message[0..200]}"}}.to_json
  rescue JSON::ParserError
    $stderr.puts "  JSON parse error on dispatcher output"
    status 502
    {type: "error", error: {type: "api_error", message: "Dispatcher returned non-JSON output"}}.to_json
  rescue Timeout::Error
    status 504
    {type: "error", error: {type: "timeout_error", message: "Dispatch timed out after #{SUBPROCESS_TIMEOUT}s"}}.to_json
  end
end

# ── OpenAI /v1/chat/completions endpoint (CLI + direct) ────────────

post %r{/(?:direct/)?v1/chat/completions} do
  content_type :json
  direct = request.path_info.start_with?("/direct/")
  body = JSON.parse(request.body.read)
  model = body["model"] || "haiku"

  extracted = PromptExtractor.from_openai(body)
  halt 400, {error: {message: "messages required"}}.to_json if extracted.nil?
  halt 400, {error: {message: "no user message content"}}.to_json unless extracted.valid?

  dispatcher = select_dispatcher(direct: direct)
  log("POST", request.path_info, model)

  begin
    result = dispatch_and_time(dispatcher, extracted, model)

    {
      id: "chatcmpl-#{SecureRandom.hex(12)}",
      object: "chat.completion",
      created: Time.now.to_i,
      model: result.dig("modelUsage")&.keys&.first || model,
      choices: [{index: 0, message: {role: "assistant", content: result["result"] || ""}, finish_reason: "stop"}],
      usage: {
        prompt_tokens: result.dig("usage", "input_tokens") || 0,
        completion_tokens: result.dig("usage", "output_tokens") || 0,
        total_tokens: (result.dig("usage", "input_tokens") || 0) + (result.dig("usage", "output_tokens") || 0),
      },
    }.to_json
  rescue CliDispatcher::CLIError => e
    $stderr.puts "  CLI error: #{e.message[0..200]}"
    status 502
    {error: {message: "CLI subprocess failed: #{e.message[0..200]}", type: "api_error"}}.to_json
  rescue DirectDispatcher::APIError => e
    $stderr.puts "  Direct API error #{e.status}: #{e.message[0..200]}"
    status((400..599).cover?(e.status) ? e.status : 502)
    {error: {message: "Direct API call failed (#{e.status}): #{e.message[0..200]}", type: "api_error"}}.to_json
  rescue JSON::ParserError
    status 502
    {error: {message: "Dispatcher returned non-JSON output", type: "api_error"}}.to_json
  rescue Timeout::Error
    status 504
    {error: {message: "Dispatch timed out after #{SUBPROCESS_TIMEOUT}s", type: "timeout_error"}}.to_json
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
    active_requests: $dispatcher.active_count,
    subprocess_timeout: SUBPROCESS_TIMEOUT,
    direct_api_enabled: !$direct_dispatcher.nil?,
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
