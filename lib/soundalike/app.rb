# frozen_string_literal: true

require "stringio"

module Soundalike
  # The whole web layer as one plain Rack app: three JSON endpoints and the
  # static files in public/. It talks to the Rack environment directly, so it
  # has no framework dependency and can be tested by calling #call.
  #
  #   GET  /api/config     which optional features are switched on
  #   POST /api/similar    { "input": "<link or artist - title>", "rerank": false }
  #   POST /api/recognize  raw audio body (what the microphone recorded)
  class App
    MAX_JSON_BYTES = 16 * 1024
    MAX_AUDIO_BYTES = 3 * 1024 * 1024

    CONTENT_TYPES = {
      ".html" => "text/html; charset=utf-8",
      ".js" => "text/javascript; charset=utf-8",
      ".css" => "text/css; charset=utf-8",
      ".svg" => "image/svg+xml",
      ".png" => "image/png",
      ".ico" => "image/x-icon",
      ".json" => "application/json",
      ".txt" => "text/plain; charset=utf-8",
      ".woff2" => "font/woff2"
    }.freeze

    SECURITY_HEADERS = {
      "x-content-type-options" => "nosniff",
      "referrer-policy" => "no-referrer",
      "permissions-policy" => "microphone=(self)",
      "content-security-policy" =>
        "default-src 'self'; img-src 'self' https: data:; media-src https:; " \
        "style-src 'self' https://fonts.googleapis.com; font-src https://fonts.gstatic.com; " \
        "connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'self'"
    }.freeze

    def initialize(resolver:, recommender:, audd:, deezer:, public_dir:, logger: nil)
      @resolver = resolver
      @recommender = recommender
      @audd = audd
      @deezer = deezer
      @public_dir = File.expand_path(public_dir)
      @logger = logger
    end

    def call(env)
      method = env["REQUEST_METHOD"]
      path = env["PATH_INFO"].to_s

      case [method, path]
      when ["GET", "/api/config"] then json(200, config)
      when ["POST", "/api/similar"] then similar(env)
      when ["POST", "/api/recognize"] then recognize(env)
      else
        if path.start_with?("/api/")
          json(404, error: "No such endpoint.")
        elsif %w[GET HEAD].include?(method)
          static(path, head: method == "HEAD")
        else
          json(405, error: "Method not allowed.")
        end
      end
    rescue Soundalike::Error => e
      json(e.status, error: e.message)
    rescue StandardError => e
      log(env, e)
      json(500, error: "Something went wrong on the server.")
    end

    private

    def config
      { listen: @audd.configured?, rerank: @recommender.rerank_available? }
    end

    def similar(env)
      payload = parse_json(read_body(env, MAX_JSON_BYTES))
      seed = @resolver.resolve(payload["input"])
      json(200, @recommender.similar(seed, rerank: payload["rerank"] == true))
    end

    def recognize(env)
      raise NotConfigured, "Listening is switched off on this server." unless @audd.configured?

      body = read_body(env, MAX_AUDIO_BYTES)
      raise BadInput, "The recording was empty. Allow microphone access and try again." if body.empty?

      heard = @audd.recognize(StringIO.new(body), content_type: env["CONTENT_TYPE"])
      raise NotFound, "Could not recognise that song. Move closer to the speaker and try again." unless heard

      seed = (heard[:deezer_id] && @deezer.track(heard[:deezer_id])) ||
             @deezer.search(artist: heard[:artist], title: heard[:title])
      unless seed
        raise NotFound, "Heard “#{heard[:title]}” by #{heard[:artist]} but could not match it for previews."
      end

      json(200, @recommender.similar(seed))
    end

    def read_body(env, limit)
      declared = env["CONTENT_LENGTH"].to_s
      raise TooLarge, "That upload is too large." if declared.match?(/\A\d+\z/) && declared.to_i > limit

      input = env["rack.input"]
      body = input ? input.read(limit + 1).to_s : ""
      raise TooLarge, "That upload is too large." if body.bytesize > limit

      body
    end

    def parse_json(body)
      payload = JSON.parse(body)
      raise BadInput, "Send a JSON object." unless payload.is_a?(Hash)

      payload
    rescue JSON::ParserError
      raise BadInput, "Send a JSON object."
    end

    def static(path, head:)
      path = "/index.html" if path == "/" || path.empty?
      return json(404, error: "Not found.") if path.include?("\0")

      file = File.expand_path(File.join(@public_dir, path))
      inside = file.start_with?("#{@public_dir}#{File::SEPARATOR}")
      return json(404, error: "Not found.") unless inside && File.file?(file)

      body = File.binread(file)
      headers = SECURITY_HEADERS.merge(
        "content-type" => CONTENT_TYPES.fetch(File.extname(file).downcase, "application/octet-stream"),
        "content-length" => body.bytesize.to_s,
        "cache-control" => "no-cache"
      )
      [200, headers, head ? [] : [body]]
    end

    def json(status, payload)
      body = JSON.generate(payload)
      headers = {
        "content-type" => "application/json; charset=utf-8",
        "content-length" => body.bytesize.to_s,
        "cache-control" => "no-store",
        "x-content-type-options" => "nosniff"
      }
      [status, headers, [body]]
    end

    def log(env, error)
      message = "#{error.class}: #{error.message}\n#{Array(error.backtrace).first(5).join("\n")}"
      stream = @logger || env["rack.errors"]
      stream ? stream.puts(message) : warn(message)
    end
  end
end
