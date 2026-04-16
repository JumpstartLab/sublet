ENV["RACK_ENV"] = "test"
ENV["CLAUDE_OAUTH_TOKEN"] ||= "sk-ant-oat01-test-000000000000000000"
ENV["CLAUDE_OAUTH_REFRESH_TOKEN"] ||= "sk-ant-ort01-test-000000000000000000"

require "minitest/autorun"
require "minitest/mock"
require "rack/test"
require "json"
require "tmpdir"
require "fileutils"

# Isolate per-test-run state from anything on the developer's machine.
TEST_TMP = File.join(Dir.tmpdir, "sublet-test-#{Process.pid}")
FileUtils.mkdir_p(TEST_TMP)
Minitest.after_run { FileUtils.rm_rf(TEST_TMP) }

ENV["TOKEN_STATE_FILE"] ||= File.join(TEST_TMP, "token_state.json")
ENV["CLI_WORKDIR"] ||= TEST_TMP

PROJECT_ROOT = File.expand_path("..", __dir__)
$LOAD_PATH.unshift(PROJECT_ROOT) unless $LOAD_PATH.include?(PROJECT_ROOT)
