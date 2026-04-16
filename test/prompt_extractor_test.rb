require_relative "test_helper"
require_relative "../lib/prompt_extractor"

class PromptExtractorAnthropicTest < Minitest::Test
  def extract(body)
    PromptExtractor.from_anthropic(body)
  end

  def test_returns_nil_when_messages_missing
    assert_nil extract({})
    assert_nil extract({"messages" => []})
    assert_nil extract({"messages" => "not-an-array"})
  end

  def test_simple_string_content
    result = extract({"messages" => [{"role" => "user", "content" => "hello"}]})
    assert_equal "hello", result.prompt
    assert_nil result.system_prompt
    assert result.valid?
  end

  def test_content_array_concatenates_text_blocks_with_newlines
    result = extract({"messages" => [{
      "role" => "user",
      "content" => [
        {"type" => "text", "text" => "line 1"},
        {"type" => "text", "text" => "line 2"},
      ],
    }]})
    assert_equal "line 1\nline 2", result.prompt
  end

  def test_multiple_user_messages_join_with_blank_line
    result = extract({"messages" => [
      {"role" => "user", "content" => "first"},
      {"role" => "assistant", "content" => "ignored"},
      {"role" => "user", "content" => "second"},
    ]})
    assert_equal "first\n\nsecond", result.prompt
  end

  def test_non_text_blocks_are_filtered
    result = extract({"messages" => [{
      "role" => "user",
      "content" => [
        {"type" => "text", "text" => "keep me"},
        {"type" => "image", "source" => {}},
        {"type" => "text", "text" => "also keep"},
      ],
    }]})
    assert_equal "keep me\nalso keep", result.prompt
  end

  def test_system_as_string
    result = extract({"system" => "be terse",
                      "messages" => [{"role" => "user", "content" => "hi"}]})
    assert_equal "be terse", result.system_prompt
  end

  def test_system_as_array_filters_billing_blocks
    result = extract({
      "system" => [
        {"type" => "text", "text" => "real instructions"},
        {"type" => "text", "text" => "x-anthropic-billing-header: foo"},
      ],
      "messages" => [{"role" => "user", "content" => "hi"}],
    })
    assert_equal "real instructions", result.system_prompt
  end

  def test_system_array_with_only_billing_blocks_becomes_nil
    result = extract({
      "system" => [{"type" => "text", "text" => "x-anthropic-billing-header: foo"}],
      "messages" => [{"role" => "user", "content" => "hi"}],
    })
    assert_nil result.system_prompt
  end

  def test_empty_user_content_array_yields_invalid_result
    result = extract({"messages" => [{"role" => "user", "content" => []}]})
    refute result.valid?, "empty content array should produce an invalid extraction"
  end

  def test_only_assistant_messages_yields_invalid_result
    result = extract({"messages" => [{"role" => "assistant", "content" => "hi"}]})
    refute result.valid?
  end
end

class PromptExtractorOpenAITest < Minitest::Test
  def extract(body)
    PromptExtractor.from_openai(body)
  end

  def test_returns_nil_when_messages_missing
    assert_nil extract({})
    assert_nil extract({"messages" => []})
  end

  def test_basic_system_and_user_split
    result = extract({"messages" => [
      {"role" => "system", "content" => "be terse"},
      {"role" => "user", "content" => "hi"},
    ]})
    assert_equal "hi", result.prompt
    assert_equal "be terse", result.system_prompt
  end

  def test_multiple_system_messages_concatenate
    result = extract({"messages" => [
      {"role" => "system", "content" => "one"},
      {"role" => "system", "content" => "two"},
      {"role" => "user", "content" => "hi"},
    ]})
    assert_equal "one\n\ntwo", result.system_prompt
  end

  def test_assistant_messages_ignored
    result = extract({"messages" => [
      {"role" => "user", "content" => "first"},
      {"role" => "assistant", "content" => "ignored"},
      {"role" => "user", "content" => "second"},
    ]})
    assert_equal "first\n\nsecond", result.prompt
  end

  def test_no_user_content_yields_invalid
    result = extract({"messages" => [{"role" => "system", "content" => "be terse"}]})
    refute result.valid?
  end
end

class PromptExtractorToolUseDetectionTest < Minitest::Test
  # --- Anthropic ----------------------------------------------------

  def test_anthropic_detects_non_empty_tools_array
    reason = PromptExtractor.tool_use_in_anthropic(
      "tools" => [{"name" => "get_weather"}],
      "messages" => [{"role" => "user", "content" => "hi"}],
    )
    assert_match(/tools array/, reason)
  end

  def test_anthropic_ignores_empty_tools_array
    assert_nil PromptExtractor.tool_use_in_anthropic(
      "tools" => [],
      "messages" => [{"role" => "user", "content" => "hi"}],
    )
  end

  def test_anthropic_detects_tool_use_content_block
    reason = PromptExtractor.tool_use_in_anthropic(
      "messages" => [{
        "role" => "assistant",
        "content" => [{"type" => "tool_use", "id" => "t1", "name" => "x", "input" => {}}],
      }],
    )
    assert_match(/tool_use/, reason)
  end

  def test_anthropic_detects_tool_result_content_block
    reason = PromptExtractor.tool_use_in_anthropic(
      "messages" => [{
        "role" => "user",
        "content" => [{"type" => "tool_result", "tool_use_id" => "t1", "content" => "42"}],
      }],
    )
    assert_match(/tool_result/, reason)
  end

  def test_anthropic_passes_clean_text_only_request
    assert_nil PromptExtractor.tool_use_in_anthropic(
      "messages" => [
        {"role" => "user", "content" => "hi"},
        {"role" => "assistant", "content" => [{"type" => "text", "text" => "hello"}]},
      ],
    )
  end

  # --- OpenAI -------------------------------------------------------

  def test_openai_detects_non_empty_tools_array
    reason = PromptExtractor.tool_use_in_openai(
      "tools" => [{"type" => "function", "function" => {"name" => "x"}}],
      "messages" => [{"role" => "user", "content" => "hi"}],
    )
    assert_match(/tools array/, reason)
  end

  def test_openai_detects_tool_calls_on_assistant_message
    reason = PromptExtractor.tool_use_in_openai(
      "messages" => [{
        "role" => "assistant",
        "tool_calls" => [{"id" => "c1", "type" => "function", "function" => {"name" => "x"}}],
      }],
    )
    assert_match(/tool_calls/, reason)
  end

  def test_openai_detects_tool_role_message
    reason = PromptExtractor.tool_use_in_openai(
      "messages" => [{"role" => "tool", "tool_call_id" => "c1", "content" => "42"}],
    )
    assert_match(/tool-role message/, reason)
  end

  def test_openai_passes_clean_text_only_request
    assert_nil PromptExtractor.tool_use_in_openai(
      "messages" => [
        {"role" => "system", "content" => "be terse"},
        {"role" => "user", "content" => "hi"},
      ],
    )
  end
end
