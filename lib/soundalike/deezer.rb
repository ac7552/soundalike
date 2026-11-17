# frozen_string_literal: true

module Soundalike
  # Deezer's public API: no key needed. Used to pin a song down to one
  # canonical track and to get its 30-second preview and artwork.
  class Deezer
    BASE = "https://api.deezer.com"
    NO_DATA = 800
    QUOTA = 4
    # Deezer allows 50 requests per 5 seconds; stay a little under it.
    REQUESTS = 45
    WINDOW_SECONDS = 5

    def initialize(http:, limiter: RateLimiter.new(limit: REQUESTS, per: WINDOW_SECONDS))
      @http = http
      @limiter = limiter
    end

    def track(id)
      data = request("/track/#{Integer(id)}")
      data && build(data)
    end

    # Tries an exact artist/title query first, then falls back to free text.
    # Pass fallback: false to spend one request at most (used for bulk lookups).
    def search(artist:, title:, fallback: true)
      artist = artist.to_s.strip
      title = title.to_s.strip
      return search_text(title) if artist.empty?

      exact = first(%(artist:"#{unquote(artist)}" track:"#{unquote(title)}"))
      exact || (fallback ? search_text("#{artist} #{title}") : nil)
    end

    def search_text(text)
      text = text.to_s.strip
      text.empty? ? nil : first(text)
    end

    # Tracks Deezer considers close to an artist. The fallback when Last.fm
    # has no key configured or no data for the seed track.
    def artist_radio(artist_id, limit: 40)
      data = request("/artist/#{Integer(artist_id)}/radio", limit: limit)
      Array(data && data["data"]).filter_map { |item| build(item) }
    end

    private

    def first(query)
      data = request("/search", q: query, limit: 1)
      item = Array(data && data["data"]).first
      item && build(item)
    end

    def request(path, params = {})
      @limiter.wait
      response = @http.get("#{BASE}#{path}", params)
      body = response.json
      raise UpstreamError, "Deezer answered with status #{response.status}." unless response.ok? && body.is_a?(Hash)

      error = body["error"]
      return body unless error

      code = error.is_a?(Hash) ? error["code"] : nil
      return nil if code == NO_DATA
      raise UpstreamError, "Deezer is rate-limiting requests. Try again in a few seconds." if code == QUOTA

      raise UpstreamError, "Deezer error: #{error.is_a?(Hash) ? error['message'] : error}."
    end

    def build(item)
      return nil unless item.is_a?(Hash) && item["id"] && item["title"]

      artist = item["artist"] || {}
      album = item["album"] || {}
      Track.new(
        id: item["id"],
        title: item["title"],
        artist: artist["name"],
        artist_id: artist["id"],
        album: album["title"],
        cover: album["cover_medium"] || album["cover"],
        preview: presence(item["preview"]),
        link: item["link"] || "https://www.deezer.com/track/#{item['id']}",
        duration: item["duration"]
      )
    end

    def unquote(text) = text.delete('"')

    def presence(value) = value.to_s.empty? ? nil : value
  end
end
