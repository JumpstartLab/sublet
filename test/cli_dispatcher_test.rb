require_relative "test_helper"
require_relative "../lib/cli_dispatcher"

class CliDispatcherConcurrencyTest < Minitest::Test
  # Faux token manager — the dispatcher only needs #access_token.
  class FakeTokenManager
    def access_token = "sk-fake"
  end

  def build(max_concurrent:, timeout: 5)
    CliDispatcher.new(
      token_manager: FakeTokenManager.new,
      workdir: TEST_TMP,
      max_concurrent: max_concurrent,
      timeout: timeout,
      logger: nil,
    )
  end

  def test_active_count_starts_at_zero
    assert_equal 0, build(max_concurrent: 5).active_count
  end

  def test_concurrency_limit_queues_excess_callers
    dispatcher = build(max_concurrent: 1)
    # Replace run_subprocess with something slow and observable.
    in_flight = 0
    max_seen = 0
    mutex = Mutex.new
    dispatcher.define_singleton_method(:run_subprocess) do |_env, _cmd, _prompt|
      mutex.synchronize { in_flight += 1; max_seen = [max_seen, in_flight].max }
      sleep 0.1
      mutex.synchronize { in_flight -= 1 }
      "{}"
    end

    threads = 3.times.map { Thread.new { dispatcher.call("hi", model: "h", json_output: true) } }
    threads.each(&:join)

    assert_equal 1, max_seen, "max_concurrent=1 should serialize callers"
    assert_equal 0, dispatcher.active_count, "slot accounting should return to zero"
  end

  def test_slot_released_when_subprocess_raises
    dispatcher = build(max_concurrent: 1)
    dispatcher.define_singleton_method(:run_subprocess) do |_env, _cmd, _prompt|
      raise CliDispatcher::CLIError.new("boom", 1)
    end

    assert_raises(CliDispatcher::CLIError) do
      dispatcher.call("hi", model: "h", json_output: true)
    end
    # If the ensure block is wrong, active_count stays at 1 and the next
    # call deadlocks. This assertion pins the ensure.
    assert_equal 0, dispatcher.active_count
  end

  def test_slot_released_when_timeout_fires
    dispatcher = build(max_concurrent: 1, timeout: 0.1)
    dispatcher.define_singleton_method(:run_subprocess) do |_env, _cmd, _prompt|
      # Simulate an inner block that times out.
      Timeout.timeout(dispatcher.instance_variable_get(:@timeout)) { sleep 1.0 }
      "{}"
    end

    assert_raises(Timeout::Error) do
      dispatcher.call("hi", model: "h", json_output: true)
    end
    assert_equal 0, dispatcher.active_count
  end
end

class CliDispatcherResponseShapeTest < Minitest::Test
  class FakeTokenManager
    def access_token = "sk-fake"
  end

  def build
    CliDispatcher.new(
      token_manager: FakeTokenManager.new,
      workdir: TEST_TMP,
      max_concurrent: 1,
      timeout: 5,
      logger: nil,
    )
  end

  def test_json_output_is_parsed
    dispatcher = build
    dispatcher.define_singleton_method(:run_subprocess) { |*| '{"result":"ok"}' }
    assert_equal({"result" => "ok"}, dispatcher.call("hi", model: "h", json_output: true))
  end

  def test_non_json_output_is_stripped
    dispatcher = build
    dispatcher.define_singleton_method(:run_subprocess) { |*| "  hello  \n" }
    assert_equal "hello", dispatcher.call("hi", model: "h")
  end

  def test_malformed_json_bubbles_up_as_parse_error
    dispatcher = build
    dispatcher.define_singleton_method(:run_subprocess) { |*| "not json" }
    assert_raises(JSON::ParserError) do
      dispatcher.call("hi", model: "h", json_output: true)
    end
  end
end
