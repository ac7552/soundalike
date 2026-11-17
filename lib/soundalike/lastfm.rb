# frozen_string_literal: true

module Soundalike
  # Last.fm's track.getSimilar: neighbours ranked from listening data.
  # Needs a free API key (https://www.last.fm/api/account/create).
  class Lastfm
    BASE = "https://ws.audioscrobbler.com/2.0/"
    TRACK_NOT_FOUND = 6
    KEY_ERRORS = [10, 26].freeze
    RATE_LIMITED = 29

    def initialize(http:, api_key:)
      @http = http
      @api_key = api_key.to_s.strip
    end

    def configured? = !@api_key.empty?

    # Returns [{ artist:, title:, match:, url: }], best match first.
    # match is Last.fm's own 0..1 similarity.
    def similar(artist:, title:, limit: 60)
      return [] unless configured?

      response = @http.get(BASE, method: "track.getsimilar", artist: artist, track: title,
                                 autocorrect: 1, limit: limit, api_key: @api_key, format: "json")
      body = response.json
      raise UpstreamError, "Last.fm answered with status #{response.status}." unless body.is_a?(Hash)

      check_error(body)
      tracks = body.dig("similartracks", "track")
      tracks = [tracks] if tracks.is_a?(Hash)
      Array(tracks).filter_map { |item| build(item) }
    end

    private

    def check_error(body)
      code = body["error"] or return
      return if code == TRACK_NOT_FOUND
      raise UpstreamError, "Last.fm rejected the API key. Check LASTFM_API_KEY." if KEY_ERRORS.include?(code)
      raise UpstreamError, "Last.fm is rate-limiting requests. Try again shortly." if code == RATE_LIMITED

      raise UpstreamError, "Last.fm error: #{body['message']}."
    end

    def build(item)
      return nil unless item.is_a?(Hash)

      artist = item["artist"].is_a?(Hash) ? item["artist"]["name"] : item["artist"]
      title = item["name"]
      return nil if artist.to_s.empty? || title.to_s.empty?

      { artist: artist, title: title, match: Float(item["match"], exception: false) || 0.0, url: item["url"] }
    end
  end
end
