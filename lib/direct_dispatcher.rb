require "json"
require "net/http"
require "uri"

class DirectDispatcher
  class APIError < StandardError
    attr_reader :status
    def initialize(message, status)
      super(message)
      @status = status
    end
  end

  DEFAULT_ENDPOINT = "https://api.anthropic.com/v1/messages"
  ANTHROPIC_VERSION = "2023-06-01"
  ANTHROPIC_BETA = "oauth-2025-04-20"
  DEFAULT_MAX_TOKENS = 4096

  def initialize(token_manager:, endpoint: DEFAULT_ENDPOINT, max_tokens: DEFAULT_MAX_TOKENS, timeout: 120, logger: nil)
    @token_manager = token_manager
    @endpoint = endpoint
    @max_tokens = max_tokens
    @timeout = timeout
    @logger = logger
  end

  def active_count
    0
  end

  def call(prompt, model:, system_prompt: nil, json_output: false)
    body = {
      model: model,
      max_tokens: @max_tokens,
      messages: [{role: "user", content: prompt}],
    }
    body[:system] = system_prompt if system_prompt && !system_prompt.empty?

    response = post(body)
    reshape(response, model)
  end

  private

  def post(body)
    uri = URI(@endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = @timeout

    req = Net::HTTP::Post.new(uri)
    req["Authorization"] = "Bearer #{@token_manager.access_token}"
    req["anthropic-version"] = ANTHROPIC_VERSION
    req["anthropic-beta"] = ANTHROPIC_BETA
    req["content-type"] = "application/json"
    req["accept"] = "application/json"
    req.body = JSON.generate(body)

    resp = http.request(req)
    if resp.code.to_i != 200
      @logger&.puts "  Direct API error: #{resp.code} #{resp.body.to_s[0..300]}"
      raise APIError.new(resp.body.to_s, resp.code.to_i)
    end

    JSON.parse(resp.body)
  end

  # Remap the Anthropic Messages response shape onto the CliDispatcher-shaped
  # hash that app.rb reads — {"result", "usage", "modelUsage", "stop_reason"}.
  def reshape(resp, requested_model)
    text = Array(resp["content"])
      .select { |b| b["type"] == "text" }
      .map { |b| b["text"].to_s }
      .join

    usage = resp["usage"] || {}
    returned_model = resp["model"] || requested_model

    {
      "result" => text,
      "usage" => usage,
      "modelUsage" => {returned_model => usage},
      "stop_reason" => resp["stop_reason"],
    }
  end
end
