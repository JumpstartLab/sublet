require_relative "test_helper"
require_relative "support/mock_anthropic"
require_relative "../lib/direct_dispatcher"

class DirectDispatcherTest < Minitest::Test
  class FakeTokenManager
    def access_token = "sk-ant-oat01-fake-token"
  end

  def setup
    @mock = MockAnthropic.new.start
    @dispatcher = DirectDispatcher.new(
      token_manager: FakeTokenManager.new,
      endpoint: "#{@mock.base_url}/v1/messages",
      max_tokens: 512,
      timeout: 5,
      logger: nil,
    )
  end

  def teardown
    @mock.stop
  end

  def test_call_reshapes_response_to_cli_shape
    @mock.enqueue({
      id: "msg_1", type: "message", role: "assistant",
      model: "claude-haiku-4-5-20251001",
      content: [{type: "text", text: "hi there"}],
      stop_reason: "end_turn",
      usage: {input_tokens: 7, output_tokens: 3},
    })

    result = @dispatcher.call("hi", model: "haiku")

    assert_equal "hi there", result["result"]
    assert_equal "end_turn", result["stop_reason"]
    assert_equal({"input_tokens" => 7, "output_tokens" => 3}, result["usage"])
    assert_equal({"input_tokens" => 7, "output_tokens" => 3},
                 result["modelUsage"]["claude-haiku-4-5-20251001"])
  end

  def test_call_sends_oauth_bearer_and_beta_header
    @mock.enqueue({content: [{type: "text", text: "ok"}], usage: {}})
    @dispatcher.call("hi", model: "haiku")

    req = @mock.requests.last
    assert_equal "POST", req[:method]
    assert_equal "Bearer sk-ant-oat01-fake-token", req[:headers]["authorization"]
    assert_equal "2023-06-01", req[:headers]["anthropic-version"]
    assert_equal "oauth-2025-04-20", req[:headers]["anthropic-beta"]
  end

  def test_call_forwards_model_and_max_tokens
    @mock.enqueue({content: [{type: "text", text: "ok"}], usage: {}})
    @dispatcher.call("hello world", model: "claude-haiku-4-5-20251001")

    body = @mock.requests.last[:body]
    assert_equal "claude-haiku-4-5-20251001", body["model"]
    assert_equal 512, body["max_tokens"]
    assert_equal [{"role" => "user", "content" => "hello world"}], body["messages"]
  end

  def test_call_includes_system_prompt_when_provided
    @mock.enqueue({content: [{type: "text", text: "ok"}], usage: {}})
    @dispatcher.call("hi", model: "haiku", system_prompt: "You are terse.")

    assert_equal "You are terse.", @mock.requests.last[:body]["system"]
  end

  def test_call_omits_system_when_empty
    @mock.enqueue({content: [{type: "text", text: "ok"}], usage: {}})
    @dispatcher.call("hi", model: "haiku", system_prompt: "")

    refute @mock.requests.last[:body].key?("system")
  end

  def test_non_200_raises_api_error_with_status
    @mock.enqueue({error: {message: "overloaded"}}, status: 529)

    err = assert_raises(DirectDispatcher::APIError) do
      @dispatcher.call("hi", model: "haiku")
    end
    assert_equal 529, err.status
    assert_includes err.message, "overloaded"
  end

  def test_concatenates_multiple_text_blocks_and_ignores_non_text
    @mock.enqueue({
      content: [
        {type: "text", text: "hello "},
        {type: "thinking", text: "ignored"},
        {type: "text", text: "world"},
      ],
      usage: {input_tokens: 1, output_tokens: 2},
    })

    result = @dispatcher.call("hi", model: "haiku")
    assert_equal "hello world", result["result"]
  end

  def test_active_count_is_zero
    assert_equal 0, @dispatcher.active_count
  end
end
