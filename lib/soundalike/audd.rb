# frozen_string_literal: true

module Soundalike
  # AudD music recognition: names the song in a short microphone recording.
  # This is the one paid dependency (a free allowance, then per request),
  # so the "listen" feature stays off until AUDD_API_TOKEN is set.
  class Audd
    URL = "https://api.audd.io/"
    EXTENSIONS = {
      "audio/webm" => "webm", "audio/ogg" => "ogg", "audio/mp4" => "m4a",
      "audio/mpeg" => "mp3", "audio/wav" => "wav", "audio/x-wav" => "wav",
      "audio/aac" => "aac", "audio/flac" => "flac"
    }.freeze

    def initialize(http:, api_token:)
      @http = http
      @api_token = api_token.to_s.strip
    end

    def configured? = !@api_token.empty?

    # io: the recorded clip. Returns { artist:, title:, deezer_id: } or nil when nothing matched.
    def recognize(io, content_type:)
      raise NotConfigured, "Listening is switched off: set AUDD_API_TOKEN to turn it on." unless configured?

      media_type = content_type.to_s.split(";").first.to_s.strip.downcase
      filename = "clip.#{EXTENSIONS.fetch(media_type, 'webm')}"
      file_options = { filename: filename, content_type: media_type.empty? ? "audio/webm" : media_type }

      response = @http.post_multipart(
        URL,
        [["api_token", @api_token], ["return", "deezer"], ["file", io, file_options]],
        read_timeout: 30
      )
      body = response.json
      raise UpstreamError, "AudD answered with status #{response.status}." unless body.is_a?(Hash)

      if body["status"] == "error"
        message = body.dig("error", "error_message") || "unknown error"
        raise UpstreamError, "AudD could not process the recording: #{message}"
      end

      result = body["result"]
      return nil unless result.is_a?(Hash) && result["title"]

      { artist: result["artist"], title: result["title"], deezer_id: result.dig("deezer", "id") }
    end
  end
end
