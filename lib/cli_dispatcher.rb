require "json"
require "timeout"

class CliDispatcher
  class CLIError < StandardError
    attr_reader :exit_code
    def initialize(message, exit_code)
      super(message)
      @exit_code = exit_code
    end
  end

  def initialize(token_manager:, workdir:, max_concurrent:, timeout:, logger: nil)
    @token_manager = token_manager
    @workdir = workdir
    @timeout = timeout
    @max_concurrent = max_concurrent
    @logger = logger

    @semaphore = Mutex.new
    @cv = ConditionVariable.new
    @active_count = 0
  end

  def active_count
    @semaphore.synchronize { @active_count }
  end

  def call(prompt, model:, system_prompt: nil, json_output: false)
    cmd = ["claude", "--print", "--model", model, "--strict-mcp-config"]
    cmd += ["--output-format", "json"] if json_output
    cmd += ["--system-prompt", system_prompt] if system_prompt

    env = {
      "CLAUDE_CODE_OAUTH_TOKEN" => @token_manager.access_token,
      "HOME" => ENV["HOME"] || "/root",
    }

    acquire_slot
    begin
      stdout = run_subprocess(env, cmd, prompt)
    ensure
      release_slot
    end

    json_output ? JSON.parse(stdout) : stdout.strip
  end

  private

  def acquire_slot
    @semaphore.synchronize do
      @cv.wait(@semaphore) while @active_count >= @max_concurrent
      @active_count += 1
    end
  end

  def release_slot
    @semaphore.synchronize do
      @active_count -= 1
      @cv.signal
    end
  end

  def run_subprocess(env, cmd, prompt)
    pid = nil
    stdout = stderr = status = nil

    begin
      Timeout.timeout(@timeout) do
        stdin_r, stdin_w = IO.pipe
        stdout_r, stdout_w = IO.pipe
        stderr_r, stderr_w = IO.pipe

        pid = Process.spawn(env, *cmd, in: stdin_r, out: stdout_w, err: stderr_w, chdir: @workdir)
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
        pid = nil
      end
    rescue Timeout::Error
      kill_pid(pid)
      raise
    end

    unless status&.success?
      exit_code = status&.exitstatus || -1
      @logger&.puts "  CLI error (exit #{exit_code}): #{stderr.to_s[0..500]}"
      raise CLIError.new(stderr.to_s, exit_code)
    end

    stdout
  end

  def kill_pid(pid)
    return unless pid
    Process.kill("TERM", pid) rescue nil
    sleep(0.5)
    Process.kill("KILL", pid) rescue nil
    Process.waitpid(pid) rescue nil
  end
end
