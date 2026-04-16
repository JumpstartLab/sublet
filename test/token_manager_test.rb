require_relative "test_helper"
require_relative "../lib/token_manager"

class TokenManagerTest < Minitest::Test
  def setup
    @token_file = File.join(TEST_TMP, "token_state_#{object_id}.json")
    @null_logger = File.open(File::NULL, "w")
  end

  def teardown
    File.unlink(@token_file) if File.exist?(@token_file)
    @null_logger.close
  end

  def build(token: "sk-ant-oat01-aaaaaaaaaaaaaaa", refresh: "refresh-1", expires_in: 3600)
    TokenManager.new(
      token, refresh,
      expires_in: expires_in,
      oauth_client_id: "test-client",
      cli_version: "0.0.0",
      token_file: @token_file,
      logger: @null_logger,
    )
  end

  def test_status_reports_prefix_and_refresh_presence
    mgr = build
    status = mgr.status
    assert_equal "sk-ant-oat01-aaa", status[:token_prefix]
    assert_equal true, status[:has_refresh]
    assert_operator status[:expires_in], :>, 0
  end

  def test_access_token_returns_current_token_when_fresh
    mgr = build
    assert_equal "sk-ant-oat01-aaaaaaaaaaaaaaa", mgr.access_token
  end

  def test_load_state_ignores_file_with_mismatched_prefix
    # Seed the file with a DIFFERENT prefix from what we'll hand to the
    # constructor — operator rotation scenario. Env var should win.
    File.write(@token_file, JSON.generate(
      access_token: "sk-ant-oat01-DIFFERENTPREFIX",
      refresh_token: "ignored-refresh",
      expires_at: (Time.now + 7200).to_f,
    ))

    mgr = build(token: "sk-ant-oat01-aaaaaaaaaaaaaaa")
    assert_equal "sk-ant-oat01-aaaaaaaaaaaaaaa", mgr.access_token
  end

  def test_load_state_ignores_expired_file
    File.write(@token_file, JSON.generate(
      access_token: "sk-ant-oat01-aaaaaaaaaaaaaaa",
      refresh_token: "stale-refresh",
      expires_at: (Time.now - 60).to_f,
    ))

    mgr = build(token: "sk-ant-oat01-aaaaaaaaaaaaaaa")
    # env-var values stand; the expired file is not trusted
    assert_equal "sk-ant-oat01-aaaaaaaaaaaaaaa", mgr.access_token
  end

  def test_load_state_adopts_matching_unexpired_file
    File.write(@token_file, JSON.generate(
      access_token: "sk-ant-oat01-aaaaaaaaaaaaaaa",
      refresh_token: "saved-refresh",
      expires_at: (Time.now + 7200).to_f,
    ))

    mgr = build(token: "sk-ant-oat01-aaaaaaaaaaaaaaa", refresh: "env-refresh")
    # Refresh token from disk overrides the env-var one when prefix matches.
    # (That keeps us in sync after a restart.)
    assert_operator mgr.status[:expires_in], :>, 3600
  end

  def test_corrupt_state_file_does_not_crash_startup
    File.write(@token_file, "not json at all }}}{{")
    mgr = build(token: "sk-ant-oat01-aaaaaaaaaaaaaaa")
    assert_equal "sk-ant-oat01-aaaaaaaaaaaaaaa", mgr.access_token
  end

  def test_refresh_is_triggered_when_inside_margin
    # Initialize with only 60s left — well inside REFRESH_MARGIN (300s) —
    # and stub refresh! to confirm it is called.
    mgr = build(expires_in: 60)
    called = 0
    mgr.define_singleton_method(:refresh!) { called += 1 }
    mgr.access_token
    mgr.access_token # second call, still expiring — still triggers
    assert_equal 2, called
  end

  def test_refresh_not_triggered_when_fresh
    mgr = build(expires_in: 7200)
    called = 0
    mgr.define_singleton_method(:refresh!) { called += 1 }
    mgr.access_token
    assert_equal 0, called
  end

  def test_refresh_skipped_when_no_refresh_token
    mgr = build(refresh: nil, expires_in: 60)
    called = 0
    mgr.define_singleton_method(:refresh!) { called += 1 }
    mgr.access_token
    assert_equal 0, called
    assert_equal false, mgr.status[:has_refresh]
    assert_equal false, mgr.status[:auto_refresh]
  end

  def test_force_refresh_always_runs
    mgr = build(expires_in: 7200)
    called = 0
    mgr.define_singleton_method(:refresh!) { called += 1 }
    mgr.force_refresh!
    assert_equal 1, called
  end
end
