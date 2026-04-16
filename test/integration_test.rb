require_relative "test_helper"
require_relative "support/mock_anthropic"

# Integration tests: HTTP client → our Sinatra → real `claude --print`
# subprocess → MockAnthropic → full response path. No Anthropic credentials
# or network traffic required.
#
# Skipped when the `claude` CLI is not on PATH, or when SKIP_INTEGRATION=1.
class IntegrationTest < Minitest::Test
  include Rack::Test::Methods

  CLI_AVAILABLE = !ENV["SKIP_INTEGRATION"] && !`which claude 2>/dev/null`.strip.empty?

  def app
    @app_loaded ||= begin
      require_relative "../app"
      true
    end
    Sinatra::Application
  end

  def setup
    skip "integration tests disabled (SKIP_INTEGRATION=1 or `claude` not on PATH)" unless CLI_AVAILABLE

    @mock = MockAnthropic.new.start
    @prev_base = ENV["ANTHROPIC_BASE_URL"]
    @prev_key  = ENV["ANTHROPIC_API_KEY"]
    ENV["ANTHROPIC_BASE_URL"] = @mock.base_url
    ENV["ANTHROPIC_API_KEY"] = "sk-test-fake"
  end

  def teardown
    @mock&.stop
    ENV["ANTHROPIC_BASE_URL"] = @prev_base
    ENV["ANTHROPIC_API_KEY"] = @prev_key
  end

  def test_anthropic_roundtrip_through_real_cli
    @mock.enqueue({
      id: "msg_from_mock",
      type: "message",
      role: "assistant",
      model: "claude-haiku-4-5-20251001",
      content: [{type: "text", text: "hello from mock"}],
      stop_reason: "end_turn",
      usage: {input_tokens: 13, output_tokens: 3},
    })

    post "/v1/messages",
         {model: "haiku", messages: [{role: "user", content: "hi"}]}.to_json,
         {"CONTENT_TYPE" => "application/json"}

    assert_equal 200, last_response.status, "body=#{last_response.body}"
    body = JSON.parse(last_response.body)
    assert_equal "hello from mock", body.dig("content", 0, "text")
    assert_equal "end_turn", body["stop_reason"]
  end

  def test_openai_roundtrip_through_real_cli
    @mock.enqueue({
      id: "msg_from_mock",
      type: "message",
      role: "assistant",
      model: "claude-haiku-4-5-20251001",
      content: [{type: "text", text: "ok from mock"}],
      stop_reason: "end_turn",
      usage: {input_tokens: 7, output_tokens: 3},
    })

    post "/v1/chat/completions",
         {model: "haiku", messages: [
           {role: "system", content: "be terse"},
           {role: "user", content: "hi"},
         ]}.to_json,
         {"CONTENT_TYPE" => "application/json"}

    assert_equal 200, last_response.status, "body=#{last_response.body}"
    body = JSON.parse(last_response.body)
    assert_equal "ok from mock", body.dig("choices", 0, "message", "content")
  end
end
