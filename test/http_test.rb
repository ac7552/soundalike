# frozen_string_literal: true

require_relative "test_helper"
require "socket"

# Exercises the real Net::HTTP client against a throwaway server on localhost.
class HTTPTest < Minitest::Test
  Received = Struct.new(:request_line, :headers, :body)

  def setup
    @server = TCPServer.new("127.0.0.1", 0)
    @base = "http://127.0.0.1:#{@server.addr[1]}"
    @received = Queue.new
    @responses = Queue.new
    @thread = Thread.new { serve }
  end

  def teardown
    @thread.kill
    @server.close
  end

  def serve
    loop do
      client = @server.accept
      request_line = client.gets.to_s.strip
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.downcase] = value.strip
      end
      body = client.read(headers["content-length"].to_i)
      @received << Received.new(request_line, headers, body)

      status, payload, delay = @responses.pop
      sleep(delay) if delay
      client.write("HTTP/1.1 #{status} X\r\ncontent-type: application/json\r\ncontent-length: #{payload.bytesize}\r\nconnection: close\r\n\r\n#{payload}")
      client.close
    rescue IOError, SystemCallError
      next
    end
  end

  def reply(status, payload, delay: nil) = @responses << [status, payload, delay]

  def test_get_encodes_params_and_parses_json
    reply(200, '{"data":[1]}')
    response = Soundalike::HTTP.new.get("#{@base}/search", q: 'artist:"girl in red" track:"a&b"', limit: 1)

    assert response.ok?
    assert_equal({ "data" => [1] }, response.json)
    seen = @received.pop
    assert_equal "GET /search?q=artist%3A%22girl+in+red%22+track%3A%22a%26b%22&limit=1 HTTP/1.1", seen.request_line
    assert_equal "soundalike/0.1", seen.headers["user-agent"]
  end

  def test_error_statuses_still_return_the_body
    reply(403, '{"error":10,"message":"Invalid API key"}')
    response = Soundalike::HTTP.new.get("#{@base}/")
    refute response.ok?
    assert_equal [403, 10], [response.status, response.json["error"]]
  end

  def test_non_json_and_empty_bodies_are_nil
    reply(200, "<html>nope</html>")
    assert_nil Soundalike::HTTP.new.get("#{@base}/").json
    reply(204, "")
    assert_nil Soundalike::HTTP.new.get("#{@base}/").json
  end

  def test_post_json
    reply(200, '{"scores":{"1":0.5}}')
    response = Soundalike::HTTP.new.post_json("#{@base}/scores", { seed: { id: 1 } })

    assert_equal({ "scores" => { "1" => 0.5 } }, response.json)
    seen = @received.pop
    assert_equal "POST /scores HTTP/1.1", seen.request_line
    assert_equal "application/json", seen.headers["content-type"]
    assert_equal({ "seed" => { "id" => 1 } }, JSON.parse(seen.body))
  end

  def test_post_multipart_sends_fields_and_the_file
    reply(200, '{"status":"success","result":null}')
    clip = StringIO.new("RIFF-audio-bytes")
    Soundalike::HTTP.new.post_multipart(
      "#{@base}/",
      [["api_token", "secret"], ["return", "deezer"], ["file", clip, { filename: "clip.webm", content_type: "audio/webm" }]]
    )

    seen = @received.pop
    assert_match(%r{\Amultipart/form-data; boundary=}, seen.headers["content-type"])
    assert_includes seen.body, %(name="api_token"\r\n\r\nsecret)
    assert_includes seen.body, %(name="file"; filename="clip.webm")
    assert_includes seen.body, "Content-Type: audio/webm"
    assert_includes seen.body, "RIFF-audio-bytes"
  end

  def test_slow_servers_time_out_as_upstream_errors
    reply(200, "{}", delay: 1.5)
    error = assert_raises(Soundalike::UpstreamError) { Soundalike::HTTP.new(read_timeout: 0.2).get("#{@base}/") }
    assert_match(/Could not reach 127\.0\.0\.1/, error.message)
  end

  def test_refused_connections_are_upstream_errors
    closed = TCPServer.new("127.0.0.1", 0)
    port = closed.addr[1]
    closed.close
    assert_raises(Soundalike::UpstreamError) { Soundalike::HTTP.new.get("http://127.0.0.1:#{port}/") }
  end
end
