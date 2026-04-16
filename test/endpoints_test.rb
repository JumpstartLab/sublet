require_relative "test_helper"
require_relative "../app"

# Endpoint smoke tests. Per Corey: 2 tests per endpoint — one happy path,
# one error-mapping test. The translation behavior is covered in detail
# by prompt_extractor_test.rb; the job here is wiring.
class EndpointsTest < Minitest::Test
  include Rack::Test::Methods

  def app
    Sinatra::Application
  end

  # A successful response out of the CLI subprocess.
  CANNED_SUCCESS = {
    "result" => "hi there",
    "stop_reason" => "end_turn",
    "modelUsage" => {"claude-haiku-4-5-20251001" => {}},
    "usage" => {"input_tokens" => 11, "output_tokens" => 4},
  }.freeze

  # --- Anthropic /v1/messages ---------------------------------------

  def test_anthropic_happy_path
    $dispatcher.stub(:call, CANNED_SUCCESS) do
      post "/v1/messages",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "message", body["type"]
    assert_equal "assistant", body["role"]
    assert_equal "hi there", body.dig("content", 0, "text")
    assert_equal "claude-haiku-4-5-20251001", body["model"]
    assert_equal({"input_tokens" => 11, "output_tokens" => 4}, body["usage"])
  end

  def test_anthropic_cli_error_maps_to_502
    $dispatcher.stub(:call, ->(*) { raise CliDispatcher::CLIError.new("subprocess died", 1) }) do
      post "/v1/messages",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end

    assert_equal 502, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "error", body["type"]
    assert_equal "api_error", body.dig("error", "type")
  end

  # --- OpenAI /v1/chat/completions ----------------------------------

  def test_openai_happy_path
    $dispatcher.stub(:call, CANNED_SUCCESS) do
      post "/v1/chat/completions",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end

    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "chat.completion", body["object"]
    assert_equal "hi there", body.dig("choices", 0, "message", "content")
    assert_equal "stop", body.dig("choices", 0, "finish_reason")
    assert_equal 15, body.dig("usage", "total_tokens")
  end

  def test_openai_cli_error_maps_to_502
    $dispatcher.stub(:call, ->(*) { raise CliDispatcher::CLIError.new("boom", 1) }) do
      post "/v1/chat/completions",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end

    assert_equal 502, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "api_error", body.dig("error", "type")
  end

  # --- Timeout maps to 504 ------------------------------------------

  def test_timeout_maps_to_504
    $dispatcher.stub(:call, ->(*) { raise Timeout::Error }) do
      post "/v1/messages",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end

    assert_equal 504, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "timeout_error", body.dig("error", "type")
  end

  # --- 400 on no usable content -------------------------------------

  def test_empty_messages_returns_400
    post "/v1/messages", {model: "haiku", messages: []}.to_json,
         {"CONTENT_TYPE" => "application/json"}
    assert_equal 400, last_response.status
  end

  # --- Health, models, refresh --------------------------------------

  def test_health_reports_ok_and_token_status
    get "/health"
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "ok", body["status"]
    assert_equal "cli-subprocess", body["mode"]
    assert body.key?("token_prefix"), "health should expose token_prefix"
    refute_includes body["token_prefix"], ENV["CLAUDE_OAUTH_TOKEN"][16..],
                    "health must not leak the full token"
  end

  def test_models_lists_expected_ids
    get "/v1/models"
    assert_equal 200, last_response.status
    ids = JSON.parse(last_response.body)["data"].map { |m| m["id"] }
    assert_includes ids, "claude-haiku-4-5-20251001"
  end

  # --- Empty / defensive CLI response -------------------------------

  def test_empty_cli_result_does_not_produce_null_response_fields
    $dispatcher.stub(:call, {}) do
      post "/v1/messages",
           {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
           {"CONTENT_TYPE" => "application/json"}
    end
    assert_equal 200, last_response.status
    body = JSON.parse(last_response.body)
    assert_equal "", body.dig("content", 0, "text")
    assert_equal 0, body.dig("usage", "input_tokens")
    assert_equal "end_turn", body["stop_reason"]
  end
end
