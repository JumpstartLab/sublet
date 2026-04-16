require "json"
require "net/http"
require "uri"
require "time"

class TokenManager
  REFRESH_MARGIN = 300 # refresh 5 min before expiry
  DEFAULT_ENDPOINT = "https://platform.claude.com/v1/oauth/token"
  DEFAULT_LIFETIME = 28800 # 8 hours, when server doesn't tell us

  def initialize(access_token, refresh_token,
                 expires_in: nil,
                 token_endpoint: DEFAULT_ENDPOINT,
                 oauth_client_id:,
                 cli_version:,
                 token_file:,
                 logger: $stderr)
    @mutex = Mutex.new
    @access_token = access_token
    @refresh_token = refresh_token
    @initial_token_prefix = access_token[0..15]
    @expires_at = expires_in ? Time.now + expires_in : Time.now + DEFAULT_LIFETIME
    @token_endpoint = token_endpoint
    @oauth_client_id = oauth_client_id
    @cli_version = cli_version
    @token_file = token_file
    @logger = logger
    load_state
  end

  def access_token
    @mutex.synchronize do
      refresh! if @refresh_token && Time.now >= (@expires_at - REFRESH_MARGIN)
      @access_token
    end
  end

  def force_refresh!
    @mutex.synchronize { refresh! }
  end

  def status
    @mutex.synchronize do
      {
        token_prefix: @access_token[0..15],
        has_refresh: !@refresh_token.nil?,
        expires_in: (@expires_at - Time.now).to_i,
        expires_at: @expires_at.iso8601,
        auto_refresh: !@refresh_token.nil?,
      }
    end
  end

  private

  def log(msg)
    @logger.puts("[#{Time.now.strftime("%H:%M:%S")}] #{msg}") if @logger
  end

  def refresh!
    log("Refreshing OAuth token...")

    uri = URI(@token_endpoint)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = (uri.scheme == "https")
    http.read_timeout = 30

    req = Net::HTTP::Post.new(uri)
    req["Content-Type"] = "application/x-www-form-urlencoded"
    req["User-Agent"] = "claude-cli/#{@cli_version} (external, sdk-cli)"
    req["X-Stainless-Arch"] = "arm64"
    req["X-Stainless-Lang"] = "js"
    req["X-Stainless-OS"] = "MacOS"
    req["X-Stainless-Runtime"] = "node"
    req["X-Stainless-Runtime-Version"] = "v24.3.0"
    req.body = URI.encode_www_form(
      grant_type: "refresh_token",
      refresh_token: @refresh_token,
      client_id: @oauth_client_id,
    )

    resp = http.request(req)
    unless resp.code.to_i == 200
      log("  Token refresh failed: #{resp.code} #{resp.body.to_s[0..200]}")
      return
    end

    data = JSON.parse(resp.body)
    @access_token = data["access_token"]
    @refresh_token = data["refresh_token"]
    @expires_at = Time.now + (data["expires_in"] || DEFAULT_LIFETIME)

    log("  Token refreshed: #{@access_token[0..15]}... expires_in=#{data["expires_in"]}s")
    save_state
  rescue => e
    log("  Token refresh error: #{e.message}")
  end

  def save_state
    tmp_file = "#{@token_file}.tmp"
    File.write(tmp_file, JSON.generate(
      access_token: @access_token,
      refresh_token: @refresh_token,
      expires_at: @expires_at.to_f,
    ))
    File.rename(tmp_file, @token_file)
  rescue => e
    log("  Warning: could not save token state: #{e.message}")
  end

  def load_state
    return unless @token_file && File.exist?(@token_file)

    data = JSON.parse(File.read(@token_file))
    saved_prefix = data["access_token"][0..15] rescue nil
    saved_at = Time.at(data["expires_at"].to_f)

    # If the on-disk token prefix differs from the env var, the operator
    # manually rotated tokens — prefer the fresh env var values.
    if saved_prefix && saved_prefix != @initial_token_prefix
      log("  Token state file has different token prefix (#{saved_prefix}), preferring env var token")
      return
    end

    # Stale file → let the env-var token stand.
    return unless saved_at > Time.now

    @access_token = data["access_token"]
    @refresh_token = data["refresh_token"] if data["refresh_token"]
    @expires_at = saved_at
    log("  Loaded saved token state: #{@access_token[0..15]}... expires_in=#{(@expires_at - Time.now).to_i}s")
  rescue => e
    log("  Warning: could not load token state: #{e.message}")
  end
end
