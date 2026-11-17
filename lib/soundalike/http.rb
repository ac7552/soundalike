# frozen_string_literal: true

module Soundalike
  # Small JSON-over-HTTPS client on top of Net::HTTP.
  #
  # Every method returns a Response whatever the status code, because the
  # upstream APIs disagree about how they report errors (Deezer and Last.fm
  # often answer 200 with an error object). Callers decide what a status means.
  # Network failures raise UpstreamError.
  class HTTP
    Response = Struct.new(:status, :json) do
      def ok? = status.between?(200, 299)
    end

    NETWORK_ERRORS = [
      Timeout::Error, SocketError, SystemCallError, EOFError, IOError,
      OpenSSL::SSL::SSLError, Net::ProtocolError
    ].freeze

    def initialize(open_timeout: 5, read_timeout: 10, user_agent: "soundalike/0.1")
      @open_timeout = open_timeout
      @read_timeout = read_timeout
      @user_agent = user_agent
    end

    def get(url, params = {})
      uri = URI.parse(url)
      uri.query = URI.encode_www_form(params) unless params.empty?
      perform(uri, Net::HTTP::Get.new(uri))
    end

    def post_json(url, payload, read_timeout: nil)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request["content-type"] = "application/json"
      request.body = JSON.generate(payload)
      perform(uri, request, read_timeout: read_timeout)
    end

    # parts: [[name, string], [name, io, { filename:, content_type: }], ...]
    def post_multipart(url, parts, read_timeout: nil)
      uri = URI.parse(url)
      request = Net::HTTP::Post.new(uri)
      request.set_form(parts, "multipart/form-data")
      perform(uri, request, read_timeout: read_timeout)
    end

    private

    def perform(uri, request, read_timeout: nil)
      request["user-agent"] = @user_agent
      request["accept"] = "application/json"

      response = Net::HTTP.start(
        uri.host, uri.port,
        use_ssl: uri.scheme == "https",
        open_timeout: @open_timeout,
        read_timeout: read_timeout || @read_timeout
      ) { |connection| connection.request(request) }

      Response.new(response.code.to_i, parse(response.body))
    rescue *NETWORK_ERRORS => e
      raise UpstreamError, "Could not reach #{uri.host} (#{e.class.name.split('::').last})."
    end

    def parse(body)
      return nil if body.nil? || body.strip.empty?

      JSON.parse(body)
    rescue JSON::ParserError
      nil
    end
  end
end
