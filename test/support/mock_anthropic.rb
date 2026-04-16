require "webrick"
require "json"
require "socket"

# A minimal stand-in for api.anthropic.com that the real `claude --print`
# CLI can be pointed at via ANTHROPIC_BASE_URL. Serves canned responses
# from a queue and records every request it receives.
class MockAnthropic
  attr_reader :port, :requests

  def self.free_port
    s = TCPServer.new("127.0.0.1", 0)
    port = s.addr[1]
    s.close
    port
  end

  def initialize
    @responses = []
    @requests = []
    @mutex = Mutex.new
  end

  def start
    @port = self.class.free_port
    @server = WEBrick::HTTPServer.new(
      Port: @port,
      BindAddress: "127.0.0.1",
      Logger: WEBrick::Log.new(File.open(File::NULL, "w")),
      AccessLog: [],
    )
    mount_routes
    @thread = Thread.new { @server.start }
    wait_until_listening
    self
  end

  def stop
    @server&.shutdown
    @thread&.join(5)
  end

  def base_url
    "http://127.0.0.1:#{@port}"
  end

  def enqueue(body, status: 200)
    @mutex.synchronize { @responses << {body: body, status: status} }
  end

  def reset!
    @mutex.synchronize do
      @responses.clear
      @requests.clear
    end
  end

  private

  def wait_until_listening
    20.times do
      begin
        TCPSocket.new("127.0.0.1", @port).close
        return
      rescue Errno::ECONNREFUSED
        sleep 0.025
      end
    end
    raise "mock server failed to start on port #{@port}"
  end

  def mount_routes
    @server.mount_proc("/v1/messages") do |req, res|
      recorded = parse_request(req)
      @mutex.synchronize { @requests << recorded }

      # The `claude` CLI sends a streaming request first and falls back
      # to non-streaming if it can't parse the response as SSE. We only
      # consume the queue for the non-streaming attempt — streaming
      # requests get a default that triggers the fallback path.
      is_streaming = recorded[:body].is_a?(Hash) && recorded[:body]["stream"] == true
      canned =
        if is_streaming
          {body: default_response, status: 200}
        else
          @mutex.synchronize { @responses.shift || {body: default_response, status: 200} }
        end

      res.status = canned[:status]
      res["content-type"] = "application/json"
      res.body = canned[:body].is_a?(String) ? canned[:body] : JSON.generate(canned[:body])
    end
    # Catch-all so unexpected probes (HEAD /, GET /, etc.) return cleanly.
    @server.mount_proc("/") do |_req, res|
      res.status = 404
      res["content-type"] = "application/json"
      res.body = "{}"
    end
  end

  def parse_request(req)
    {
      method: req.request_method,
      path: req.path,
      headers: req.header.transform_values { |v| v.is_a?(Array) ? v.first : v },
      body: (JSON.parse(req.body) rescue req.body),
    }
  end

  def default_response
    {
      id: "msg_mock_default",
      type: "message",
      role: "assistant",
      model: "claude-haiku-4-5-20251001",
      content: [{type: "text", text: "ok"}],
      stop_reason: "end_turn",
      usage: {input_tokens: 5, output_tokens: 2},
    }
  end
end
